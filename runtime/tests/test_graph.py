from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from helpers import FakeRunner, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph.graph import build_graph
from agent_team_graph.registry import RoleResult


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

    import pytest

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
    with pytest.raises(RuntimeError, match="researcher failed with exit code 5"):
        graph.invoke(initial(workspace, spec, "denied-thread"), config=config_)
    assert not list((tmp_path / "artifacts").rglob("20-research.md"))
    assert not list((tmp_path / "artifacts").rglob("30-code-attempt-*.md"))


def _graph(tmp_path: Path, runner):
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    return build_graph(
        checkpointer=SqliteSaver(connection), artifact_root=tmp_path / "artifacts", runner=runner
    )


def _names(snapshot) -> list[str]:
    return [item["name"] for item in snapshot.values["artifacts"]]


class TimingRunner(FakeRunner):
    """Scripted per-call timeouts: `timeouts[role]` lists which calls (1-based) time out."""

    def __init__(self, verdicts=None, timeouts=None, writes=None):
        super().__init__(verdicts, writes)
        self.timeouts = timeouts or {}
        self.calls: dict[str, int] = {}

    def run(self, role, prompt, workspace):
        short = role.rsplit(".", 1)[1]
        self.calls[short] = self.calls.get(short, 0) + 1
        if self.calls[short] in self.timeouts.get(short, ()):
            self.roles.append(role)
            return RoleResult("fake-id", role, "fake", "cut off", 124, 1, timed_out=True)
        return super().run(role, prompt, workspace)


