"""Filesystem attestation (#26): the digest no longer depends on what `.git` says.

Each "detected" case pairs the fail-closed snapshot with a negative control: the
git listing the pre-0.1.7 digest was built from, showing it missed the change.
"""

from __future__ import annotations

import json
import os
import shlex
import sqlite3
import subprocess
from pathlib import Path

import pytest
from helpers import FakeRunner, baseline_for, initial, make_repo
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command

from agent_team_graph.graph import (
    PRE_ATTESTATION,
    _change_snapshot,
    _changed_paths,
    _review_commands,
    build_graph,
    resume_graph,
)
from agent_team_graph.state import GraphState


def _git(workspace: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(workspace), *args], capture_output=True,
                          text=True, check=True).stdout.strip()


def _commit_all(workspace: Path, message: str) -> str:
    _git(workspace, "add", "-A")
    _git(workspace, "commit", "-qm", message)
    return _git(workspace, "rev-parse", "HEAD")


def _head(workspace: Path) -> str:
    return _git(workspace, "rev-parse", "HEAD")


def _snapshot(workspace: Path, base: str, baseline, strict: bool = False) -> dict:
    return _change_snapshot(workspace, base, [], strict, baseline)


def _refused(workspace: Path, base: str, baseline, strict: bool = False) -> str:
    with pytest.raises(ValueError) as caught:
        _snapshot(workspace, base, baseline, strict)
    return str(caught.value)


@pytest.fixture(autouse=True)
def _isolated_global_git(tmp_path, monkeypatch):
    """Give every test its own global git config and ignore file."""
    global_ignore = tmp_path / "global-ignore"
    global_ignore.write_text("", encoding="utf-8")
    config = tmp_path / "global-gitconfig"
    config.write_text(f"[core]\n\texcludesFile = {global_ignore}\n", encoding="utf-8")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    return global_ignore


# --- hiding through .git that is now detected -------------------------------


