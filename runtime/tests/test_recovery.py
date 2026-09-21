"""Failed attempts and durable recovery across fresh SQLite connections."""
from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

import pytest
from helpers import FakeRunner, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph

from agent_team_graph.artifacts import ArtifactStore
from agent_team_graph.cli import main
from agent_team_graph.graph import build_graph, resume_graph
from agent_team_graph.registry import RoleResult
from agent_team_graph.state import GraphState


@contextmanager
def persisted(tmp_path, runner):
    with sqlite3.connect(tmp_path / "runs.sqlite3", check_same_thread=False) as connection:
        yield build_graph(checkpointer=SqliteSaver(connection), artifact_root=tmp_path / "artifacts",
                          runner=runner)


class FailingRunner(FakeRunner):
    def __init__(self, stage, failures):
        super().__init__()
        self.stage = stage
        self.failures = failures

    def run(self, role, prompt, workspace):
        result = super().run(role, prompt, workspace)
        if role.endswith("." + self.stage) and self.failures:
            self.failures -= 1
            raise subprocess.TimeoutExpired(["fake-model"], 1, output=b"partial\xff\n")
        return result


@pytest.mark.parametrize("stage", ["planner", "researcher", "coder", "reviewer"])
@pytest.mark.parametrize("failures", [1, 10])
def test_role_timeout_counts_once_per_cycle_and_is_bounded(tmp_path, stage, failures):
    workspace, spec = make_repo(tmp_path)
    runner = FailingRunner(stage, failures)
    config = {"configurable": {"thread_id": "retry"}}
    with persisted(tmp_path, runner) as graph:
        graph.invoke(initial(workspace, spec, "retry"), config, durability="sync")
        snapshot = graph.get_state(config)
    assert snapshot.values["attempt"] == 2
    assert runner.roles.count(f"langgraph-conductor.{stage}") == 2
    assert len(snapshot.values["usage"]) == len(runner.roles)
    assert snapshot.next == (("approval",) if failures == 1 else ())
    if failures != 1:
        assert snapshot.values["status"] == "needs-human"
        if stage in {"planner", "researcher", "coder"}:
            assert "langgraph-conductor.reviewer" not in runner.roles
    if stage != "planner":
        assert runner.roles.count("langgraph-conductor.planner") == 1
    records = [a for a in snapshot.values["artifacts"] if a["name"].startswith("failure-")]
    result = json.loads(Path(records[0]["path"]).read_text())
    assert result["output"] == "partial\ufffd\n"
    assert result["timed_out"]
    assert snapshot.values["base_sha"]


@pytest.mark.parametrize("kind", ["nonzero", "blank"])
def test_failed_research_never_becomes_coder_context(tmp_path, kind):
    class Runner(FakeRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".researcher"):
                return RoleResult("failed", role, "fake", "FAILED-CONTEXT" if kind == "nonzero"
                                  else "  ", 9 if kind == "nonzero" else 0, 1)
            return result
    workspace, spec = make_repo(tmp_path)
    runner = Runner()
    config = {"configurable": {"thread_id": "research-failure"}}
    with persisted(tmp_path, runner) as graph:
        graph.invoke(initial(workspace, spec, "research-failure"), config, durability="sync")
        values = graph.get_state(config).values
    assert values["status"] == "needs-human" and values["attempt"] == 2
    assert "langgraph-conductor.coder" not in runner.roles
    assert not any(a["name"] == "20-research.md" for a in values["artifacts"])


def test_completed_call_is_reused_after_node_crash_and_connection_reopen(tmp_path, monkeypatch):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner(writes={"README.md": "implemented\n"})
    config = {"configurable": {"thread_id": "recover"}}
    original = ArtifactStore.write
    crashed = False

    def crash_after_completion(store, run_id, name, content):
        nonlocal crashed
        if name == "30-code-attempt-1.md" and not crashed:
            crashed = True
            raise RuntimeError("simulated crash after durable completion")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash_after_completion)
    with persisted(tmp_path, runner) as graph:
        with pytest.raises(RuntimeError, match="simulated crash"):
            graph.invoke(initial(workspace, spec, "recover"), config, durability="sync")
        assert graph.get_state(config).next == ("coder",)
        assert graph.get_state(config).values["attempt"] == 1
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        result = graph.get_state(config)
    assert runner.roles.count("langgraph-conductor.coder") == 1
    assert result.next == ("approval",)
    assert result.values["attempt"] == 1 and len(result.values["usage"]) == 4


