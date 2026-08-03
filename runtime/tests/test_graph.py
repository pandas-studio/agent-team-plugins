from __future__ import annotations

import sqlite3
from pathlib import Path

from helpers import FakeRunner, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph.graph import build_graph


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
