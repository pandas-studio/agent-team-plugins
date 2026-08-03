"""Command-line interface for starting, inspecting, and resuming durable runs."""

from __future__ import annotations

import argparse
import json
import shlex
import sqlite3
import sys
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
    run.add_argument("--max-attempts", type=int, default=2, choices=range(1, 6))
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
    state_dir = state_dir.expanduser().resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False)
    try:
        saver = SqliteSaver(connection)
        yield build_graph(checkpointer=saver, artifact_root=state_dir / "artifacts")
    finally:
        connection.close()


def _view(graph: Any, thread_id: str) -> dict[str, Any]:
    snapshot = graph.get_state({"configurable": {"thread_id": thread_id}})
    values = dict(snapshot.values or {})
    return {
        "thread_id": thread_id,
        "status": values.get("status", "not-found"),
        "verdict": values.get("verdict"),
        "attempt": values.get("attempt"),
        "next": list(snapshot.next),
        "artifacts": values.get("artifacts", []),
        "usage": values.get("usage", []),
    }


def _print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, default=str))


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    with _open_runtime(args.state_dir) as graph:
        config = {"configurable": {"thread_id": args.thread_id}}
        if args.command == "run":
            thread_id = args.thread_id or f"{args.project_id}-{uuid.uuid4().hex[:12]}"
            config = {"configurable": {"thread_id": thread_id}}
            initial = {
                "thread_id": thread_id,
                "run_id": uuid.uuid4().hex,
                "project_id": args.project_id,
                "workspace": str(args.workspace),
                "spec_path": str(args.spec),
                "task": args.task,
                "test_command": shlex.split(args.test_command),
                "allowed_paths": args.allow_path,
                "max_attempts": args.max_attempts,
                "artifacts": [],
                "usage": [],
                "errors": [],
            }
            graph.invoke(initial, config=config)
            _print(_view(graph, thread_id))
            return 0
        if args.command == "status":
            _print(_view(graph, args.thread_id))
            return 0
        if args.command == "resume":
            graph.invoke(None, config=config)
            _print(_view(graph, args.thread_id))
            return 0
        if args.command == "approve":
            graph.invoke(Command(resume=args.decision), config=config)
            _print(_view(graph, args.thread_id))
            return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
