"""Exit codes are the wrapper-facing contract; the JSON body is for humans."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from agent_team_graph.cli import _exit_code, _view, build_parser


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        ("approved", 0),
        ("running", 4),
        ("rejected", 4),
        ("needs-human", 4),
        ("not-found", 5),
        ("something-new", 4),
    ],
)
def test_status_maps_to_a_distinct_exit_code(status: str, expected: int):
    assert _exit_code({"status": status, "next": []}) == expected


def test_max_attempts_is_bounded_and_reports_real_choices(capsys):
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(
            [
                "run", "--project-id", "p", "--spec", "s", "--task", "t",
                "--test-command", "true", "--allow-path", "src",
                "--max-attempts", "9",
            ]
        )
    # argparse renders a tuple as "1, 2, 3, 4, 5"; a bare range() leaks "range(1, 6)".
    assert "range(" not in capsys.readouterr().err


def test_exclude_path_is_repeatable():
    args = build_parser().parse_args(
        [
            "run",
            "--project-id", "p",
            "--spec", "s",
            "--task", "t",
            "--test-command", "true",
            "--allow-path", "src",
            "--exclude-path", ".codex",
            "--exclude-path", ".claude",
        ]
    )
    assert args.exclude_path == [".codex", ".claude"]


def test_view_distinguishes_recorded_approve_from_blocked_receipt():
    class Graph:
        def get_state(self, config):
            return SimpleNamespace(
                values={
                    "status": "needs-human",
                    "approval": "approve",
                    "excluded_paths": [".reviewer-cache"],
                },
                next=(),
            )

    view = _view(Graph(), "blocked")
    assert view["approval"] == "approve"
    assert "receipt blocked" in view["approval_note"]
    assert view["excluded_paths_not_attested"] == [".reviewer-cache"]


def test_only_a_real_ship_interrupt_returns_approval_exit_code():
    class Graph:
        def get_state(self, config):
            return SimpleNamespace(values={"status": "running"}, next=("approval",),
                                   interrupts=(SimpleNamespace(value={"kind": "ship-approval"}),))
    assert _exit_code(_view(Graph(), "t")) == 3
    assert _exit_code({"status": "running", "next": ["approval"]}) == 4


@pytest.fixture
def cli_run(tmp_path, monkeypatch, capsys):
    import json

    from helpers import FakeRunner, make_repo

    from agent_team_graph.cli import main
    from agent_team_graph.registry import RoleRunner

    workspace, spec = make_repo(tmp_path)
    runner = FakeRunner()
    monkeypatch.setattr(RoleRunner, "preflight", lambda self, workspace: None)
    monkeypatch.setattr(RoleRunner, "resolve_adapter", lambda self, role, workspace:
                        ("fake", {"args": []}, "fake-model"))
    monkeypatch.setattr(RoleRunner, "run", lambda self, role, prompt, workspace, **kw:
                        runner.run(role, prompt, workspace))
    state = tmp_path / "state"
    common = ["--state-dir", str(state), "--thread-id", "same-thread"]
    run_args = ["--project-id", "demo", "--workspace", str(workspace), "--spec", str(spec),
                "--task", "bounded task", "--allow-path", "README.md", "--test-command", "true"]

    def invoke(command, *extra):
        argv = [command, *common, *(run_args if command == "run" else []), *extra]
        rc = main(argv)
        return rc, json.loads(capsys.readouterr().out)
    return invoke, runner, workspace, state


@pytest.mark.parametrize("database_exists", [False, True])
@pytest.mark.parametrize("command, extra", [("status", []), ("resume", []),
                                           ("approve", ["--decision", "reject"])])
def test_unknown_threads_have_one_contract_without_registry(cli_run, monkeypatch, tmp_path,
                                                           command, extra, database_exists):
    invoke, runner, _, state = cli_run
    if database_exists:
        import sqlite3
        state.mkdir()
        sqlite3.connect(state / "runs.sqlite3").close()
    config = tmp_path / "broken.json"
    config.write_text("{broken")
    monkeypatch.setenv("AGENT_TEAM_MODELS_CONFIG", str(config))
    rc, view = invoke(command, *extra)
    assert rc == 5 and view["status"] == "not-found"
    assert runner.roles == []
    assert state.exists() is database_exists


def test_terminal_thread_reuse_clears_all_run_state_and_keeps_history(cli_run):
    from agent_team_graph.cli import _open_runtime
    invoke, runner, _, state = cli_run
    rc, first = invoke("run")
    assert rc == 3
    assert invoke("approve", "--decision", "reject")[0] == 4
    runner.verdicts = ["DISCUSS"]
    rc, second = invoke("run")
    assert rc == 4 and second["status"] == "needs-human"
    assert second["approval"] == "" and second["verdict"] == "DISCUSS"
    assert first["run_id"] != second["run_id"]
    assert len(second["usage"]) == 4
    assert sum(a["name"] == "00-context.json" for a in second["artifacts"]) == 1
    assert not any(a in second["artifacts"] for a in first["artifacts"])
    with _open_runtime(state) as graph:
        history = list(graph.get_state_history({"configurable": {"thread_id": "same-thread"}}))
    assert any(s.values.get("run_id") == first["run_id"] and
               s.values.get("status") == "rejected" for s in history)
    from pathlib import Path
    assert all(Path(a["path"]).exists() for a in first["artifacts"])


def test_pending_approval_is_preserved_by_run_and_resume(cli_run):
    invoke, runner, _, _ = cli_run
    _, first = invoke("run")
    assert invoke("run")[0] == 2
    assert invoke("resume")[0] == 3
    rc, view = invoke("status")
    assert rc == 3 and view["run_id"] == first["run_id"]
    assert len(runner.roles) == 4


def test_broken_registry_does_not_break_status_or_reject(cli_run, tmp_path, monkeypatch):
    invoke, _, _, _ = cli_run
    assert invoke("run")[0] == 3
    config = tmp_path / "broken.json"
    config.write_text("{broken")
    monkeypatch.setenv("AGENT_TEAM_MODELS_CONFIG", str(config))
    assert invoke("status")[0] == 3
    rc, view = invoke("approve", "--decision", "reject")
    assert rc == 4 and view["status"] == "rejected"
    assert invoke("approve", "--decision", "approve")[0] == 2
    assert invoke("resume")[0] == 4


@pytest.mark.parametrize("command", ["", "   ", "'unclosed"])
def test_invalid_test_command_is_rejected_before_models_or_checkpoint(cli_run, command):
    invoke, runner, _, state = cli_run
    assert invoke("run", "--test-command", command)[0] == 2
    assert runner.roles == []
    assert not state.exists()


def test_dirty_workspace_stops_before_models(cli_run):
    invoke, runner, workspace, _ = cli_run
    (workspace / "SPEC.md").write_text("existing untracked spec")
    rc, view = invoke("run")
    assert rc == 4 and view["status"] == "needs-human"
    assert runner.roles == []
    assert "SPEC.md" in view["errors"][0]


def test_invalid_new_run_preserves_previous_approval(cli_run):
    invoke, runner, _, _ = cli_run
    _, first = invoke("run")
    assert invoke("run", "--allow-path", "../escape")[0] == 2
    _, latest = invoke("status")
    assert latest == first
    assert len(runner.roles) == 4


def test_thread_mutations_fail_immediately_while_locked(cli_run):
    from agent_team_graph.cli import _thread_lock
    invoke, _, _, state = cli_run
    assert invoke("run")[0] == 3
    with _thread_lock(state, "same-thread"):
        assert invoke("status")[0] == 3
        assert invoke("approve", "--decision", "reject")[0] == 2
        assert invoke("resume")[0] == 2
        assert invoke("run")[0] == 2
    assert invoke("approve", "--decision", "reject")[0] == 4


@pytest.mark.parametrize("signum", [2, 15])
def test_cancel_during_validation_does_not_create_checkpoint_or_call(cli_run, monkeypatch, signum):
    import os

    from agent_team_graph import cli

    invoke, runner, _, state = cli_run
    original = cli.validate_run_input

    def cancel_after_validation(*args):
        result = original(*args)
        os.kill(os.getpid(), signum)
        return result

    monkeypatch.setattr(cli, "validate_run_input", cancel_after_validation)
    rc, view = invoke("run")
    assert rc == 128 + signum and "cancelled before checkpoint" in view["error"]
    assert runner.roles == []
    assert list((state / "artifacts").iterdir()) == []
    with cli._open_runtime(state) as graph:
        assert list(graph.get_state_history({"configurable": {"thread_id": "same-thread"}})) == []


def test_cli_resume_reuses_only_its_interrupted_completed_call(cli_run, monkeypatch):
    from agent_team_graph.artifacts import ArtifactStore

    invoke, runner, _, _ = cli_run
    original = ArtifactStore.write
    crashed = False

    def crash_after_completion(store, run_id, name, content):
        nonlocal crashed
        if name == "30-code-attempt-1.md" and not crashed:
            crashed = True
            raise RuntimeError("crash before coder checkpoint")
        return original(store, run_id, name, content)

    monkeypatch.setattr(ArtifactStore, "write", crash_after_completion)
    rc, view = invoke("run")
    assert rc == 4 and view["next"] == ["coder"]
    rc, view = invoke("resume")
    assert rc == 3 and view["next"] == ["approval"]
    assert runner.roles.count("langgraph-conductor.coder") == 1
    assert len(view["usage"]) == 4