def test_new_file_hidden_by_info_exclude_fails_closed(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    (workspace / "NEW.md").write_text("smuggled\n", encoding="utf-8")
    with (workspace / ".git/info/exclude").open("a", encoding="utf-8") as rules:
        rules.write("NEW.md\n")
    assert _changed_paths(workspace, base, []) == ([], [])  # the old view: nothing
    message = _refused(workspace, base, baseline)
    assert message == ("git and the filesystem disagree on changed paths: "
                       "filesystem-only ['NEW.md'], git-only []")


def test_index_removal_of_an_unchanged_file_fails_closed(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    _git(workspace, "rm", "-q", "--cached", "README.md")
    assert _refused(workspace, base, baseline) == (
        "git and the filesystem disagree on changed paths: "
        "filesystem-only [], git-only ['README.md']"
    )


def test_mode_change_hidden_by_core_filemode_fails_closed(tmp_path):
    workspace, _ = make_repo(tmp_path)
    (workspace / "run.sh").write_text("#!/bin/sh\n", encoding="utf-8")
    base = _commit_all(workspace, "script")
    baseline = baseline_for(workspace, base)
    _git(workspace, "config", "core.fileMode", "false")
    (workspace / "run.sh").chmod(0o755)
    assert _changed_paths(workspace, base, []) == ([], [])
    assert _refused(workspace, base, baseline) == (
        "git and the filesystem disagree on changed paths: filesystem-only ['run.sh'], "
        "git-only []; likely mode-only change (core.fileMode=false?)"
    )


def _repo_with_submodule(tmp_path: Path) -> tuple[Path, Path, str]:
    source = tmp_path / "subsource"
    source.mkdir()
    _git(source, "init", "-q")
    _git(source, "config", "user.email", "t@example.com")
    _git(source, "config", "user.name", "T")
    (source / "s.txt").write_text("one\n", encoding="utf-8")
    _commit_all(source, "s")
    workspace, spec = make_repo(tmp_path)
    _git(workspace, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
         str(source), "sub")
    return workspace, spec, _commit_all(workspace, "submodule")


def test_submodule_moved_to_another_commit_fails_closed(tmp_path):
    workspace, _, base = _repo_with_submodule(tmp_path)
    baseline = baseline_for(workspace, base)
    assert baseline.document["gitlinks"] == ["sub"]
    assert baseline.document["boundaries"] == ["sub"]
    (workspace / "sub/s.txt").write_text("two\n", encoding="utf-8")
    _git(workspace / "sub", "-c", "user.email=t@example.com", "-c", "user.name=T",
         "commit", "-qam", "moved")
    assert _refused(workspace, base, baseline) == (
        "1 change(s) inside a non-attested repository boundary (first: 'sub'); "
        "submodule and nested-repository content cannot be attested"
    )


def test_gitlink_removed_from_the_index_fails_closed(tmp_path):
    workspace, _, base = _repo_with_submodule(tmp_path)
    baseline = baseline_for(workspace, base)
    _git(workspace, "rm", "-q", "--cached", "sub")
    assert "inside a non-attested repository boundary (first: 'sub')" in _refused(
        workspace, base, baseline)


def test_new_nested_repository_fails_closed(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    (workspace / "vendor").mkdir()
    _git(workspace / "vendor", "init", "-q")
    (workspace / "vendor/lib.py").write_text("x = 1\n", encoding="utf-8")
    assert _refused(workspace, base, baseline) == (
        "nested repository boundaries changed during the run (new: ['vendor'], gone: []); "
        "their content cannot be attested"
    )


# --- hiding through .git that is now simply attested ------------------------


def test_repo_local_excludes_set_mid_run_cannot_hide_a_new_file(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    hide = tmp_path / "hide"
    hide.write_text("NEW.md\n", encoding="utf-8")
    _git(workspace, "config", "core.excludesFile", str(hide))
    (workspace / "NEW.md").write_text("visible\n", encoding="utf-8")
    snapshot = _snapshot(workspace, base, baseline)
    assert snapshot["changed_paths"] == ["NEW.md"]
    assert snapshot["changes"]["NEW.md"]["mode"] == "100644"


def test_index_removal_of_an_edited_file_attests_the_edit(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    _git(workspace, "rm", "-q", "--cached", "README.md")
    (workspace / "README.md").write_text("edited\n", encoding="utf-8")
    snapshot = _snapshot(workspace, base, baseline)
    assert snapshot["changed_paths"] == ["README.md"]
    assert snapshot["changes"]["README.md"] != baseline.document["files"]["README.md"]


def test_global_ignore_edited_mid_run_hides_nothing(tmp_path, _isolated_global_git):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    (workspace / "NEW.md").write_text("new\n", encoding="utf-8")
    _isolated_global_git.write_text("NEW.md\n", encoding="utf-8")
    assert _snapshot(workspace, base, baseline)["changed_paths"] == ["NEW.md"]
    state = {"repo_root": str(workspace), "base_sha": base, "excluded_paths": [],
             "attestation_ignore_rules": str(baseline.ignore_rules)}
    _, listing = _review_commands(state)
    shown = subprocess.run(shlex.split(listing), capture_output=True, text=True, check=True)
    assert shown.stdout.split() == ["NEW.md"]


# --- content attestation ----------------------------------------------------


def test_deletion_mode_flip_and_symlink_swap_are_attested(tmp_path):
    workspace, _ = make_repo(tmp_path)
    (workspace / "a.txt").write_text("a\n", encoding="utf-8")
    (workspace / "b.txt").write_text("b\n", encoding="utf-8")
    os.symlink("a.txt", workspace / "link")
    base = _commit_all(workspace, "files")
    baseline = baseline_for(workspace, base)
    assert _snapshot(workspace, base, baseline)["changes"] == {}

    (workspace / "README.md").unlink()
    assert _snapshot(workspace, base, baseline)["changes"] == {"README.md": None}

    (workspace / "a.txt").chmod(0o755)
    modes = _snapshot(workspace, base, baseline)["changes"]
    assert modes["a.txt"]["mode"] == "100755"
    assert modes["a.txt"]["sha256"] == baseline.document["files"]["a.txt"]["sha256"]

    before = _snapshot(workspace, base, baseline)["change_sha256"]
    (workspace / "link").unlink()
    os.symlink("b.txt", workspace / "link")
    swapped = _snapshot(workspace, base, baseline)
    assert swapped["changes"]["link"]["mode"] == "120000"
    assert swapped["change_sha256"] != before


def test_tracked_file_hidden_by_a_later_gitignore_is_still_attested(tmp_path):
    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    (workspace / ".gitignore").write_text("README.md\n", encoding="utf-8")
    (workspace / "README.md").write_text("edited while ignored\n", encoding="utf-8")
    assert _snapshot(workspace, base, baseline)["changed_paths"] == [".gitignore", "README.md"]


def test_ignored_output_is_reported_unless_strict(tmp_path):
    workspace, _ = make_repo(tmp_path)
    (workspace / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
    base = _commit_all(workspace, "ignore")
    loose, strict = baseline_for(workspace, base), baseline_for(workspace, base, strict_ignored=True)
    (workspace / "__pycache__").mkdir()
    (workspace / "__pycache__/m.pyc").write_bytes(b"\x00")
    relaxed = _snapshot(workspace, base, loose)
    assert (relaxed["changes"], relaxed["ignored_paths"]) == ({}, ["__pycache__/m.pyc"])
    enforced = _snapshot(workspace, base, strict, strict=True)
    assert list(enforced["changes"]) == ["__pycache__/m.pyc"]


# --- the run baseline -------------------------------------------------------


def _graph(tmp_path: Path, runner: FakeRunner, connection=None):
    connection = connection or sqlite3.connect(":memory:", check_same_thread=False)
    return build_graph(checkpointer=SqliteSaver(connection),
                       artifact_root=tmp_path / "artifacts", runner=runner)


def test_uninitialized_submodule_run_reaches_a_receipt(tmp_path):
    workspace, spec, _ = _repo_with_submodule(tmp_path)
    _git(workspace, "submodule", "deinit", "-q", "-f", "sub")
    graph = _graph(tmp_path, FakeRunner(writes={"README.md": "reviewed\n"}))
    config = {"configurable": {"thread_id": "uninit"}}
    graph.invoke(initial(workspace, spec, "uninit"), config=config)
    graph.invoke(Command(resume="approve"), config=config)
    values = graph.get_state(config).values
    assert values["status"] == "approved", values["errors"]
    receipt = json.loads(Path(values["artifacts"][-1]["path"]).read_text(encoding="utf-8"))
    assert receipt["submodule_paths_not_attested"] == ["sub"]
    assert list(receipt["changes"]) == ["README.md"]


def test_tampered_base_manifest_blocks_the_receipt(tmp_path):
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner(writes={"README.md": "reviewed\n"}))
    config = {"configurable": {"thread_id": "tamper"}}
    graph.invoke(initial(workspace, spec, "tamper"), config=config)
    manifest = tmp_path / "artifacts/run-tamper/02-base-manifest.json"
    manifest.chmod(0o644)
    original = manifest.read_bytes()
    manifest.write_bytes(original + b" ")
    graph.invoke(Command(resume="approve"), config=config)
    values = graph.get_state(config).values
    assert values["status"] == "needs-human"
    assert values["errors"][-1] == (
        "approval blocked: cannot attest current change set: ValueError: "
        "base manifest does not match the digest recorded at run start"
    )


@pytest.mark.parametrize("same", [True, False])
def test_context_reentry_must_reproduce_the_baseline(tmp_path, same):
    """A crash before the context checkpoint re-runs it; the baseline is written once."""
    workspace, spec = make_repo(tmp_path)
    graph = _graph(tmp_path, FakeRunner())
    first = {"configurable": {"thread_id": "first"}}
    graph.invoke(initial(workspace, spec, "first"), config=first)
    rules = tmp_path / "artifacts/run-first/02-ignore-rules.txt"
    retry = initial(workspace, spec, "retry")
    retry["run_id"] = "run-first"  # the re-entered context of the same run
    if not same:
        with (workspace / ".git/info/exclude").open("a", encoding="utf-8") as extra:
            extra.write("*.tmp\n")
    config = {"configurable": {"thread_id": "retry"}}
    graph.invoke(retry, config=config)
    values = graph.get_state(config).values
    if same:
        assert values["base_manifest_sha256"] == graph.get_state(first).values[
            "base_manifest_sha256"]
    else:
        assert values["status"] == "needs-human"
        assert values["errors"][0].startswith("workspace preflight failed: immutable artifact "
                                              f"already exists with different content: {rules}")


def test_pre_attestation_checkpoint_does_not_run_its_pending_call(tmp_path):
    """A pre-0.1.7 run parked before a role resumes to needs-human; the role never runs."""
    from agent_team_graph.graph import validate_run_input

    workspace, spec = make_repo(tmp_path)
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    state = initial(workspace, spec, "old-run")
    state.update(validate_run_input(state, tmp_path / "artifacts"))
    state.update(status="running", attempt=1, execution_policy_version=1,
                 attempt_start="planner", schema_version="graph-run-v1")
    config = {"configurable": {"thread_id": "old-run"}}
    old = StateGraph(GraphState)
    old.add_node("prepare_attempt", lambda s: {})
    old.add_node("planner", lambda s: {})
    old.add_edge(START, "prepare_attempt")
    old.add_edge("prepare_attempt", "planner")
    old.add_edge("planner", END)
    old.compile(checkpointer=SqliteSaver(connection), interrupt_before=["planner"]).invoke(
        state, config, durability="sync")
    runner = FakeRunner()
    graph = _graph(tmp_path, runner, connection)
    assert graph.get_state(config).next == ("planner",)
    resume_graph(graph, config)
    values = graph.get_state(config).values
    assert runner.roles == []
    assert values["status"] == "needs-human"
    assert values["errors"] == [f"planner_node: RecoveryError: {PRE_ATTESTATION}"]


def test_tracked_directory_swapped_for_an_outside_symlink_fails_closed(tmp_path):
    workspace, _ = make_repo(tmp_path)
    (workspace / "src").mkdir()
    (workspace / "src/a.py").write_text("x = 1\n", encoding="utf-8")
    base = _commit_all(workspace, "src")
    baseline = baseline_for(workspace, base)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "a.py").write_text("x = 1\n", encoding="utf-8")  # identical bytes
    (workspace / "src/a.py").unlink()
    (workspace / "src").rmdir()
    os.symlink(outside, workspace / "src")
    assert _refused(workspace, base, baseline) == "path resolves outside repository: src/a.py"


def test_tracked_file_matching_an_ignore_rule_is_not_ignored_output(tmp_path):
    """A committed file that .gitignore matches stays a base file, in both modes."""
    workspace, spec = make_repo(tmp_path)
    (workspace / ".gitignore").write_text("README.md\n", encoding="utf-8")
    base = _commit_all(workspace, "ignore rule for a tracked file")
    for strict in (False, True):
        snapshot = _snapshot(workspace, base, baseline_for(workspace, base, strict_ignored=strict),
                             strict)
        assert (snapshot["changes"], snapshot["ignored_paths"]) == ({}, [])
    graph = _graph(tmp_path, FakeRunner(writes={"new.txt": "allowed\n"}))
    state = initial(workspace, spec, "tracked-ignored")
    state.update(allowed_paths=["new.txt"], strict_ignored=True)
    config = {"configurable": {"thread_id": "tracked-ignored"}}
    graph.invoke(state, config=config)
    graph.invoke(Command(resume="approve"), config=config)
    values = graph.get_state(config).values
    assert values["status"] == "approved", values["errors"]


def test_relative_excludes_file_resolves_against_the_repository(tmp_path, monkeypatch):
    from agent_team_graph.graph import _ignore_rules_text

    workspace, _ = make_repo(tmp_path)
    (workspace / "rules").write_text("hidden\n", encoding="utf-8")
    _git(workspace, "config", "core.excludesFile", "rules")
    monkeypatch.chdir(tmp_path)  # the runtime is launched from outside the repository
    # info/exclude (git's template comments) follows the configured file.
    assert _ignore_rules_text(workspace).splitlines()[0] == "hidden"


def test_a_write_during_hashing_fails_closed(tmp_path, monkeypatch):
    """The bytes read must still be the bytes on disk when the snapshot ends."""
    from agent_team_graph import graph as graph_module

    workspace, _ = make_repo(tmp_path)
    base = _head(workspace)
    baseline = baseline_for(workspace, base)
    (workspace / "README.md").write_text("reviewed\n", encoding="utf-8")
    real = graph_module._file_digest

    def write_after_read(repo_root, relative, **kwargs):
        digest = real(repo_root, relative, **kwargs)
        (repo_root / relative).write_text("swapped after hashing\n", encoding="utf-8")
        return digest

    monkeypatch.setattr(graph_module, "_file_digest", write_after_read)
    assert _refused(workspace, base, baseline) == (
        "workspace changed while it was being attested (first: 'README.md'); "
        "retry once writers have stopped"
    )


def test_a_directory_swapped_during_hashing_fails_closed(tmp_path, monkeypatch):
    from agent_team_graph import graph as graph_module

    workspace, _ = make_repo(tmp_path)
    (workspace / "src").mkdir()
    for name in ("a.py", "b.py"):
        (workspace / "src" / name).write_text("x = 1\n", encoding="utf-8")
    base = _commit_all(workspace, "src")
    baseline = baseline_for(workspace, base)
    outside = tmp_path / "outside"
    outside.mkdir()
    for name in ("a.py", "b.py"):
        (outside / name).write_text("x = 1\n", encoding="utf-8")
    real = graph_module._file_digest

    def swap_after_first(repo_root, relative, **kwargs):
        digest = real(repo_root, relative, **kwargs)
        if relative == "src/a.py":
            os.rename(repo_root / "src", tmp_path / "moved-src")
            os.symlink(outside, repo_root / "src")
        return digest

    monkeypatch.setattr(graph_module, "_file_digest", swap_after_first)
    assert _refused(workspace, base, baseline).startswith(
        "workspace changed while it was being attested (first: 'src/a.py')")


def test_empty_excludes_file_setting_names_no_file(tmp_path):
    from agent_team_graph.graph import _ignore_rules_text

    workspace, _ = make_repo(tmp_path)
    _git(workspace, "config", "core.excludesFile", "")
    info_exclude = (workspace / ".git/info/exclude").read_text(encoding="utf-8")
    assert _ignore_rules_text(workspace).splitlines() == info_exclude.splitlines()


@pytest.mark.parametrize("direction", ["file-to-dir", "dir-to-file"])
def test_file_and_directory_replacements_are_a_deletion_and_an_addition(tmp_path, direction):
    workspace, _ = make_repo(tmp_path)
    if direction == "file-to-dir":
        (workspace / "item").write_text("file\n", encoding="utf-8")
        old, new = "item", "item/child"
    else:
        (workspace / "item").mkdir()
        (workspace / "item/child").write_text("file\n", encoding="utf-8")
        old, new = "item/child", "item"
    base = _commit_all(workspace, "item")
    baseline = baseline_for(workspace, base)
    if direction == "file-to-dir":
        (workspace / "item").unlink()
        (workspace / "item").mkdir()
        (workspace / "item/child").write_text("now a file below\n", encoding="utf-8")
    else:
        (workspace / "item/child").unlink()
        (workspace / "item").rmdir()
        (workspace / "item").write_text("now a file\n", encoding="utf-8")
    changes = _snapshot(workspace, base, baseline)["changes"]
    assert sorted(changes) == sorted([old, new])
    assert changes[old] is None and changes[new]["mode"] == "100644"


def test_repository_inside_ignored_content_matters_only_when_strict(tmp_path):
    """A tool that installs a git checkout into ignored output must not stop a run."""
    workspace, _ = make_repo(tmp_path)
    (workspace / ".gitignore").write_text("node_modules/\n", encoding="utf-8")
    base = _commit_all(workspace, "ignore deps")
    loose, strict = baseline_for(workspace, base), baseline_for(workspace, base, strict_ignored=True)
    (workspace / "node_modules/dep").mkdir(parents=True)
    _git(workspace / "node_modules/dep", "init", "-q")
    (workspace / "README.md").write_text("edited\n", encoding="utf-8")
    assert _snapshot(workspace, base, loose)["changed_paths"] == ["README.md"]
    assert _refused(workspace, base, strict, strict=True).startswith(
        "nested repository boundaries changed during the run (new: ['node_modules/dep']")


def test_isolated_listing_uses_the_repository_ignorecase(tmp_path):
    """git init takes core.ignorecase from the temp filesystem; the run freezes the repo's."""
    workspace, _ = make_repo(tmp_path)
    _git(workspace, "config", "core.ignorecase", "false")
    (workspace / ".gitignore").write_text("*.LOG\n", encoding="utf-8")
    base = _commit_all(workspace, "case-sensitive ignore")
    baseline = baseline_for(workspace, base)
    assert baseline.document["ignorecase"] is False
    (workspace / "debug.log").write_text("not matched by *.LOG here\n", encoding="utf-8")
    assert _snapshot(workspace, base, baseline)["changed_paths"] == ["debug.log"]


def test_line_ending_only_rewrite_names_a_likely_cause(tmp_path):
    workspace, _ = make_repo(tmp_path)
    (workspace / ".gitattributes").write_text("* text=auto eol=lf\n", encoding="utf-8")
    (workspace / "a.txt").write_bytes(b"one\ntwo\n")
    base = _commit_all(workspace, "text")
    baseline = baseline_for(workspace, base)
    (workspace / "a.txt").write_bytes(b"one\r\ntwo\r\n")
    assert _refused(workspace, base, baseline) == (
        "git and the filesystem disagree on changed paths: filesystem-only ['a.txt'], "
        "git-only []; likely content change git does not report (line-ending normalization "
        "or a clean filter?)"
    )