@pytest.mark.parametrize("drift", [False, True])
def test_incomplete_or_drifted_call_is_not_repeated(tmp_path, drift):
    class CrashRunner(FakeRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".coder"):
                raise RuntimeError("hard crash before completion record")
            return result
    workspace, spec = make_repo(tmp_path)
    runner = CrashRunner(writes={"README.md": "partial\n"})
    config = {"configurable": {"thread_id": "unknown"}}
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError):
        graph.invoke(initial(workspace, spec, "unknown"), config, durability="sync")
    if drift:
        (workspace / "README.md").write_text("manual change\n")
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        values = graph.get_state(config).values
    assert runner.roles.count("langgraph-conductor.coder") == 1
    assert "langgraph-conductor.reviewer" not in runner.roles
    assert values["status"] == "needs-human" and values["attempt"] == 1
    assert any("outcome unknown" in error for error in values["errors"])


def test_completed_call_with_workspace_drift_cannot_be_reused(tmp_path, monkeypatch):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner()
    config = {"configurable": {"thread_id": "drift"}}
    original = ArtifactStore.write

    def crash(store, run_id, name, content):
        if name == "30-code-attempt-1.md":
            raise RuntimeError("after-completion crash")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash)
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError):
        graph.invoke(initial(workspace, spec, "drift"), config, durability="sync")
    (workspace / "README.md").write_text("external edit")
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        values = graph.get_state(config).values
    assert values["status"] == "needs-human"
    assert any("no longer matches" in error for error in values["errors"])
    assert runner.roles.count("langgraph-conductor.coder") == 1


def test_gate_timeout_is_a_decoded_failure_and_not_a_crash(tmp_path):
    workspace, spec = make_repo(tmp_path)
    state = initial(workspace, spec, "test-timeout")
    state["max_attempts"] = 1
    state["gate_timeout_seconds"] = 1
    state["test_command"] = [sys.executable, "-c", "import os,time; os.write(1,b'OUT\\xff\\n'); time.sleep(10)"]
    config = {"configurable": {"thread_id": "test-timeout"}}
    with persisted(tmp_path, FakeRunner()) as graph:
        graph.invoke(state, config, durability="sync")
        values = graph.get_state(config).values
    record = next(a for a in values["artifacts"] if a["name"].startswith("40-gate"))
    gate = json.loads(Path(record["path"]).read_text())
    assert gate["output"] == "OUT\ufffd\n" and gate["returncode"] == 124
    assert values["status"] == "needs-human"
    assert values["gate_timeout_seconds"] == 1
    assert "gate attempt 1: test command timed out" in values["errors"]


def test_legacy_interrupted_external_checkpoint_is_preserved_by_cli(tmp_path, capsys):
    state_dir = tmp_path / "legacy"
    state_dir.mkdir()
    config = {"configurable": {"thread_id": "old"}}
    with sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False) as connection:
        saver = SqliteSaver(connection)
        b = StateGraph(GraphState)
        b.add_node("context", lambda s: {"status": "running", "attempt": 0})
        b.add_node("coder", lambda s: {})
        b.add_edge(START, "context")
        b.add_edge("context", "coder")
        b.add_edge("coder", END)
        old = b.compile(checkpointer=saver, interrupt_before=["coder"])
        old.invoke({"thread_id": "old", "run_id": "old-run"}, config, durability="sync")
        checkpoint = old.get_state(config).config
    rc = main(["resume", "--state-dir", str(state_dir), "--thread-id", "old"])
    result = json.loads(capsys.readouterr().out)
    assert rc == 4 and result["next"] == ["coder"]
    assert "checkpoint preserved" in result["error"]
    with sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False) as connection:
        assert SqliteSaver(connection).get_tuple(config).config == checkpoint


