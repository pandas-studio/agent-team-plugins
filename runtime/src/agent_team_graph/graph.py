"""A bounded, checkpointable role workflow for one engineering task."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path
from typing import Any, Protocol

from langgraph.graph import END, START, StateGraph
from langgraph.types import interrupt

from .artifacts import ArtifactStore
from .policy import approval_route, parse_verdict, review_route
from .registry import RoleResult, RoleRunner, usage_record
from .state import GraphState

GATE_TIMEOUT_SECONDS = 900
SNAPSHOT_ERRORS = (OSError, ValueError)


class Runner(Protocol):
    def run(self, role: str, prompt: str, workspace: Path) -> RoleResult: ...


def _git(workspace: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(workspace), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def _git_bytes(workspace: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(workspace), *args],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        error = result.stderr.decode(errors="replace").strip()
        raise ValueError(error or f"git {' '.join(args)} failed")
    return result.stdout


def _normalize_allowed(paths: list[str]) -> list[str]:
    normalized: list[str] = []
    for value in paths:
        candidate = value.replace("\\", "/").strip().rstrip("/")
        parts = Path(candidate).parts
        if not candidate or candidate.startswith("/") or ".." in parts or candidate == ".":
            raise ValueError(f"unsafe allowed path: {value!r}")
        normalized.append(candidate)
    return normalized


def _under(path: str, roots: list[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in roots)


def _keep(paths: list[str], excluded: list[str]) -> list[str]:
    return sorted({path for path in paths if path and not _under(path, excluded)})


def _changed_paths(
    repo_root: Path, base_sha: str, excluded: list[str]
) -> tuple[list[str], list[str]]:
    """Repository-root-relative (tracked-diff, untracked) path sets.

    Both git invocations run from the repository root so their output shares one
    base. `git diff --name-only` is always root-relative, while `git ls-files
    --others` is relative to — and scoped to — its working directory; running it
    anywhere but the root would both mislabel paths and hide files created
    outside that subtree.
    """
    tracked = _git(repo_root, "diff", "--name-only", base_sha, "--").splitlines()
    untracked = _git(repo_root, "ls-files", "--others", "--exclude-standard").splitlines()
    return _keep(tracked, excluded), _keep(untracked, excluded)


def _ignored_paths(repo_root: Path, excluded: list[str]) -> list[str]:
    """Untracked files that .gitignore hides from `_changed_paths`.

    Always reported so an operator can see writes the scope gate would otherwise
    never surface; only enforced when the run opts into `strict_ignored`, because
    a test command routinely creates ignored build output (`__pycache__`,
    `.venv`) before the gate ever looks.
    """
    listed = _git(
        repo_root, "ls-files", "--others", "--ignored", "--exclude-standard"
    ).splitlines()
    return _keep(listed, excluded)


def _file_digest(repo_root: Path, relative: str) -> str:
    """Hash an untracked path without following a symlink outside the repository."""

    path = repo_root / relative
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        kind = b"symlink"
        content = os.readlink(path).encode()
    elif stat.S_ISREG(metadata.st_mode):
        try:
            path.resolve(strict=True).relative_to(repo_root.resolve())
        except ValueError as exc:
            raise ValueError(f"untracked path resolves outside repository: {relative}") from exc
        kind = b"file"
        content = path.read_bytes()
    else:
        raise ValueError(f"cannot attest non-file untracked path: {relative}")
    return hashlib.sha256(kind + b"\0" + content).hexdigest()


def _change_snapshot(
    repo_root: Path,
    base_sha: str,
    excluded: list[str],
    strict_ignored: bool,
) -> dict[str, Any]:
    """Return a canonical identity for the exact change set covered by the gate."""

    tracked_diff = _git_bytes(repo_root, "diff", "--binary", base_sha, "--")
    tracked, untracked = _changed_paths(repo_root, base_sha, excluded)
    ignored = _ignored_paths(repo_root, excluded)
    new_files = {path: _file_digest(repo_root, path) for path in untracked}
    ignored_files = (
        {path: _file_digest(repo_root, path) for path in ignored} if strict_ignored else {}
    )
    document = {
        "base_sha": base_sha,
        "tracked_diff_sha256": hashlib.sha256(tracked_diff).hexdigest(),
        "new_files": new_files,
        "ignored_files": ignored_files,
        "strict_ignored": strict_ignored,
    }
    encoded = json.dumps(
        document, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()
    return document | {
        "change_sha256": hashlib.sha256(encoded).hexdigest(),
        "changed_paths": sorted(set(tracked) | set(untracked)),
        "untracked_paths": untracked,
        "ignored_paths": ignored,
    }


def _attestation_covers(strict_ignored: bool) -> str:
    content = (
        "base SHA, tracked binary diff, and untracked and ignored file content digests"
        if strict_ignored
        else "base SHA, tracked binary diff, and untracked file content digests; ignored files excluded"
    )
    return f"{content}; HEAD SHA is informational and excluded"


def _snapshot_error(exc: OSError | ValueError) -> str:
    return f"{type(exc).__name__}: {exc}"


def _outside_scope(changed: list[str], allowed: list[str]) -> list[str]:
    return [path for path in changed if not _under(path, allowed)]


def _repo_relative(repo_root: Path, path: Path) -> str | None:
    try:
        relative = path.expanduser().resolve().relative_to(repo_root)
    except ValueError:
        return None
    return relative.as_posix() or None


def _role_prompt(state: GraphState, role: str) -> str:
    shared = (
        f"Task: {state['task']}\n"
        f"Specification: {state['spec_path']}\n"
        f"Workspace: {state['workspace']}\n"
        f"Attempt: {state.get('attempt', 0)}/{state.get('max_attempts', 2)}\n"
    )
    if role == "planner":
        return shared + "Produce a concise implementation plan. Do not edit files."
    if role == "researcher":
        return (
            shared
            + f"Plan:\n{state['plan']}\nIdentify relevant evidence and risks. Do not edit files."
        )
    if role == "coder":
        return (
            shared
            + f"Plan:\n{state['plan']}\nResearch:\n{state['research']}\n"
            + f"Previous review:\n{state.get('review', '(none)')}\n"
            + "Implement the task in the workspace. Stay within the specification."
        )
    return (
        shared
        + f"Plan:\n{state['plan']}\nResearch:\n{state['research']}\n"
        + f"Coder report:\n{state['code_report']}\nGate passed: {state['gate_passed']}\n"
        + "Review the current git diff. Do not edit files. End with exactly one line: "
        + "VERDICT: SHIP, VERDICT: NEEDS-FIX, VERDICT: DISCUSS, or VERDICT: OUT-OF-SCOPE."
    )


def build_graph(
    *,
    checkpointer: Any,
    artifact_root: Path,
    runner: Runner | None = None,
    state_root: Path | None = None,
):
    """Compile the graph with injected persistence and role execution boundaries."""

    role_runner = runner or RoleRunner()
    store = ArtifactStore(artifact_root)
    runtime_root = Path(state_root or artifact_root)

    def context_node(state: GraphState) -> dict[str, Any]:
        workspace = Path(state["workspace"]).expanduser().resolve()
        spec = Path(state["spec_path"]).expanduser().resolve()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,47}", state["project_id"]):
            raise ValueError("project_id must be a safe 1-48 character identifier")
        if not workspace.is_dir() or not spec.is_file():
            raise ValueError("workspace must be a directory and spec_path must be a file")
        allowed_paths = _normalize_allowed(state.get("allowed_paths", []))
        if not allowed_paths:
            raise ValueError("at least one allowed path is required")
        repo_root = Path(_git(workspace, "rev-parse", "--show-toplevel")).resolve()
        base_sha = _git(repo_root, "rev-parse", "HEAD")
        # The runtime's own state (checkpoint db + artifacts) is machine-written,
        # never coder-written, so it must not count against the scope gate.
        excluded = [
            relative
            for relative in (_repo_relative(repo_root, runtime_root),)
            if relative is not None
        ]
        strict_ignored = bool(state.get("strict_ignored", False))
        spec_text = spec.read_text(encoding="utf-8")
        artifact = store.write_json(
            state["run_id"],
            "00-context.json",
            {
                "workspace": str(workspace),
                "repo_root": str(repo_root),
                "spec_path": str(spec),
                "base_sha": base_sha,
                "allowed_paths": allowed_paths,
                "excluded_paths": excluded,
                "strict_ignored": strict_ignored,
            },
        )
        return {
            "schema_version": "graph-run-v1",
            "workspace": str(workspace),
            "repo_root": str(repo_root),
            "spec_path": str(spec),
            "spec_sha256": hashlib.sha256(spec_text.encode()).hexdigest(),
            "base_sha": base_sha,
            "allowed_paths": allowed_paths,
            "excluded_paths": excluded,
            "strict_ignored": strict_ignored,
            "attempt": 0,
            "max_attempts": int(state.get("max_attempts", 2)),
            "status": "running",
            "artifacts": [artifact],
        }

    def invoke_role(state: GraphState, role: str, name: str) -> tuple[str, dict, dict]:
        try:
            result = role_runner.run(
                f"langgraph-conductor.{role}",
                _role_prompt(state, role),
                Path(state["workspace"]),
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"{role} timed out after {exc.timeout}s") from exc
        if result.returncode:
            raise RuntimeError(f"{role} failed with exit code {result.returncode}: {result.output}")
        artifact = store.write(state["run_id"], name, result.output)
        return result.output, artifact, usage_record(result)

    def planner_node(state: GraphState) -> dict[str, Any]:
        output, artifact, usage = invoke_role(state, "planner", "10-plan.md")
        return {"plan": output, "artifacts": [artifact], "usage": [usage]}

    def researcher_node(state: GraphState) -> dict[str, Any]:
        output, artifact, usage = invoke_role(state, "researcher", "20-research.md")
        return {"research": output, "artifacts": [artifact], "usage": [usage]}

    def coder_node(state: GraphState) -> dict[str, Any]:
        attempt = state.get("attempt", 0) + 1
        staged = dict(state)
        staged["attempt"] = attempt
        output, artifact, usage = invoke_role(staged, "coder", f"30-code-attempt-{attempt}.md")
        return {
            "attempt": attempt,
            "code_report": output,
            "artifacts": [artifact],
            "usage": [usage],
        }

    def gate_node(state: GraphState) -> dict[str, Any]:
        command = state.get("test_command", [])
        errors: list[str] = []
        if not command:
            passed, returncode, output = False, 2, "test_command is required"
        else:
            try:
                completed = subprocess.run(
                    command,
                    cwd=state["workspace"],
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=GATE_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired as exc:
                # A hung test command is a gate failure, not a crashed run: record
                # it and let the bounded retry / human-stop paths handle it.
                passed, returncode = False, 124
                output = f"test command timed out after {GATE_TIMEOUT_SECONDS}s\n{exc.stdout or ''}"
                errors.append(f"gate attempt {state['attempt']}: test command timed out")
            else:
                passed, returncode = completed.returncode == 0, completed.returncode
                output = completed.stdout + completed.stderr
        repo_root = Path(state["repo_root"])
        excluded = state.get("excluded_paths", [])
        strict_ignored = bool(state.get("strict_ignored", False))
        try:
            snapshot = _change_snapshot(
                repo_root, state["base_sha"], excluded, strict_ignored
            )
        except SNAPSHOT_ERRORS as exc:
            message = _snapshot_error(exc)
            record = {
                "command": command,
                "returncode": returncode,
                "passed": False,
                "changed_paths": [],
                "untracked_paths": [],
                "ignored_paths": [],
                "strict_ignored": strict_ignored,
                "outside_scope": [],
                "gated_change_sha256": None,
                "snapshot_error": message,
                "output": output,
            }
            artifact = store.write_json(
                state["run_id"], f"40-gate-attempt-{state['attempt']}.json", record
            )
            return {
                "gate_passed": False,
                "gated_change_sha256": None,
                "reviewed_change_sha256": None,
                "artifacts": [artifact],
                "errors": [
                    *errors,
                    f"gate attempt {state['attempt']}: cannot attest change set: {message}",
                ],
            }
        changed = snapshot["changed_paths"]
        ignored = snapshot["ignored_paths"]
        scoped = sorted(set(changed) | set(ignored)) if strict_ignored else changed
        outside_scope = _outside_scope(scoped, state["allowed_paths"])
        passed = passed and not outside_scope
        record = {
            "command": command,
            "returncode": returncode,
            "passed": passed,
            "changed_paths": changed,
            "untracked_paths": snapshot["untracked_paths"],
            "ignored_paths": ignored,
            "strict_ignored": strict_ignored,
            "outside_scope": outside_scope,
            "gated_change_sha256": snapshot["change_sha256"],
            "attestation_covers": _attestation_covers(strict_ignored),
            "output": output,
        }
        artifact = store.write_json(
            state["run_id"], f"40-gate-attempt-{state['attempt']}.json", record
        )
        update: dict[str, Any] = {
            "gate_passed": passed,
            "gated_change_sha256": snapshot["change_sha256"],
            "reviewed_change_sha256": None,
            "artifacts": [artifact],
        }
        if errors:
            update["errors"] = errors
        return update

    def reviewer_node(state: GraphState) -> dict[str, Any]:
        repo_root = Path(state["repo_root"])
        excluded = state.get("excluded_paths", [])
        strict_ignored = bool(state.get("strict_ignored", False))
        gated_digest = state.get("gated_change_sha256")
        try:
            before = _change_snapshot(
                repo_root, state["base_sha"], excluded, strict_ignored
            )
        except SNAPSHOT_ERRORS as exc:
            message = _snapshot_error(exc)
            artifact = store.write_json(
                state["run_id"],
                f"54-pre-review-snapshot-error-attempt-{state['attempt']}.json",
                {
                    "gated_change_sha256": gated_digest,
                    "snapshot_error": message,
                    "note": "review skipped because the gated change set could not be revalidated",
                },
            )
            return {
                "verdict": "DISCUSS",
                "gate_passed": False,
                "reviewed_change_sha256": None,
                "artifacts": [artifact],
                "errors": [
                    f"review attempt {state['attempt']}: cannot attest pre-review change set: {message}"
                ],
            }

        unchanged_before_review = (
            bool(gated_digest) and before["change_sha256"] == gated_digest
        )
        if not unchanged_before_review:
            artifact = store.write_json(
                state["run_id"],
                f"55-pre-review-drift-attempt-{state['attempt']}.json",
                {
                    "gated_change_sha256": gated_digest,
                    "pre_review_change_sha256": before["change_sha256"],
                    "note": "change set mutated after the test/scope gate and before reviewer execution",
                },
            )
            return {
                "verdict": "NEEDS-FIX",
                "gate_passed": False,
                "reviewed_change_sha256": None,
                "artifacts": [artifact],
                "errors": [
                    f"review attempt {state['attempt']}: change set drifted before reviewer execution"
                ],
            }

        output, artifact, usage = invoke_role(
            state, "reviewer", f"50-review-attempt-{state['attempt']}.md"
        )
        verdict = parse_verdict(output)
        artifacts = [artifact]
        errors: list[str] = []
        try:
            after = _change_snapshot(
                repo_root, state["base_sha"], excluded, strict_ignored
            )
        except SNAPSHOT_ERRORS as exc:
            message = _snapshot_error(exc)
            drift = store.write_json(
                state["run_id"],
                f"56-post-review-snapshot-error-attempt-{state['attempt']}.json",
                {
                    "gated_change_sha256": gated_digest,
                    "pre_review_change_sha256": before["change_sha256"],
                    "snapshot_error": message,
                    "note": "reviewer output recorded, but its post-run change set could not be attested",
                },
            )
            artifacts.append(drift)
            errors.append(
                f"review attempt {state['attempt']}: cannot attest post-review change set: {message}"
            )
            verdict = "DISCUSS"
            unchanged_during_review = False
        else:
            unchanged_during_review = after["change_sha256"] == before["change_sha256"]
            if not unchanged_during_review:
                drift = store.write_json(
                    state["run_id"],
                    f"56-reviewer-mutation-attempt-{state['attempt']}.json",
                    {
                        "gated_change_sha256": gated_digest,
                        "pre_review_change_sha256": before["change_sha256"],
                        "post_review_change_sha256": after["change_sha256"],
                        "note": "reviewer execution mutated the workspace; reviewer roles are read-only",
                    },
                )
                artifacts.append(drift)
                errors.append(
                    f"review attempt {state['attempt']}: reviewer execution mutated the workspace"
                )
                verdict = "DISCUSS"
        if not state["gate_passed"] and verdict == "SHIP":
            verdict = "NEEDS-FIX"
        update: dict[str, Any] = {
            "review": output,
            "verdict": verdict,
            "gate_passed": state["gate_passed"] and unchanged_during_review,
            "reviewed_change_sha256": (
                before["change_sha256"] if unchanged_during_review else None
            ),
            "artifacts": artifacts,
            "usage": [usage],
        }
        if errors:
            update["errors"] = errors
        return update

    def approval_node(state: GraphState) -> dict[str, Any]:
        decision = interrupt(
            {
                "kind": "ship-approval",
                "thread_id": state["thread_id"],
                "verdict": state["verdict"],
                "base_sha": state["base_sha"],
                "attempt": state["attempt"],
                "reviewed_change_sha256": state.get("reviewed_change_sha256"),
            }
        )
        normalized = decision.get("decision") if isinstance(decision, dict) else decision
        if normalized not in {"approve", "reject"}:
            normalized = "reject"
        return {"approval": normalized}

    def publish_node(state: GraphState) -> dict[str, Any]:
        repo_root = Path(state["repo_root"])
        excluded = state.get("excluded_paths", [])
        expected = state.get("reviewed_change_sha256", "")
        strict_ignored = bool(state.get("strict_ignored", False))
        try:
            current = _change_snapshot(
                repo_root, state["base_sha"], excluded, strict_ignored
            )
        except SNAPSHOT_ERRORS as exc:
            message = _snapshot_error(exc)
            artifact = store.write_json(
                state["run_id"],
                "91-approval-snapshot-error.json",
                {
                    "approved": False,
                    "reviewed_change_sha256": expected,
                    "snapshot_error": message,
                    "note": "approval blocked because the current change set could not be attested",
                },
            )
            return {
                "status": "needs-human",
                "artifacts": [artifact],
                "errors": [f"approval blocked: cannot attest current change set: {message}"],
            }
        if not expected or current["change_sha256"] != expected:
            drift = {
                "approved": False,
                "reviewed_change_sha256": expected,
                "current_change_sha256": current["change_sha256"],
                "changed_paths": current["changed_paths"],
                "ignored_paths_not_attested": (
                    [] if state.get("strict_ignored") else current["ignored_paths"]
                ),
                "note": "approval blocked because the change set drifted after review",
            }
            artifact = store.write_json(
                state["run_id"], "91-approval-change-drift.json", drift
            )
            return {
                "status": "needs-human",
                "artifacts": [artifact],
                "errors": ["approval blocked: change set differs from reviewed digest"],
            }
        receipt = {
            "approved": True,
            "base_sha": state["base_sha"],
            "head_sha": _git(repo_root, "rev-parse", "HEAD"),
            "head_sha_attested": False,
            "tracked_diff_sha256": current["tracked_diff_sha256"],
            "new_files": current["new_files"],
            "ignored_files": current["ignored_files"],
            "change_sha256": current["change_sha256"],
            "reviewed_change_sha256": expected,
            "ignored_paths_not_attested": (
                [] if state.get("strict_ignored") else current["ignored_paths"]
            ),
            "covers": _attestation_covers(strict_ignored),
            "note": "approval receipt only; this runtime never pushes or force-merges",
        }
        artifact = store.write_json(state["run_id"], "90-approval-receipt.json", receipt)
        return {"status": "approved", "artifacts": [artifact]}

    def stop_node(state: GraphState) -> dict[str, Any]:
        status = "rejected" if state.get("approval") == "reject" else "needs-human"
        return {"status": status}

    builder = StateGraph(GraphState)
    builder.add_node("context", context_node)
    builder.add_node("planner", planner_node)
    builder.add_node("researcher", researcher_node)
    builder.add_node("coder", coder_node)
    builder.add_node("gate", gate_node)
    builder.add_node("reviewer", reviewer_node)
    builder.add_node("approval", approval_node)
    builder.add_node("publish", publish_node)
    builder.add_node("stop", stop_node)
    builder.add_edge(START, "context")
    builder.add_edge("context", "planner")
    builder.add_edge("planner", "researcher")
    builder.add_edge("researcher", "coder")
    builder.add_edge("coder", "gate")
    builder.add_edge("gate", "reviewer")
    builder.add_conditional_edges(
        "reviewer",
        lambda state: review_route(
            state["verdict"], state["attempt"], state.get("max_attempts", 2)
        ),
        {"approval": "approval", "retry": "coder", "stop": "stop"},
    )
    builder.add_conditional_edges(
        "approval",
        lambda state: approval_route(state["approval"]),
        {"publish": "publish", "stop": "stop"},
    )
    builder.add_edge("publish", END)
    builder.add_edge("stop", END)
    return builder.compile(checkpointer=checkpointer)