def test_a_change_outside_scope_before_the_run_refuses_the_start(tmp_path: Path):
    """The README example (uncommitted SPEC.md) used to fail every paid attempt."""
    workspace, spec = make_repo(tmp_path)
    (workspace / "SPEC.md").write_text("uncommitted spec\n", encoding="utf-8")
    runner = FakeRunner()
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "dirty"}}
    graph.invoke(initial(workspace, spec, "dirty"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.values["status"] == "needs-human"
    assert runner.roles == []
    refusal = next(
        a for a in snapshot.values["artifacts"] if a["name"] == "05-preexisting-changes.json"
    )
    assert json.loads(Path(refusal["path"]).read_text())["outside_scope"] == ["SPEC.md"]
    assert "pre-existing" in snapshot.values["errors"][0]


def test_a_change_inside_scope_before_the_run_is_kept_and_recorded(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    (workspace / "README.md").write_text("edited before the run\n", encoding="utf-8")
    graph = _graph(tmp_path, FakeRunner())
    config = {"configurable": {"thread_id": "inside"}}
    graph.invoke(initial(workspace, spec, "inside"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.next == ("approval",)
    context = next(a for a in snapshot.values["artifacts"] if a["name"] == "00-context.json")
    assert json.loads(Path(context["path"]).read_text())["preexisting_changes"] == ["README.md"]


def test_a_gate_snapshot_error_is_not_reported_as_drift(tmp_path: Path, monkeypatch):
    import inspect

    import agent_team_graph.graph as graph_module

    workspace, spec = make_repo(tmp_path)
    real_snapshot = graph_module._change_snapshot

    def fail_at_gate(*args, **kwargs):
        caller = inspect.currentframe().f_back
        if caller and caller.f_code.co_name == "gate_node":
            raise ValueError("simulated gate snapshot error")
        return real_snapshot(*args, **kwargs)

    monkeypatch.setattr(graph_module, "_change_snapshot", fail_at_gate)
    runner = FakeRunner()
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "gate-error"}}
    graph.invoke(initial(workspace, spec, "gate-error"), config=config)
    snapshot = graph.get_state(config)
    assert not any("drift" in name for name in _names(snapshot))
    assert not any(role.endswith(".reviewer") for role in runner.roles)
    assert any("gate could not attest" in error for error in snapshot.values["errors"])
    assert not any("drifted" in error for error in snapshot.values["errors"])
    assert runner.roles.count("langgraph-conductor.coder") == 2
    assert snapshot.values["status"] == "needs-human"


def test_a_coder_timeout_is_a_failed_attempt_and_the_retry_is_gated_and_reviewed(
    tmp_path: Path,
):
    runner = TimingRunner(timeouts={"coder": [1]})
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "coder-timeout"}}
    graph.invoke(initial(workspace, spec, "coder-timeout"), config=config)
    snapshot = graph.get_state(config)
    names = _names(snapshot)
    # Attempt 1 skipped the gate and the paid review; attempt 2 went through both.
    assert "40-gate-attempt-1.json" not in names
    assert "50-review-attempt-1.md" not in names
    assert "40-gate-attempt-2.json" in names and "50-review-attempt-2.md" in names
    assert snapshot.next == ("approval",)
    assert snapshot.values["attempt"] == 2


def test_a_coder_timeout_on_the_last_attempt_stops_for_a_human(tmp_path: Path):
    runner = TimingRunner(verdicts=["NEEDS-FIX"], timeouts={"coder": [2]})
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "last-timeout"}}
    graph.invoke(initial(workspace, spec, "last-timeout"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.values["status"] == "needs-human"
    assert snapshot.values["reviewed_change_sha256"] is None
    assert snapshot.values["gated_change_sha256"] is None
    assert "40-gate-attempt-2.json" not in _names(snapshot)


def test_a_planner_timeout_stops_without_crashing(tmp_path: Path):
    runner = TimingRunner(timeouts={"planner": [1]})
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "planner-timeout"}}
    graph.invoke(initial(workspace, spec, "planner-timeout"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.values["status"] == "needs-human"
    assert runner.roles == ["langgraph-conductor.planner"]


def test_a_reviewer_timeout_never_supplies_a_verdict(tmp_path: Path):
    class CutOffShip(TimingRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if result.timed_out and role.endswith(".reviewer"):
                return RoleResult("fake-id", role, "fake", "VERDICT: SHIP", 124, 1, timed_out=True)
            return result

    runner = CutOffShip(timeouts={"reviewer": [1]})
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": "reviewer-timeout"}}
    graph.invoke(initial(workspace, spec, "reviewer-timeout"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.values["verdict"] == "DISCUSS"
    assert snapshot.values["status"] == "needs-human"
    assert runner.roles.count("langgraph-conductor.coder") == 1


def test_a_role_that_exits_124_itself_is_still_a_resumable_crash(tmp_path: Path):
    import pytest

    class Exits124(FakeRunner):
        def run(self, role, prompt, workspace):
            if role.endswith(".coder"):
                return RoleResult("fake-id", role, "fake", "own 124", 124, 1)
            return super().run(role, prompt, workspace)

    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, Exits124())
    config = {"configurable": {"thread_id": "own-124"}}
    with pytest.raises(RuntimeError, match="exit code 124"):
        graph.invoke(initial(workspace, spec, "own-124"), config=config)
    assert graph.get_state(config).next == ("coder",)


def test_gate_output_that_is_not_utf8_is_recorded(tmp_path: Path):
    import sys

    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner())
    config = {"configurable": {"thread_id": "bad-bytes"}}
    state = initial(workspace, spec, "bad-bytes")
    state["test_command"] = [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\xff')"]
    graph.invoke(state, config=config)
    snapshot = graph.get_state(config)
    gate = next(a for a in snapshot.values["artifacts"] if a["name"] == "40-gate-attempt-1.json")
    assert json.loads(Path(gate["path"]).read_text())["output"] == "\ufffd"


def test_a_gate_timeout_records_partial_output_as_text(tmp_path: Path, monkeypatch):
    import sys

    import agent_team_graph.graph as graph_module

    monkeypatch.setattr(graph_module, "GATE_TIMEOUT_SECONDS", 1)
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner())
    config = {"configurable": {"thread_id": "gate-timeout"}}
    state = initial(workspace, spec, "gate-timeout")
    state["max_attempts"] = 1
    state["test_command"] = [
        sys.executable, "-c", "import time; print('partial', flush=True); time.sleep(30)"
    ]
    graph.invoke(state, config=config)
    snapshot = graph.get_state(config)
    gate = next(a for a in snapshot.values["artifacts"] if a["name"] == "40-gate-attempt-1.json")
    output = json.loads(Path(gate["path"]).read_text())["output"]
    assert output == "test command timed out after 1s\npartial\n"