def test_recovered_reviewer_mutation_still_stops_for_human(tmp_path, monkeypatch):
    class MutatingReviewer(FakeRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".reviewer"):
                (workspace / "README.md").write_text("reviewer changed code")
            return result
    workspace, spec = make_repo(tmp_path)
    runner = MutatingReviewer()
    config = {"configurable": {"thread_id": "review-recovery"}}
    original = ArtifactStore.write
    failed = False

    def crash(store, run_id, name, content):
        nonlocal failed
        if name == "50-review-attempt-1.md" and not failed:
            failed = True
            raise RuntimeError("crash before mutation check")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash)
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError):
        graph.invoke(initial(workspace, spec, "review-recovery"), config, durability="sync")
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        values = graph.get_state(config).values
    assert values["status"] == "needs-human" and values["verdict"] == "DISCUSS"
    assert runner.roles.count("langgraph-conductor.reviewer") == 1
    assert runner.roles.count("langgraph-conductor.coder") == 1
    assert any("reviewer execution mutated" in error for error in values["errors"])


@pytest.mark.parametrize("decision", ["approve", "reject"])
def test_legacy_approval_checkpoint_remains_actionable(tmp_path, capsys, decision):
    from langgraph.types import interrupt

    from agent_team_graph.graph import _change_snapshot, validate_run_input

    workspace, spec = make_repo(tmp_path)
    state_dir = tmp_path / "legacy-approval"
    state_dir.mkdir()
    state = initial(workspace, spec, "old-approval")
    state.update(validate_run_input(state, state_dir))
    digest = _change_snapshot(workspace, state["base_sha"], [], False)["change_sha256"]
    state.update(status="running", attempt=1, verdict="SHIP", gate_passed=True,
                 gated_change_sha256=digest, reviewed_change_sha256=digest)
    config = {"configurable": {"thread_id": "old-approval"}}
    with sqlite3.connect(state_dir / "runs.sqlite3", check_same_thread=False) as connection:
        b = StateGraph(GraphState)
        b.add_node("approval", lambda s: {"approval": interrupt({"kind": "ship-approval"})})
        b.add_edge(START, "approval")
        b.add_edge("approval", END)
        old = b.compile(checkpointer=SqliteSaver(connection))
        old.invoke(state, config, durability="sync")
    rc = main(["approve", "--state-dir", str(state_dir), "--thread-id", "old-approval",
               "--decision", decision, "--reviewed-digest", digest])
    view = json.loads(capsys.readouterr().out)
    assert rc == (0 if decision == "approve" else 4)
    assert view["status"] == ("approved" if decision == "approve" else "rejected")
    if decision == "approve":
        receipt = json.loads(Path(view["artifacts"][-1]["path"]).read_text())
        assert receipt["approved_change_sha256"] == digest


def _kill_checkpoint_writer(root, phase, ready):
    import signal

    class PausingRunner(FakeRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".coder") and phase == "before-completion":
                ready.set()
                signal.pause()
            return result

    if phase == "after-completion":
        original = ArtifactStore.write

        def pause_before_node_commit(store, run_id, name, content):
            if name == "30-code-attempt-1.md":
                ready.set()
                signal.pause()
            return original(store, run_id, name, content)

        ArtifactStore.write = pause_before_node_commit
    runner = PausingRunner(writes={"README.md": "from coder\n"})
    config = {"configurable": {"thread_id": "killed"}}
    with persisted(root, runner) as graph:
        graph.invoke(initial(root / "repo", root / "SPEC.md", "killed"), config,
                     durability="sync")


