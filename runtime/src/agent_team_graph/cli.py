"""Command-line interface for starting, inspecting, and resuming durable runs."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import sqlite3
import stat
import sys
import uuid
from collections.abc import Iterator
from contextlib import contextmanager, nullcontext
from pathlib import Path
from typing import Any

from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command, Overwrite

from .artifacts import ArtifactStore, directory_fd
from .graph import (
    GATE_TIMEOUT_SECONDS,
    ROLE_TIMEOUT_SECONDS,
    build_graph,
    initial_workspace_changes,
    resume_graph,
    validate_run_input,
    validate_timeout,
)
from .process import Cancellation, signal_handlers
from .registry import RegistryError, RoleRunner


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--state-dir", type=Path, default=Path(".agent-team"),
        help="checkpoint directory relative to the invocation cwd (default: .agent-team)",
    )


def _timeout(value: str) -> int:
    try:
        return validate_timeout(int(value), label="timeout")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agent-team-graph")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="start a bounded role workflow")
    _common(run)
    run.add_argument("--project-id", required=True)
    run.add_argument("--workspace", type=Path, default=Path.cwd())
    run.add_argument("--spec", type=Path, required=True)
    run.add_argument("--task", required=True)
    run.add_argument("--test-command", required=True, help="quoted argv; no shell operators")
    run.add_argument(
        "--allow-path",
        action="append",
        required=True,
        help="repository-relative file or directory; repeat as needed",
    )
    run.add_argument(
        "--exclude-path",
        action="append",
        default=[],
        help="trusted repository-relative path omitted from scope checks and attestation; repeat as needed",
    )
    run.add_argument("--max-attempts", type=int, default=2, choices=tuple(range(1, 6)))
    run.add_argument(
        "--strict-ignored",
        action="store_true",
        help="fail the scope gate on .gitignore'd writes outside --allow-path too",
    )
    run.add_argument("--role-timeout", type=_timeout, default=ROLE_TIMEOUT_SECONDS,
                     metavar="SECONDS", help="per role call (default: %(default)s)")
    run.add_argument("--gate-timeout", type=_timeout, default=GATE_TIMEOUT_SECONDS,
                     metavar="SECONDS", help="per test command run (default: %(default)s)")
    run.add_argument("--thread-id")
    status = sub.add_parser("status", help="show checkpointed state")
    _common(status)
    status.add_argument("--thread-id", required=True)
    resume = sub.add_parser("resume", help="continue a non-interrupted checkpoint")
    _common(resume)
    resume.add_argument("--thread-id", required=True)
    approve = sub.add_parser("approve", help="resume a ship approval interrupt")
    _common(approve)
    approve.add_argument("--thread-id", required=True)
    approve.add_argument("--decision", required=True, choices=("approve", "reject"))
    approve.add_argument(
        "--reviewed-digest", metavar="SHA256",
        help="reviewed_change_sha256 from status; required with --decision approve",
    )
    return parser


@contextmanager
def _open_runtime(state_dir: Path, cancellation: Cancellation | None = None) -> Iterator[Any]:
    state_dir = state_dir.expanduser().resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False)
    try:
        saver = SqliteSaver(connection)
        yield build_graph(
            checkpointer=saver,
            artifact_root=state_dir / "artifacts",
            state_root=state_dir,
            cancellation=cancellation,
        )
    finally:
        connection.close()


def _snapshot_view(snapshot: Any, thread_id: str) -> dict[str, Any]:
    values = dict(getattr(snapshot, "values", None) or {})
    next_nodes = tuple(getattr(snapshot, "next", ()))
    interrupts = getattr(snapshot, "interrupts", ())
    if not interrupts:
        interrupts = tuple(i for task in getattr(snapshot, "tasks", ()) for i in task.interrupts)
    awaiting = next_nodes == ("approval",) and any(
        isinstance(i.value, dict) and i.value.get("kind") == "ship-approval" for i in interrupts
    )
    approval = values.get("approval")
    status = values.get("status", "not-found")
    approval_note = None
    if approval == "approve" and status != "approved":
        approval_note = "approve decision recorded; receipt blocked, see errors and artifacts"
    return {
        "thread_id": thread_id,
        "run_id": values.get("run_id"),
        "status": status,
        "verdict": values.get("verdict"),
        "attempt": values.get("attempt"),
        "gated_change_sha256": values.get("gated_change_sha256"),
        "reviewed_change_sha256": values.get("reviewed_change_sha256"),
        "excluded_paths_not_attested": values.get("excluded_paths", []),
        "approval": approval,
        "approval_note": approval_note,
        "awaiting_approval": awaiting,
        "next": list(next_nodes),
        "errors": values.get("errors", []),
        "artifacts": values.get("artifacts", []),
        "usage": values.get("usage", []),
    }


def _view(graph: Any, thread_id: str) -> dict[str, Any]:
    return _snapshot_view(graph.get_state({"configurable": {"thread_id": thread_id}}), thread_id)


def _exit_code(view: dict[str, Any]) -> int:
    if view["status"] == "not-found":
        return 5
    if view.get("awaiting_approval"):
        return 3
    if view["status"] == "approved" and not view.get("next"):
        return 0
    return 4


def _print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, default=str))


def _report(graph: Any, thread_id: str) -> int:
    view = _view(graph, thread_id)
    _print(view)
    return _exit_code(view)


@contextmanager
def _thread_lock(state_dir: Path, thread_id: str) -> Iterator[None]:
    name = hashlib.sha256(thread_id.encode("utf-8")).hexdigest() + ".lock"
    with directory_fd(state_dir / "locks") as parent:
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600, dir_fd=parent)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError("thread lock must be a regular file")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ValueError("thread is busy; retry after its active command finishes") from exc
            yield
        finally:
            # Never unlink: another process may already have this inode open.
            os.close(fd)


def _initial(args: argparse.Namespace, thread_id: str) -> dict[str, Any]:
    return {
        "schema_version": "graph-run-v1",
        "thread_id": thread_id, "run_id": uuid.uuid4().hex, "project_id": args.project_id,
        "workspace": str(args.workspace), "spec_path": str(args.spec), "task": args.task,
        "test_command": shlex.split(args.test_command), "allowed_paths": args.allow_path,
        "operator_excluded_paths": args.exclude_path, "max_attempts": args.max_attempts,
        "strict_ignored": args.strict_ignored,
        "role_timeout_seconds": args.role_timeout, "gate_timeout_seconds": args.gate_timeout,
        "repo_root": "", "spec_sha256": "", "base_sha": "", "excluded_paths": [],
        "execution_policy_version": 1, "attempt_start": "", "role_failed": False,
        "halted": False, "cancelled_signal": None,
        "attempt": 0, "plan": "", "research": "", "code_report": "", "review": "",
        "verdict": "", "approval": "", "status": "running",
        "gate_passed": False, "gate_feedback": "",
        "gated_change_sha256": None, "reviewed_change_sha256": None,
        "approved_change_sha256": None,
        "base_manifest_sha256": None, "attestation_ignore_rules": None,
        "artifacts": Overwrite([]), "usage": Overwrite([]), "errors": Overwrite([]),
    }


def _execute(args: argparse.Namespace, thread_id: str, state_dir: Path,
             cancellation: Cancellation) -> int:
    config = {"configurable": {"thread_id": thread_id}}
    if args.command != "run" and not (state_dir / "runs.sqlite3").exists():
        _print(_snapshot_view(None, thread_id))
        return 5
    initial = None
    if args.command == "run":
        initial = _initial(args, thread_id)
        context = validate_run_input(initial, state_dir)
    lock = nullcontext() if args.command == "status" else _thread_lock(state_dir, thread_id)
    with lock, _open_runtime(state_dir, cancellation) as graph:
        snapshot = graph.get_state(config)
        view = _snapshot_view(snapshot, thread_id)
        if args.command == "run":
            if view["status"] != "not-found" and (
                view["status"] not in {"approved", "rejected", "needs-human"}
                or snapshot.next or getattr(snapshot, "interrupts", ())
            ):
                _print(view | {"error": "thread is unfinished; use approve/reject or resume"})
                return 2
            ArtifactStore(state_dir / "artifacts").preflight()
            try:
                dirty = any(initial_workspace_changes(context).values())
            except (OSError, ValueError):
                # Let context_node record the workspace failure before trying
                # any model configuration. It rechecks the live tree on invoke.
                dirty = True
            if not dirty:
                RoleRunner().preflight(Path(initial["workspace"]).expanduser().resolve())
            payload = initial
        elif args.command == "status" or view["status"] == "not-found":
            _print(view)
            return _exit_code(view)
        elif args.command == "approve":
            if not view["awaiting_approval"]:
                _print(view | {"error": "approve requires a ship-approval interrupt"})
                return 2
            if not snapshot.values.get("base_manifest_sha256"):
                # Started before filesystem attestation: approval_node records
                # needs-human before asking, so no digest is needed to reach it.
                payload = Command(resume={"decision": args.decision,
                                          "reviewed_change_sha256": None})
            else:
                digest = args.reviewed_digest
                if args.decision == "approve":
                    reviewed = view["reviewed_change_sha256"]
                    if not digest:
                        _print(view | {"error": "approve requires --reviewed-digest; "
                                       "pass reviewed_change_sha256 from status"})
                        return 2
                    if not re.fullmatch(r"[a-f0-9]{64}", digest) or digest != reviewed:
                        _print(view | {"error": f"--reviewed-digest {digest} is not the reviewed "
                                       f"change set {reviewed}; re-read status before approving"})
                        return 2
                else:
                    # Rejecting is always safe; it must not depend on what the caller saw.
                    digest = None
                payload = Command(resume={"decision": args.decision,
                                          "reviewed_change_sha256": digest})
        elif view["awaiting_approval"] and snapshot.values.get("base_manifest_sha256"):
            _print(view | {"note": "use approve --decision approve --reviewed-digest "
                           "<reviewed_change_sha256>, or approve --decision reject"})
            return 3
        elif not snapshot.next:
            _print(view)
            return _exit_code(view)
        else:
            if snapshot.values.get("execution_policy_version") != 1 and any(
                node in {"planner", "researcher", "coder", "gate", "reviewer"} for node in snapshot.next
            ):
                _print(view | {"error": "legacy interrupted call has no outcome records; inspect "
                               "the workspace and start a new run; checkpoint preserved"})
                return 4
            payload = None
        if cancellation.signal:
            _print(view | {"error": "execution cancelled before checkpoint update"})
            return 128 + cancellation.signal
        try:
            if args.command == "resume":
                resume_graph(graph, config)
            else:
                graph.invoke(payload, config=config, durability="sync")
        except Exception as exc:  # noqa: BLE001 - CLI boundary reports failed checkpoints without a traceback
            view = _view(graph, thread_id)
            _print(view | {"errors": [*view["errors"], f"{type(exc).__name__}: {exc}"]})
            return 128 + cancellation.signal if cancellation.signal else 4
        rc = _report(graph, thread_id)
        return 128 + cancellation.signal if cancellation.signal else rc


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    thread_id = args.thread_id
    if thread_id is None and args.command == "run":
        thread_id = f"{args.project_id}-{uuid.uuid4().hex[:12]}"
    try:
        if not thread_id or "\0" in thread_id:
            raise ValueError("thread_id must be nonempty and contain no NUL bytes")
        cancellation = Cancellation()
        with signal_handlers(cancellation):
            return _execute(args, thread_id, args.state_dir.expanduser().resolve(), cancellation)
    except (ValueError, OSError, RegistryError) as exc:
        _print({"thread_id": thread_id, "error": f"{type(exc).__name__}: {exc}"})
        return 2


if __name__ == "__main__":
    sys.exit(main())
