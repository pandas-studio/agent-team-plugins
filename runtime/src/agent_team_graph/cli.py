"""Command-line interface for starting, inspecting, and resuming durable runs."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shlex
import signal
import sqlite3
import sys
import threading
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from .graph import build_graph


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--state-dir", type=Path, default=Path(".agent-team"))


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
    run.add_argument(
        "--max-attempts",
        type=int,
        default=2,
        choices=tuple(range(1, 6)),
        help="coder attempts, not retries (2 = one retry)",
    )
    run.add_argument(
        "--strict-ignored",
        action="store_true",
        help="fail the scope gate on .gitignore'd writes outside --allow-path too",
    )
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
    return parser


@contextmanager
def _open_runtime(state_dir: Path) -> Iterator[Any]:
    connection = sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False)
    try:
        saver = SqliteSaver(connection)
        yield build_graph(
            checkpointer=saver,
            artifact_root=state_dir / "artifacts",
            state_root=state_dir,
        )
    finally:
        connection.close()


@contextmanager
def _thread_lock(state_dir: Path, thread_id: str) -> Iterator[bool]:
    """Hold this thread's lock for the block; yields False if another process has it.

    One process per thread: without it two `run`s could both find a thread id
    unused, and `status` could not tell an active run from a crashed one. The
    lock file is never deleted (that would reopen the race); only a held lock
    means busy. flock is advisory: processes older than this lock never take it.
    """
    locks = state_dir / "locks"
    locks.mkdir(exist_ok=True)
    name = hashlib.sha256(thread_id.encode()).hexdigest()[:32]
    with open(locks / f"{name}.lock", "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


TERMINAL_STATUSES = ("approved", "rejected", "needs-human")


def _thread_exists(snapshot: Any) -> bool:
    # A checkpoint, not a status: a run that crashed inside `context` has one but
    # never set `status`.
    return snapshot.created_at is not None


def _status(snapshot: Any) -> str:
    if not _thread_exists(snapshot):
        return "not-found"
    status = (snapshot.values or {}).get("status")
    if status in TERMINAL_STATUSES:
        return status
    # Called under the thread lock, so nothing is executing: a non-terminal
    # checkpoint is either parked at the approval interrupt or stopped early.
    return "running" if snapshot.interrupts else "incomplete"


def _view(graph: Any, thread_id: str) -> dict[str, Any]:
    snapshot = graph.get_state({"configurable": {"thread_id": thread_id}})
    values = dict(snapshot.values or {})
    approval = values.get("approval")
    status = _status(snapshot)
    approval_note = None
    if approval == "approve" and status != "approved":
        approval_note = "approve decision recorded; receipt blocked, see errors and artifacts"
    return {
        "thread_id": thread_id,
        "status": status,
        "verdict": values.get("verdict"),
        "attempt": values.get("attempt"),
        "gated_change_sha256": values.get("gated_change_sha256"),
        "reviewed_change_sha256": values.get("reviewed_change_sha256"),
        "excluded_paths_not_attested": values.get("excluded_paths", []),
        "approval": approval,
        "approval_note": approval_note,
        "next": list(snapshot.next),
        "errors": values.get("errors", []),
        "artifacts": values.get("artifacts", []),
        "usage": values.get("usage", []),
    }


# Exit codes let a wrapper branch on the outcome without parsing the JSON body:
# 0 approved, 3 still open (parked at the ship-approval interrupt), 4 stopped
# without approval, 5 unknown thread, 6 stopped before reaching approval (crash
# or interruption; `resume` continues), 7 busy in another process. 2 is a usage
# error (argparse, or `run` on an existing thread).
EXIT_BY_STATUS = {
    "approved": 0,
    "running": 3,
    "rejected": 4,
    "needs-human": 4,
    "not-found": 5,
    "incomplete": 6,
    "busy": 7,
}


def _exit_code(view: dict[str, Any]) -> int:
    return EXIT_BY_STATUS.get(view["status"], 4)


def _print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, default=str))


def _report(graph: Any, thread_id: str) -> int:
    view = _view(graph, thread_id)
    _print(view)
    return _exit_code(view)


def _invoke(graph: Any, value: Any, config: dict[str, Any]) -> None:
    """Run the graph; a failure is reported, and the view then says `incomplete`."""
    try:
        graph.invoke(value, config=config)
    except Exception as exc:  # noqa: BLE001 - the CLI boundary reports every failure
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)


class _Terminated(BaseException):
    """SIGTERM/SIGHUP as an exception, so `run_bounded` ends the role's group."""

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