@pytest.mark.parametrize("phase", ["before-completion", "after-completion"])
def test_sigkill_between_external_call_and_checkpoint(tmp_path, phase):
    import multiprocessing

    make_repo(tmp_path)
    ctx = multiprocessing.get_context("spawn")
    ready = ctx.Event()
    process = ctx.Process(target=_kill_checkpoint_writer, args=(tmp_path, phase, ready))
    process.start()
    try:
        assert ready.wait(20)
        process.kill()
        process.join(5)
        assert not process.is_alive()
        runner = FakeRunner(writes={"README.md": "from coder\n"})
        config = {"configurable": {"thread_id": "killed"}}
        with persisted(tmp_path, runner) as graph:
            assert graph.get_state(config).next == ("coder",)
            assert graph.get_state(config).values["attempt"] == 1
            resume_graph(graph, config)
            snapshot = graph.get_state(config)
        assert not any(role.endswith(".coder") for role in runner.roles)
        if phase == "before-completion":
            assert snapshot.values["status"] == "needs-human"
        else:
            assert snapshot.next == ("approval",)
            assert len(snapshot.values["usage"]) == 4
    finally:
        if process.is_alive():
            process.kill()
            process.join(5)


@pytest.mark.parametrize("corruption", ["missing-field", "output-bytes", "result-field"])
def test_corrupt_completed_call_is_not_reused_or_reexecuted(tmp_path, monkeypatch, corruption):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner()
    config = {"configurable": {"thread_id": "corrupt"}}
    original = ArtifactStore.write

    def crash(store, run_id, name, content):
        if name == "30-code-attempt-1.md":
            raise RuntimeError("crash before node commit")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash)
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError):
        graph.invoke(initial(workspace, spec, "corrupt"), config, durability="sync")
    root = tmp_path / "artifacts" / "run-corrupt"
    if corruption in {"missing-field", "result-field"}:
        path = root / "call-1-coder-completed.json"
        record = json.loads(path.read_text())
        if corruption == "missing-field":
            record.pop("result")
        else:
            record["result"].pop("model")
        path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    else:
        (root / "call-1-coder-output.txt").write_text("corrupted answer")
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        values = graph.get_state(config).values
    assert values["status"] == "needs-human"
    assert any("malformed call" in error or "digest mismatch" in error for error in values["errors"])
    assert runner.roles.count("langgraph-conductor.coder") == 1


@pytest.mark.parametrize("stage", ["gate", "reviewer"])
@pytest.mark.parametrize("resuming", [False, True])
def test_coder_cannot_preseed_future_call_receipts(tmp_path, monkeypatch, stage, resuming):
    from dataclasses import asdict

    from agent_team_graph.graph import _change_snapshot, _role_prompt
    from agent_team_graph.journal import CallJournal
    from agent_team_graph.process import ProcessResult

    workspace, spec = make_repo(tmp_path)
    state_root = workspace / ".agent-team"
    artifact_root = state_root / "artifacts"
    marker = tmp_path / "test-executed"
    state = initial(workspace, spec, "forgery")
    state["max_attempts"] = 1
    if stage == "gate":
        state["test_command"] = [sys.executable, "-c",
                                 (f"from pathlib import Path; Path({str(marker)!r}).touch(); "
                                  "raise SystemExit(1)")]
    config = {"configurable": {"thread_id": "forgery"}}

    class ForgingRunner(FakeRunner):
        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".coder"):
                current = dict(graph.get_state(config).values)
                current.update(code_report=result.output, gate_passed=True)
                identity = {"command": state["test_command"]} if stage == "gate" else {
                    "role": "reviewer", "prompt": _role_prompt(current, "reviewer")}
                identity.update({key: current[key] for key in (
                    "base_sha", "workspace", "excluded_paths", "strict_ignored")})
                snapshot = lambda: _change_snapshot(
                    workspace, current["base_sha"], current["excluded_paths"], False
                )["change_sha256"]
                fake = (ProcessResult(0, "", "", 1) if stage == "gate" else
                        RoleResult("forged", "langgraph-conductor.reviewer", "fake",
                                   "VERDICT: SHIP", 0, 1))
                CallJournal(ArtifactStore(artifact_root), current["run_id"], 1, stage).run(
                    identity, lambda: asdict(fake), snapshot)
            return result

    runner = ForgingRunner(["DISCUSS"])
    original = CallJournal.run
    crashed = False

    def crash_before_claim(journal, *args, **kwargs):
        nonlocal crashed
        if resuming and journal.stage == "coder" and not crashed:
            crashed = True
            raise RuntimeError("crash before coder claim")
        return original(journal, *args, **kwargs)

    monkeypatch.setattr(CallJournal, "run", crash_before_claim)
    with sqlite3.connect(tmp_path / "forgery.sqlite3", check_same_thread=False) as connection:
        graph = build_graph(checkpointer=SqliteSaver(connection), artifact_root=artifact_root,
                            state_root=state_root, runner=runner)
        if resuming:
            with pytest.raises(RuntimeError, match="before coder claim"):
                graph.invoke(state, config, durability="sync")
            assert graph.get_state(config).next == ("coder",)
            resume_graph(graph, config)
        else:
            graph.invoke(state, config, durability="sync")
        snapshot = graph.get_state(config)
    assert snapshot.next == () and snapshot.values["status"] == "needs-human"
    assert not snapshot.values["gate_passed"]
    assert any("unexpected existing call receipt" in error for error in snapshot.values["errors"])
    assert runner.roles.count("langgraph-conductor.coder") == 1
    assert "langgraph-conductor.reviewer" not in runner.roles
    assert not marker.exists()


