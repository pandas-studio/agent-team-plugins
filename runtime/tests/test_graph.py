from __future__ import annotations

import sqlite3
import subprocess
from pathlib import Path

from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph.graph import build_graph
from agent_team_graph.registry import RoleResult


class FakeRunner:
    def __init__(self, verdicts: list[str] | None = None):
        self.verdicts = iter(verdicts or ["SHIP"])
        self.roles: list[str] = []

    def run(self, role: str, prompt: str, workspace: Path) -> RoleResult:
        self.roles.append(role)
        output = f"output from {role}"
        if role.endswith(".reviewer"):
            output = f"review complete\nVERDICT: {next(self.verdicts)}"
        return RoleResult("fake-id", role, "fake", output, 0, 1)


def make_repo(tmp_path: Path) -> tuple[Path, Path]:
    workspace = tmp_path / "repo"
    workspace.mkdir()
    subprocess.run(["git", "init", "-q", workspace], check=True)
    subprocess.run(["git", "-C", workspace, "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", workspace, "config", "user.name", "Test"], check=True)
    (workspace / "README.md").write_text("demo\n", encoding="utf-8")
    subprocess.run(["git", "-C", workspace, "add", "README.md"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "init"], check=True)
    spec = tmp_path / "SPEC.md"
    spec.write_text("# bounded task\n", encoding="utf-8")
    return workspace, spec


def initial(workspace: Path, spec: Path, thread_id: str = "demo-thread") -> dict:
    return {
        "thread_id": thread_id,
        "run_id": f"run-{thread_id}",
        "project_id": "demo",
        "workspace": str(workspace),
        "spec_path": str(spec),
        "task": "implement one vertical slice",
        "test_command": ["git", "status", "--short"],
        "allowed_paths": ["README.md"],
        "max_attempts": 2,
        "artifacts": [],
        "usage": [],
        "errors": [],
    }


def test_ship_interrupt_is_checkpointed_and_resumed(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner()
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    graph = build_graph(
        checkpointer=SqliteSaver(connection), artifact_root=tmp_path / "artifacts", runner=runner
    )
    config = {"configurable": {"thread_id": "demo-thread"}}

    graph.invoke(initial(workspace, spec), config=config)
    paused = graph.get_state(config)
    assert paused.values["verdict"] == "SHIP"
    assert paused.values["status"] == "running"
    assert paused.next == ("approval",)

    graph.invoke(Command(resume="approve"), config=config)
    finished = graph.get_state(config)
    assert finished.values["status"] == "approved"
    assert finished.next == ()
    assert len(finished.values["usage"]) == 4
    assert Path(finished.values["artifacts"][-1]["path"]).name == "90-approval-receipt.json"


def test_needs_fix_retries_once_then_can_be_rejected(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner(["NEEDS-FIX", "SHIP"])
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    graph = build_graph(
        checkpointer=SqliteSaver(connection), artifact_root=tmp_path / "artifacts", runner=runner
    )
    config = {"configurable": {"thread_id": "retry-thread"}}
    graph.invoke(initial(workspace, spec, "retry-thread"), config=config)
    assert graph.get_state(config).values["attempt"] == 2
    assert runner.roles.count("langgraph-conductor.coder") == 2

    graph.invoke(Command(resume="reject"), config=config)
    assert graph.get_state(config).values["status"] == "rejected"
