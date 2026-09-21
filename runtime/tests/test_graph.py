from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest
from helpers import FakeRunner, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph.graph import build_graph
from agent_team_graph.registry import ModelRegistry, RoleRunner


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


def test_researcher_exit_zero_without_answer_stops_before_coding(tmp_path: Path):
    """stderr-only research (agy soft-deny) must not reach the coder."""
    import json
    import sys

    from agent_team_graph.registry import ModelRegistry, RoleRunner

    answer = ["-c", "print('an answer')", "{prompt}"]
    denied = ["-c", "import sys; sys.stderr.write('auto-denied\\n')", "{prompt}"]
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {
                    "ok": {"command": sys.executable, "args": answer},
                    "denied": {"command": sys.executable, "args": denied},
                },
                "roles": {
                    "langgraph-conductor.planner": "ok",
                    "langgraph-conductor.researcher": "denied",
                    "langgraph-conductor.coder": "ok",
                    "langgraph-conductor.reviewer": "ok",
                },
            }
        ),
        encoding="utf-8",
    )
    workspace, spec = make_repo(tmp_path)
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    graph = build_graph(
        checkpointer=SqliteSaver(connection),
        artifact_root=tmp_path / "artifacts",
        runner=RoleRunner(ModelRegistry(config)),
    )
    config_ = {"configurable": {"thread_id": "denied-thread"}}
    graph.invoke(initial(workspace, spec, "denied-thread"), config=config_)
    values = graph.get_state(config_).values
    assert values["status"] == "needs-human"
    assert values["attempt"] == 2
    assert len(values["usage"]) == 3  # one planner, two failed research calls
    assert all("researcher" in error and "exit code 5" in error for error in values["errors"])
    assert not list((tmp_path / "artifacts").rglob("20-research.md"))
    assert not list((tmp_path / "artifacts").rglob("30-code-attempt-*.md"))


def _parked(tmp_path: Path, connection=None):
    workspace, spec = make_repo(tmp_path)
    connection = connection or sqlite3.connect(":memory:", check_same_thread=False)
    graph = build_graph(checkpointer=SqliteSaver(connection),
                        artifact_root=tmp_path / "artifacts", runner=FakeRunner())
    config = {"configurable": {"thread_id": "demo-thread"}}
    graph.invoke(initial(workspace, spec), config=config)
    assert graph.get_state(config).next == ("approval",)
    return graph, config


def test_approval_for_another_digest_blocks_without_receipt(tmp_path: Path):
    graph, config = _parked(tmp_path)
    graph.invoke(Command(resume={"decision": "approve", "reviewed_change_sha256": "0" * 64}),
                 config=config)
    values = graph.get_state(config).values
    assert values["status"] == "needs-human" and values["approval"] == "approve"
    assert values["approved_change_sha256"] == "0" * 64
    assert values["errors"] == ["approval blocked: approved digest differs from reviewed digest"]
    assert not list((tmp_path / "artifacts").rglob("90-approval-receipt.json"))


@pytest.mark.parametrize("bound", [False, True])
def test_publish_replays_its_receipt_after_a_crash(tmp_path: Path, monkeypatch, bound):
    """A receipt written just before a crash is rewritten byte-identical on resume."""
    from agent_team_graph.artifacts import ArtifactStore
    from agent_team_graph.graph import resume_graph

    graph, config = _parked(tmp_path)
    digest = graph.get_state(config).values["reviewed_change_sha256"]
    real_write = ArtifactStore.write_json

    def crash_after_receipt(self, run_id, name, value):
        record = real_write(self, run_id, name, value)
        if name == "90-approval-receipt.json":
            raise RuntimeError("simulated crash after the receipt write")
        return record

    monkeypatch.setattr(ArtifactStore, "write_json", crash_after_receipt)
    decision = ({"decision": "approve", "reviewed_change_sha256": digest} if bound
                else "approve")
    with pytest.raises(RuntimeError, match="simulated crash"):
        graph.invoke(Command(resume=decision), config=config, durability="sync")
    assert graph.get_state(config).next == ("publish",)
    receipt = next((tmp_path / "artifacts").rglob("90-approval-receipt.json"))
    before = receipt.read_bytes()
    monkeypatch.setattr(ArtifactStore, "write_json", real_write)
    resume_graph(graph, config)
    values = graph.get_state(config).values
    assert values["status"] == "approved" and receipt.read_bytes() == before
    assert ("approved_change_sha256" in json.loads(before)) is bound


def _slow_models(tmp_path: Path) -> Path:
    config = tmp_path / "models.json"
    config.write_text(json.dumps({
        "models": {"slow": {"command": sys.executable,
                            "args": ["-c", "import time; time.sleep(30)", "{prompt}"]}},
        "roles": {role: "slow" for role in (
            "langgraph-conductor.planner", "langgraph-conductor.researcher",
            "langgraph-conductor.coder", "langgraph-conductor.reviewer")},
    }))
    return config


@pytest.mark.parametrize("configured_by", ["state", "injected-runner"])
def test_role_timeout_reaches_the_builtin_runner(tmp_path: Path, configured_by):
    """State wins when given; otherwise an injected RoleRunner keeps its own timeout."""
    by_state = configured_by == "state"
    runner = RoleRunner(ModelRegistry(_slow_models(tmp_path)),
                        **({} if by_state else {"timeout_seconds": 1}))
    workspace, spec = make_repo(tmp_path)
    graph = build_graph(checkpointer=SqliteSaver(sqlite3.connect(":memory:",
                                                                 check_same_thread=False)),
                        artifact_root=tmp_path / "artifacts", runner=runner)
    state = initial(workspace, spec) | {"max_attempts": 1}
    if by_state:
        state["role_timeout_seconds"] = 1
    thread = {"configurable": {"thread_id": "demo-thread"}}
    started = time.monotonic()
    graph.invoke(state, config=thread)
    assert time.monotonic() - started < 15
    values = graph.get_state(thread).values
    assert values["status"] == "needs-human"
    assert values["errors"] == ["planner attempt 1 failed with exit code 124 (timeout)"]
    failure = next((tmp_path / "artifacts").rglob("failure-1-planner.json"))
    assert "role timed out after 1s" in json.loads(failure.read_text())["stderr"]
    assert ("role_timeout_seconds" in values) is by_state


@pytest.mark.parametrize("field", ["role_timeout_seconds", "gate_timeout_seconds"])
@pytest.mark.parametrize("value", [0, 86401, True, 1.5, "60"])
def test_direct_callers_get_the_same_timeout_bounds(tmp_path: Path, field, value):
    from agent_team_graph.graph import validate_run_input

    workspace, spec = make_repo(tmp_path)
    with pytest.raises(ValueError, match=field):
        validate_run_input(initial(workspace, spec) | {field: value}, tmp_path / "state")


def test_instance_level_run_override_keeps_the_three_argument_protocol(tmp_path: Path):
    runner = RoleRunner()
    fake = FakeRunner()
    runner.run = fake.run  # three arguments; must not receive timeout=
    runner.preflight = lambda workspace: None
    runner.resolve_adapter = lambda role, workspace: ("fake", {"args": []}, "fake-model")
    workspace, spec = make_repo(tmp_path)
    graph = build_graph(checkpointer=SqliteSaver(sqlite3.connect(":memory:",
                                                                 check_same_thread=False)),
                        artifact_root=tmp_path / "artifacts", runner=runner)
    thread = {"configurable": {"thread_id": "demo-thread"}}
    graph.invoke(initial(workspace, spec) | {"role_timeout_seconds": 5}, config=thread)
    assert graph.get_state(thread).next == ("approval",)
    assert len(fake.roles) == 4