def test_receipt_identity_mismatch_is_a_recovery_error(tmp_path):
    from agent_team_graph.journal import CallJournal, RecoveryError

    journal = CallJournal(ArtifactStore(tmp_path), "run", 1, "coder")
    calls = []

    def invoke():
        calls.append("executed")
        return {"output": "answer", "stderr": ""}

    journal.run({"command": "/original/model"}, invoke, lambda: "digest")
    with pytest.raises(RecoveryError, match="receipt identity mismatch") as caught:
        journal.run({"command": "/different/model"}, invoke, lambda: "digest", allow_replay=True)
    assert "PATH" in str(caught.value) and "/different/model" in str(caught.value)
    with pytest.raises(RecoveryError, match="unexpected existing call receipt"):
        journal.run({"command": "/original/model"}, invoke, lambda: "digest")
    assert calls == ["executed"]


def test_reviewer_failure_replaces_stale_feedback_for_next_coder(tmp_path):
    from dataclasses import replace

    class Runner(FakeRunner):
        def __init__(self):
            super().__init__(["NEEDS-FIX", "SHIP"])
            self.coder_prompts = []

        def run(self, role, prompt, workspace):
            result = super().run(role, prompt, workspace)
            if role.endswith(".coder"):
                self.coder_prompts.append(prompt)
            if role.endswith(".reviewer") and self.roles.count(role) == 2:
                return replace(result, returncode=124, timed_out=True,
                               output="UNTRUSTED FAILED REVIEW", stderr="PRIVATE DIAGNOSTIC")
            return result

    workspace, spec = make_repo(tmp_path)
    state = initial(workspace, spec, "review-feedback")
    state.update(max_attempts=3, review="")
    runner = Runner()
    config = {"configurable": {"thread_id": "review-feedback"}}
    with persisted(tmp_path, runner) as graph:
        graph.invoke(state, config, durability="sync")
        assert graph.get_state(config).next == ("approval",)
    assert "Previous review:\n(none)" in runner.coder_prompts[0]
    assert "VERDICT: NEEDS-FIX" in runner.coder_prompts[1]
    final = runner.coder_prompts[2]
    assert "previous reviewer attempt 2 failed with exit code 124 (timeout)" in final
    assert "Preserve changes that passed the gate" in final
    assert all(text not in final for text in (
        "VERDICT: NEEDS-FIX", "UNTRUSTED FAILED REVIEW", "PRIVATE DIAGNOSTIC"))