_TERMINATING_SIGNALS = (signal.SIGTERM, signal.SIGHUP)


@contextmanager
def _terminate_as_exception() -> Iterator[None]:
    """Turn SIGTERM/SIGHUP into `_Terminated` for the block.

    Roles run in their own session (so a timeout can kill the whole group), which
    also keeps a signal sent to this CLI or its job from reaching them. Raising
    lets the cleanup in `run_bounded` kill the group before the thread lock is
    released. A signal already ignored (`nohup`) stays ignored; signal handlers
    can only be set from the main thread, so other threads are left as they are.
    """

    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def handler(signum: int, frame: Any) -> None:
        raise _Terminated(signum)

    previous = {}
    for signum in _TERMINATING_SIGNALS:
        if signal.getsignal(signum) is signal.SIG_IGN:
            continue
        previous[signum] = signal.signal(signum, handler)
    try:
        yield
    finally:
        for signum, old in previous.items():
            signal.signal(signum, old)


def main(argv: list[str] | None = None) -> int:
    """The CLI entry point; it owns the process.

    On SIGTERM/SIGHUP it cleans up and then dies of the same signal, so a caller
    that needs to survive those must run it in a subprocess.
    """
    args = build_parser().parse_args(argv)
    try:
        with _terminate_as_exception():
            return _main(args)
    except _Terminated as exc:
        # Cleaned up and unlocked; now die of the signal, as the caller expects.
        signal.signal(exc.signum, signal.SIG_DFL)
        os.kill(os.getpid(), exc.signum)
        return 128 + exc.signum


def _main(args: argparse.Namespace) -> int:
    state_dir = args.state_dir.expanduser().resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    if args.command == "run":
        thread_id = args.thread_id or f"{args.project_id}-{uuid.uuid4().hex[:12]}"
    else:
        thread_id = args.thread_id
    config = {"configurable": {"thread_id": thread_id}}
    with _thread_lock(state_dir, thread_id) as held, _open_runtime(state_dir) as graph:
        if not held:
            if args.command != "status":
                print(f"error: thread {thread_id} is busy in another process", file=sys.stderr)
            _print({"thread_id": thread_id, "status": "busy"})
            return EXIT_BY_STATUS["busy"]
        exists = _thread_exists(graph.get_state(config))
        if args.command == "run":
            if exists:
                # Re-running would inherit the old run's review, approval and
                # verdict, and silently drop a pending approval interrupt.
                print(
                    f"error: thread {thread_id} already exists; use status, resume or "
                    "approve, or omit --thread-id to start a new run",
                    file=sys.stderr,
                )
                return 2
            initial = {
                "thread_id": thread_id,
                "run_id": uuid.uuid4().hex,
                "project_id": args.project_id,
                "workspace": str(args.workspace),
                "spec_path": str(args.spec),
                "task": args.task,
                "test_command": shlex.split(args.test_command),
                "allowed_paths": args.allow_path,
                "operator_excluded_paths": args.exclude_path,
                "max_attempts": args.max_attempts,
                "strict_ignored": args.strict_ignored,
                "artifacts": [],
                "usage": [],
                "errors": [],
            }
            _invoke(graph, initial, config)
            return _report(graph, thread_id)
        if args.command == "status" or not exists:
            # resume/approve on an unknown thread would start a new, empty run.
            return _report(graph, thread_id)
        if args.command == "resume":
            _invoke(graph, None, config)
            return _report(graph, thread_id)
        if args.command == "approve":
            _invoke(graph, Command(resume=args.decision), config)
            return _report(graph, thread_id)
    return 2


if __name__ == "__main__":
    sys.exit(main())
