"""Durable call claims: an uncertain external effect is never silently repeated."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .artifacts import ArtifactStore


class RecoveryError(RuntimeError):
    pass


@dataclass(frozen=True)
class CallRecord:
    result: dict[str, Any]
    artifacts: list[dict[str, Any]]
    snapshot_error: str | None = None


@dataclass(frozen=True)
class CallJournal:
    store: ArtifactStore
    run_id: str
    attempt: int
    stage: str

    def run(
        self,
        identity: dict[str, Any],
        invoke: Callable[[], dict[str, Any]],
        snapshot: Callable[[], str],
        *,
        allow_replay: bool = False,
    ) -> CallRecord:
        prefix = f"call-{self.attempt}-{self.stage}"
        digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        claim = {"version": 1, "input_sha256": digest}
        adapter = {key: identity[key] for key in ("model", "command")
                   if isinstance(identity.get(key), str)}
        mismatch = (
            f"call receipt identity mismatch: {prefix}; verify role inputs, model registry "
            f"and PATH; current resolved adapter: {json.dumps(adapter, ensure_ascii=False)}"
        )
        try:
            start, created = self.store.create_json(self.run_id, f"{prefix}-started.json", claim)
        except FileExistsError as exc:
            raise RecoveryError(mismatch) from exc
        if not created:
            if not allow_replay:
                raise RecoveryError(
                    f"unexpected existing call receipt: {prefix}; only the checkpoint's "
                    "interrupted call may be replayed during explicit resume"
                )
            try:
                record = self.store.read_json(self.run_id, f"{prefix}-completed.json")
            except FileNotFoundError as exc:
                raise RecoveryError(
                    f"call outcome unknown: {start['path']}; inspect the workspace and "
                    "start a new run after recovery; this call will not be repeated"
                ) from exc
            fields = {"stdout", "stderr"} if self.stage == "gate" else {"output", "stderr"}
            if (
                not isinstance(record, dict)
                or not isinstance(record.get("result"), dict)
                or not isinstance(record.get("outputs"), dict)
                or set(record["outputs"]) != fields
            ):
                raise RecoveryError(f"malformed call completion record: {prefix}")
            if record.get("input_sha256") != digest or record.get("version") != 1:
                raise RecoveryError(mismatch)
            if not record.get("change_sha256") or snapshot() != record["change_sha256"]:
                raise RecoveryError(f"workspace no longer matches completed call: {prefix}")
            result = dict(record["result"])
            artifacts = [start]
            for field, expected in record["outputs"].items():
                if field not in {"output", "stdout", "stderr"}:
                    raise RecoveryError(f"invalid output field in receipt: {prefix}")
                name = f"{prefix}-{field}.txt"
                content = self.store.read(self.run_id, name)
                if hashlib.sha256(content).hexdigest() != expected:
                    raise RecoveryError(f"call output digest mismatch: {name}")
                result[field] = content.decode("utf-8")
                artifacts.append(self.store.write(self.run_id, name, result[field]))
            artifacts.append(self.store.write_json(self.run_id, f"{prefix}-completed.json", record))
            return CallRecord(result, artifacts)

        result = invoke()
        metadata = dict(result)
        artifacts = [start]
        outputs = {}
        for field in ("output", "stdout", "stderr"):
            if field in metadata:
                artifact = self.store.write(self.run_id, f"{prefix}-{field}.txt", metadata.pop(field))
                outputs[field] = artifact["sha256"]
                artifacts.append(artifact)
        error = None
        try:
            change_digest = snapshot()
        except (OSError, ValueError) as exc:
            change_digest = None
            error = f"{type(exc).__name__}: {exc}"
        completion = {
            **claim, "result": metadata, "outputs": outputs,
            "change_sha256": change_digest, "snapshot_error": error,
        }
        artifacts.append(self.store.write_json(self.run_id, f"{prefix}-completed.json", completion))
        return CallRecord(result, artifacts, error)