@pytest.mark.parametrize("phase", ["preflight", "before-claim", "after-claim"])
def test_registry_failure_during_run_is_checkpointed_for_human_recovery(tmp_path, phase):
    from agent_team_graph.registry import RegistryError, RoleRunner

    class Runner(RoleRunner):
        def preflight(self, workspace):
            if phase == "preflight":
                raise RegistryError("model executable disappeared")

        def resolve_adapter(self, role, workspace):
            if role.endswith(".coder") and phase == "before-claim":
                raise RegistryError("model executable disappeared")
            return "fake", {"args": []}, "fake-model"

        def run(self, role, prompt, workspace):
            if role.endswith(".coder"):
                raise RegistryError("model executable disappeared")
            return RoleResult("fake", role, "fake", "answer", 0, 1)

    workspace, spec = make_repo(tmp_path)
    config = {"configurable": {"thread_id": "registry-failure"}}
    with persisted(tmp_path, Runner()) as graph:
        graph.invoke(initial(workspace, spec, "registry-failure"), config, durability="sync")
        snapshot = graph.get_state(config)
    assert snapshot.next == () and snapshot.values["status"] == "needs-human"
    assert snapshot.values["attempt"] == (0 if phase == "preflight" else 1)
    assert snapshot.values["halted"]
    assert any("model executable disappeared" in error
               for error in snapshot.values["errors"])
    assert len(snapshot.values["usage"]) == (0 if phase == "preflight" else 2)


@pytest.mark.parametrize("signum", [2, 15])
def test_cancellation_during_context_does_not_claim_first_role(tmp_path, monkeypatch, signum):
    from agent_team_graph import graph as module
    from agent_team_graph.process import Cancellation

    workspace, spec = make_repo(tmp_path)
    cancellation = Cancellation()
    original = module.validate_run_input

    def cancel_during_context(*args):
        result = original(*args)
        cancellation.signal = signum
        return result

    monkeypatch.setattr(module, "validate_run_input", cancel_during_context)
    runner = FakeRunner()
    config = {"configurable": {"thread_id": "cancel-context"}}
    artifacts = tmp_path / "artifacts"
    with sqlite3.connect(":memory:", check_same_thread=False) as connection:
        graph = build_graph(checkpointer=SqliteSaver(connection), artifact_root=artifacts,
                            cancellation=cancellation, runner=runner)
        graph.invoke(initial(workspace, spec, "cancel-context"), config, durability="sync")
        snapshot = graph.get_state(config)
    assert snapshot.next == () and snapshot.values["status"] == "needs-human"
    assert snapshot.values["attempt"] == 0 and snapshot.values["cancelled_signal"] == signum
    assert snapshot.values["usage"] == [] and runner.roles == []
    assert list(artifacts.rglob("call-*")) == []


@pytest.mark.parametrize("strict", [False, True])
def test_gate_recovery_preserves_original_ignored_observation(tmp_path, monkeypatch, strict):
    from agent_team_graph import graph as module

    workspace, spec = make_repo(tmp_path)
    (workspace / ".gitignore").write_text("cache/\n")
    subprocess.run(["git", "-C", workspace, "add", ".gitignore"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "ignore cache"], check=True)
    runner = FakeRunner(writes={"README.md": "implemented", "cache/before.pyc": "old cache"})
    state = initial(workspace, spec, "gate-cache")
    state.update(strict_ignored=strict, allowed_paths=["README.md", "cache"])
    config = {"configurable": {"thread_id": "gate-cache"}}
    original_write = ArtifactStore.write_json
    original_run = module.run_process
    calls = []
    crashed = False

    def count_test(*args, **kwargs):
        calls.append("test")
        return original_run(*args, **kwargs)

    def crash_after_gate(store, run_id, name, content):
        nonlocal crashed
        artifact = original_write(store, run_id, name, content)
        if name == "40-gate-attempt-1.json" and not crashed:
            crashed = True
            raise RuntimeError("crash after gate artifact before checkpoint")
        return artifact

    monkeypatch.setattr(module, "run_process", count_test)
    monkeypatch.setattr(ArtifactStore, "write_json", crash_after_gate)
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError, match="after gate artifact"):
        graph.invoke(state, config, durability="sync")
    path = tmp_path / "artifacts/run-gate-cache/40-gate-attempt-1.json"
    before = path.read_bytes()
    assert json.loads(before)["ignored_paths"] == ["cache/before.pyc"]
    (workspace / "cache/before.pyc").unlink()
    (workspace / "cache/after.pyc").write_text("new cache")
    with persisted(tmp_path, runner) as graph:
        assert graph.get_state(config).next == ("gate",)
        resume_graph(graph, config)
        snapshot = graph.get_state(config)
    assert calls == ["test"] and path.read_bytes() == before
    if strict:
        assert snapshot.values["status"] == "needs-human" and snapshot.next == ()
        assert any("no longer matches" in error for error in snapshot.values["errors"])
    else:
        assert snapshot.next == ("approval",) and snapshot.values["gate_passed"]


