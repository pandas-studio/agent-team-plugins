"""The scope gate is a safety boundary — exercise the paths that can leak."""

from __future__ import annotations

import json
import sqlite3
import subprocess
from pathlib import Path

from helpers import FakeRunner, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph import graph as graph_module
from agent_team_graph.graph import _changed_paths, _file_digest, _ignored_paths, build_graph


def _graph(tmp_path: Path, runner: FakeRunner):
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    return build_graph(
        checkpointer=SqliteSaver(connection),
        artifact_root=tmp_path / "artifacts",
        runner=runner,
    )


def _run(tmp_path: Path, runner: FakeRunner, state: dict, thread: str):
    graph = _graph(tmp_path, runner)
    config = {"configurable": {"thread_id": thread}}
    graph.invoke(state, config=config)
    return graph.get_state(config)


def _gate_record(snapshot) -> dict:
    artifact = next(a for a in snapshot.values["artifacts"] if "40-gate" in a["name"])
    return json.loads(Path(artifact["path"]).read_text(encoding="utf-8"))


def test_paths_share_one_base_when_workspace_is_a_subdirectory(tmp_path: Path):
    """`diff` is root-relative; `ls-files --others` is cwd-relative and cwd-scoped.

    Running both from the repository root is what keeps them comparable — and
    what stops a file created outside the workspace subtree from being invisible.
    """
    workspace, _ = make_repo(tmp_path)
    sub = workspace / "sub"
    sub.mkdir()
    (sub / "a.txt").write_text("a\n", encoding="utf-8")
    subprocess.run(["git", "-C", workspace, "add", "-A"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "sub"], check=True)
    base = subprocess.run(
        ["git", "-C", workspace, "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    (sub / "a.txt").write_text("changed\n", encoding="utf-8")
    (workspace / "elsewhere.txt").write_text("new\n", encoding="utf-8")

    tracked, untracked = _changed_paths(workspace, base, [])
    assert tracked == ["sub/a.txt"]
    # An `ls-files --others` run from `sub/` would miss this entirely.
    assert untracked == ["elsewhere.txt"]


def test_subdirectory_workspace_still_resolves_repo_root(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    sub = workspace / "sub"
    sub.mkdir()
    state = initial(workspace, spec, "subdir")
    state["workspace"] = str(sub)
    snapshot = _run(tmp_path, FakeRunner(), state, "subdir")
    assert snapshot.values["repo_root"] == str(workspace.resolve())
    assert snapshot.values["gate_passed"] is True


def test_out_of_scope_write_fails_the_gate_and_blocks_ship(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner(writes={"secrets.txt": "leaked\n"})
    snapshot = _run(tmp_path, runner, initial(workspace, spec, "scope"), "scope")

    assert snapshot.values["gate_passed"] is False
    # SHIP is downgraded because the gate failed, so the run stops for a human.
    assert snapshot.values["verdict"] == "NEEDS-FIX"
    assert snapshot.values["status"] == "needs-human"
    assert _gate_record(snapshot)["outside_scope"] == ["secrets.txt"]


def test_failing_test_command_downgrades_ship_to_needs_fix(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    state = initial(workspace, spec, "gate")
    state["test_command"] = ["git", "rev-parse", "--verify", "refs/heads/does-not-exist"]
    snapshot = _run(tmp_path, FakeRunner(), state, "gate")

    assert snapshot.values["gate_passed"] is False
    assert snapshot.values["verdict"] == "NEEDS-FIX"
    assert snapshot.values["status"] == "needs-human"


def test_gitignored_writes_are_reported_and_enforced_only_under_strict(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    (workspace / ".gitignore").write_text("build/\n", encoding="utf-8")
    subprocess.run(["git", "-C", workspace, "add", ".gitignore"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "ignore"], check=True)

    runner = FakeRunner(writes={"build/out.bin": "artifact\n"})
    lenient = _run(tmp_path, runner, initial(workspace, spec, "lenient"), "lenient")
    record = _gate_record(lenient)
    # Visible to the operator even though it does not fail the gate.
    assert record["ignored_paths"] == ["build/out.bin"]
    assert record["outside_scope"] == []
    assert lenient.values["gate_passed"] is True

    assert _ignored_paths(workspace, []) == ["build/out.bin"]
    assert _ignored_paths(workspace, ["build"]) == []

    strict = initial(workspace, spec, "strict")
    strict["strict_ignored"] = True
    snapshot = _run(tmp_path, FakeRunner(), strict, "strict")
    assert snapshot.values["gate_passed"] is False
    assert _gate_record(snapshot)["outside_scope"] == ["build/out.bin"]


def test_runtime_state_inside_the_repo_never_counts_against_the_gate(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    state_dir = workspace / ".agent-team"
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    graph = build_graph(
        checkpointer=SqliteSaver(connection),
        artifact_root=state_dir / "artifacts",
        runner=FakeRunner(),
        state_root=state_dir,
    )
    config = {"configurable": {"thread_id": "excluded"}}
    graph.invoke(initial(workspace, spec, "excluded"), config=config)
    snapshot = graph.get_state(config)
    assert snapshot.values["excluded_paths"] == [".agent-team"]
    assert snapshot.values["gate_passed"] is True


def test_receipt_covers_untracked_files(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner(writes={"README.md": "changed\n", "NEW.md": "brand new\n"})
    graph = _graph(tmp_path, runner)
    state = initial(workspace, spec, "receipt")
    state["allowed_paths"] = ["README.md", "NEW.md"]
    config = {"configurable": {"thread_id": "receipt"}}
    graph.invoke(state, config=config)
    graph.invoke(Command(resume="approve"), config=config)

    values = graph.get_state(config).values
    receipt = json.loads(Path(values["artifacts"][-1]["path"]).read_text(encoding="utf-8"))
    # `git diff` cannot see NEW.md, so a diff-only digest would silently omit it.
    assert "NEW.md" in receipt["new_files"]
    assert receipt["change_sha256"] != receipt["tracked_diff_sha256"]
    assert receipt["change_sha256"] == receipt["reviewed_change_sha256"]
    assert receipt["head_sha_attested"] is False
    assert "HEAD SHA is informational and excluded" in receipt["covers"]


def test_change_after_approval_interrupt_blocks_receipt(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner(writes={"README.md": "reviewed\n"}))
    state = initial(workspace, spec, "approval-drift")
    state["allowed_paths"] = ["README.md", "NEW.md"]
    config = {"configurable": {"thread_id": "approval-drift"}}
    graph.invoke(state, config=config)
    reviewed = graph.get_state(config).values["reviewed_change_sha256"]

    (workspace / "NEW.md").write_text("not reviewed\n", encoding="utf-8")
    graph.invoke(Command(resume="approve"), config=config)

    values = graph.get_state(config).values
    assert values["status"] == "needs-human"
    assert Path(values["artifacts"][-1]["path"]).name == "91-approval-change-drift.json"
    assert not any(item["name"] == "90-approval-receipt.json" for item in values["artifacts"])
    drift = json.loads(Path(values["artifacts"][-1]["path"]).read_text(encoding="utf-8"))
    assert drift["reviewed_change_sha256"] == reviewed
    assert drift["current_change_sha256"] != reviewed


def test_change_before_review_skips_review_of_untested_content(tmp_path: Path, monkeypatch):
    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner()
    real_snapshot = graph_module._change_snapshot
    calls = 0

    def mutate_before_second_snapshot(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 2:
            (workspace / "README.md").write_text("changed before review\n", encoding="utf-8")
        return real_snapshot(*args, **kwargs)

    monkeypatch.setattr(graph_module, "_change_snapshot", mutate_before_second_snapshot)
    state = initial(workspace, spec, "pre-review-drift")
    state["max_attempts"] = 1
    snapshot = _run(tmp_path, runner, state, "pre-review-drift")

    assert not any(role.endswith(".reviewer") for role in runner.roles)
    assert snapshot.values["verdict"] == "NEEDS-FIX"
    assert snapshot.values["reviewed_change_sha256"] is None
    assert any(
        item["name"] == "55-pre-review-drift-attempt-1.json"
        for item in snapshot.values["artifacts"]
    )


def test_reviewer_mutation_is_reported_as_reviewer_side_effect(tmp_path: Path):
    class MutatingReviewer(FakeRunner):
        def run(self, role: str, prompt: str, workspace: Path):
            result = super().run(role, prompt, workspace)
            if role.endswith(".reviewer"):
                (workspace / "README.md").write_text("changed during review\n", encoding="utf-8")
            return result

    workspace, spec = make_repo(tmp_path)
    state = initial(workspace, spec, "reviewer-mutation")
    state["max_attempts"] = 1
    snapshot = _run(tmp_path, MutatingReviewer(), state, "reviewer-mutation")

    assert snapshot.values["gate_passed"] is False
    assert snapshot.values["verdict"] == "DISCUSS"
    assert snapshot.values["reviewed_change_sha256"] is None
    assert snapshot.values["status"] == "needs-human"
    assert any(
        item["name"] == "56-reviewer-mutation-attempt-1.json"
        for item in snapshot.values["artifacts"]
    )
    assert any("reviewer execution mutated" in error for error in snapshot.values["errors"])


def test_snapshot_race_is_a_recorded_gate_failure(tmp_path: Path, monkeypatch):
    workspace, spec = make_repo(tmp_path)
    real_digest = graph_module._file_digest
    failed = False

    def disappear_once(repo_root: Path, relative: str):
        nonlocal failed
        if relative == "NEW.md" and not failed:
            failed = True
            raise FileNotFoundError("simulated list/lstat race")
        return real_digest(repo_root, relative)

    monkeypatch.setattr(graph_module, "_file_digest", disappear_once)
    state = initial(workspace, spec, "snapshot-race")
    state["allowed_paths"] = ["README.md", "NEW.md"]
    state["max_attempts"] = 1
    snapshot = _run(
        tmp_path,
        FakeRunner(writes={"NEW.md": "new\n"}),
        state,
        "snapshot-race",
    )

    record = _gate_record(snapshot)
    assert record["passed"] is False
    assert "FileNotFoundError" in record["snapshot_error"]
    assert snapshot.values["gated_change_sha256"] is None
    assert snapshot.values["status"] == "needs-human"


def test_publish_snapshot_race_blocks_receipt(tmp_path: Path, monkeypatch):
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner(writes={"NEW.md": "new\n"}))
    state = initial(workspace, spec, "publish-race")
    state["allowed_paths"] = ["README.md", "NEW.md"]
    config = {"configurable": {"thread_id": "publish-race"}}
    graph.invoke(state, config=config)

    real_digest = graph_module._file_digest

    def fail_new_file(repo_root: Path, relative: str):
        if relative == "NEW.md":
            raise FileNotFoundError("simulated approval snapshot race")
        return real_digest(repo_root, relative)

    monkeypatch.setattr(graph_module, "_file_digest", fail_new_file)
    graph.invoke(Command(resume="approve"), config=config)

    values = graph.get_state(config).values
    assert values["status"] == "needs-human"
    assert Path(values["artifacts"][-1]["path"]).name == "91-approval-snapshot-error.json"
    assert not any(item["name"] == "90-approval-receipt.json" for item in values["artifacts"])


def test_head_sha_is_informational_when_reviewed_content_is_committed(tmp_path: Path):
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner(writes={"README.md": "reviewed\n"}))
    config = {"configurable": {"thread_id": "head-info"}}
    graph.invoke(initial(workspace, spec, "head-info"), config=config)
    reviewed = graph.get_state(config).values["reviewed_change_sha256"]

    subprocess.run(["git", "-C", workspace, "add", "README.md"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "reviewed change"], check=True)
    graph.invoke(Command(resume="approve"), config=config)

    values = graph.get_state(config).values
    receipt = json.loads(Path(values["artifacts"][-1]["path"]).read_text(encoding="utf-8"))
    assert values["status"] == "approved"
    assert receipt["change_sha256"] == reviewed
    assert receipt["head_sha_attested"] is False


def test_untracked_symlink_digest_does_not_follow_external_target(tmp_path: Path):
    workspace, _ = make_repo(tmp_path)
    outside = tmp_path / "outside-secret.txt"
    outside.write_text("first secret\n", encoding="utf-8")
    (workspace / "link.txt").symlink_to(outside)
    first = _file_digest(workspace, "link.txt")

    outside.write_text("different secret\n", encoding="utf-8")
    assert _file_digest(workspace, "link.txt") == first