def test_failed_call_snapshot_is_not_reported_as_workspace_drift(tmp_path):
    from agent_team_graph.journal import CallJournal, RecoveryError

    journal = CallJournal(ArtifactStore(tmp_path), "run", 1, "gate")

    def failed_snapshot():
        raise OSError("snapshot unavailable")

    journal.run({"command": ["true"]}, lambda: {"stdout": "", "stderr": ""}, failed_snapshot)
    with pytest.raises(RecoveryError, match="snapshot could not be attested.*snapshot unavailable"):
        journal.run({"command": ["true"]}, lambda: pytest.fail("must not invoke"),
                    lambda: pytest.fail("must not relabel missing snapshot as drift"), allow_replay=True)


@pytest.mark.parametrize("phase", ["started", "completed"])
def test_unavailable_replay_adapter_explains_terminal_recovery(tmp_path, monkeypatch, phase):
    from agent_team_graph.registry import RegistryError, RoleRunner

    class Runner(RoleRunner):
        missing = False

        def preflight(self, workspace):
            pass

        def resolve_adapter(self, role, workspace):
            if self.missing:
                raise RegistryError("executable not found")
            return "fake", {"args": []}, "fake-model"

        def run(self, role, prompt, workspace):
            return RoleResult("fake", role, "fake", "answer", 0, 1)

    workspace, spec = make_repo(tmp_path)
    runner = Runner()
    original = ArtifactStore.write

    def crash(store, run_id, name, content):
        target = ("call-1-coder-completed.json" if phase == "started"
                  else "30-code-attempt-1.md")
        if name == target:
            raise RuntimeError("crash after call receipt")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash)
    config = {"configurable": {"thread_id": "missing-adapter"}}
    with persisted(tmp_path, runner) as graph, pytest.raises(RuntimeError, match="after call receipt"):
        graph.invoke(initial(workspace, spec, "missing-adapter"), config, durability="sync")
    receipt_dir = tmp_path / "artifacts/run-missing-adapter"
    assert (receipt_dir / "call-1-coder-started.json").is_file()
    assert (receipt_dir / "call-1-coder-completed.json").is_file() == (phase == "completed")
    runner.missing = True
    with persisted(tmp_path, runner) as graph:
        resume_graph(graph, config)
        snapshot = graph.get_state(config)
    assert snapshot.next == () and snapshot.values["status"] == "needs-human"
    error = "\n".join(snapshot.values["errors"])
    assert "RecoveryError" in error and "registry/PATH" in error and "start a new run" in error
    assert f"call-1-coder records under {receipt_dir}" in error
    assert "call-1-coder-completed.json" not in error


def test_programming_type_error_is_not_misclassified_as_a_receipt_failure(tmp_path):
    class Runner(FakeRunner):
        def run(self, role, prompt, workspace):
            if role.endswith(".coder"):
                raise TypeError("programming error in runner")
            return super().run(role, prompt, workspace)

    workspace, spec = make_repo(tmp_path)
    config = {"configurable": {"thread_id": "type-error"}}
    with persisted(tmp_path, Runner()) as graph:
        with pytest.raises(TypeError, match="programming error in runner"):
            graph.invoke(initial(workspace, spec, "type-error"), config, durability="sync")
        assert graph.get_state(config).next == ("coder",)


def test_context_artifact_keeps_its_0_1_5_shape_for_crash_replay(tmp_path, monkeypatch):
    """00-context.json is immutable: a 0.1.5 run that wrote it and crashed resumes here."""
    workspace, spec = make_repo(tmp_path)
    config = {"configurable": {"thread_id": "ctx"}}
    original = ArtifactStore.write_json

    def crash_after_context(store, run_id, name, value):
        record = original(store, run_id, name, value)
        if name == "00-context.json":
            raise RuntimeError("simulated crash after the context write")
        return record

    monkeypatch.setattr(ArtifactStore, "write_json", crash_after_context)
    state = initial(workspace, spec, "ctx") | {"role_timeout_seconds": 7}
    with (persisted(tmp_path, FakeRunner()) as graph,
          pytest.raises(RuntimeError, match="simulated crash")):
        graph.invoke(state, config, durability="sync")
    monkeypatch.setattr(ArtifactStore, "write_json", original)
    written = next(tmp_path.rglob("00-context.json"))
    before = written.read_bytes()
    # The exact 0.1.5 key set; run policy lives in the checkpoint, not here.
    assert sorted(json.loads(before)) == sorted([
        "workspace", "repo_root", "spec_path", "base_sha", "spec_sha256", "allowed_paths",
        "operator_excluded_paths", "excluded_paths", "strict_ignored"])
    with persisted(tmp_path, FakeRunner()) as graph:
        resume_graph(graph, config)
        values = graph.get_state(config).values
    assert graph.get_state(config).next == ("approval",) and written.read_bytes() == before
    assert values["role_timeout_seconds"] == 7 and values["gate_timeout_seconds"] == 900


def test_resumed_run_keeps_its_timeouts_after_reopen(tmp_path, monkeypatch):
    from agent_team_graph import graph as module
    from agent_team_graph.registry import RoleRunner

    workspace, spec = make_repo(tmp_path)
    fake = FakeRunner(writes={"README.md": "implemented\n"})
    seen = []

    def run(self, role, prompt, workspace, **kw):
        seen.append((role.rsplit(".", 1)[1], kw.get("timeout")))
        return fake.run(role, prompt, workspace)

    real_process = module.run_process

    def run_process(command, **kw):
        seen.append(("gate", kw["timeout"]))
        return real_process(command, **kw)

    monkeypatch.setattr(RoleRunner, "preflight", lambda self, workspace: None)
    monkeypatch.setattr(RoleRunner, "resolve_adapter",
                        lambda self, role, workspace: ("fake", {"args": []}, "fake-model"))
    monkeypatch.setattr(RoleRunner, "run", run)
    monkeypatch.setattr(module, "run_process", run_process)
    original = ArtifactStore.write
    crashed = False

    def crash_after_coder(store, run_id, name, content):
        nonlocal crashed
        if name == "30-code-attempt-1.md" and not crashed:
            crashed = True
            raise RuntimeError("simulated crash after durable completion")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash_after_coder)
    config = {"configurable": {"thread_id": "keep"}}
    state = initial(workspace, spec, "keep") | {"role_timeout_seconds": 7,
                                                "gate_timeout_seconds": 11}
    with (persisted(tmp_path, RoleRunner()) as graph,
          pytest.raises(RuntimeError, match="simulated crash")):
        graph.invoke(state, config, durability="sync")
    assert seen == [("planner", 7), ("researcher", 7), ("coder", 7)]
    with persisted(tmp_path, RoleRunner()) as graph:
        resume_graph(graph, config)
        assert graph.get_state(config).next == ("approval",)
    assert seen[3:] == [("gate", 11), ("reviewer", 7)]
