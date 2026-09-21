"""Exit codes are the wrapper-facing contract; the JSON body is for humans."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from helpers import make_repo

from agent_team_graph.cli import _exit_code, _thread_lock, _view, build_parser, main


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        ("approved", 0),
        ("running", 3),
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
                created_at="2026-01-01T00:00:00+00:00",
                interrupts=(),
            )

    view = _view(Graph(), "blocked")
    assert view["approval"] == "approve"
    assert "receipt blocked" in view["approval_note"]
    assert view["excluded_paths_not_attested"] == [".reviewer-cache"]


# --- end-to-end through main(): models are small Python commands ---------------

_ANSWER = ["-c", "print('ok')", "{prompt}"]
_SHIP = ["-c", "print('VERDICT: SHIP')", "{prompt}"]
_FAIL = ["-c", "import sys; print('boom'); sys.exit(1)", "{prompt}"]


def _models(tmp_path: Path, monkeypatch, coder=_ANSWER) -> None:
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {
                    "answer": {"command": sys.executable, "args": _ANSWER},
                    "ship": {"command": sys.executable, "args": _SHIP},
                    "coder": {"command": sys.executable, "args": coder},
                },
                "roles": {
                    "langgraph-conductor.planner": "answer",
                    "langgraph-conductor.researcher": "answer",
                    "langgraph-conductor.coder": "coder",
                    "langgraph-conductor.reviewer": "ship",
                },
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("AGENT_TEAM_MODELS_CONFIG", str(config))


def _cli(tmp_path: Path, *args: str) -> int:
    return main([*args, "--state-dir", str(tmp_path / "state")])


def _run(tmp_path: Path, workspace: Path, spec: Path, *extra: str) -> int:
    return _cli(
        tmp_path, "run", "--project-id", "demo", "--workspace", str(workspace),
        "--spec", str(spec), "--task", "t", "--test-command", "true",
        "--allow-path", "README.md", *extra,
    )


def test_run_refuses_an_existing_thread(tmp_path: Path, monkeypatch, capsys):
    """Re-running inherited the old review/approval and dropped a pending interrupt."""
    _models(tmp_path, monkeypatch)
    workspace, spec = make_repo(tmp_path)
    assert _run(tmp_path, workspace, spec, "--thread-id", "t1") == 3
    assert _run(tmp_path, workspace, spec, "--thread-id", "t1") == 2
    assert "already exists" in capsys.readouterr().err
    # Still parked at the original approval interrupt.
    assert _cli(tmp_path, "status", "--thread-id", "t1") == 3


def test_a_crashed_run_exits_6_not_3(tmp_path: Path, monkeypatch):
    _models(tmp_path, monkeypatch, coder=_FAIL)
    workspace, spec = make_repo(tmp_path)
    assert _run(tmp_path, workspace, spec, "--thread-id", "crash") == 6
    assert _cli(tmp_path, "status", "--thread-id", "crash") == 6


def test_a_crash_inside_context_is_incomplete_not_unknown(tmp_path: Path, monkeypatch):
    _models(tmp_path, monkeypatch)
    workspace, _ = make_repo(tmp_path)
    missing = tmp_path / "missing-spec.md"
    assert _run(tmp_path, workspace, missing, "--thread-id", "ctx") == 6
    assert _cli(tmp_path, "status", "--thread-id", "ctx") == 6


def test_resume_and_approve_on_an_unknown_thread_exit_5(tmp_path: Path, monkeypatch):
    _models(tmp_path, monkeypatch)
    assert _cli(tmp_path, "resume", "--thread-id", "nope") == 5
    assert _cli(tmp_path, "approve", "--thread-id", "nope", "--decision", "approve") == 5


def test_a_malformed_models_json_does_not_break_status_or_reject(
    tmp_path: Path, monkeypatch
):
    _models(tmp_path, monkeypatch)
    workspace, spec = make_repo(tmp_path)
    assert _run(tmp_path, workspace, spec, "--thread-id", "parked") == 3
    (tmp_path / "models.json").write_text("{not json", encoding="utf-8")
    assert _cli(tmp_path, "status", "--thread-id", "parked") == 3
    assert _cli(tmp_path, "approve", "--thread-id", "parked", "--decision", "reject") == 4


_HOLD_LOCK = """
import sys, time
from pathlib import Path
from agent_team_graph.cli import _thread_lock
with _thread_lock(Path(sys.argv[1]), "held") as held:
    print(held, flush=True)
    time.sleep(30)
"""


def test_a_thread_held_by_another_process_is_busy(tmp_path: Path, monkeypatch, capsys):
    _models(tmp_path, monkeypatch)
    workspace, spec = make_repo(tmp_path)
    assert _run(tmp_path, workspace, spec, "--thread-id", "held") == 3
    state_dir = (tmp_path / "state").resolve()
    holder = subprocess.Popen(
        [
            sys.executable,
            "-c",
            _HOLD_LOCK,
            str(state_dir),
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "True"
        capsys.readouterr()
        assert _cli(tmp_path, "status", "--thread-id", "held") == 7
        assert json.loads(capsys.readouterr().out)["status"] == "busy"
        assert _cli(tmp_path, "approve", "--thread-id", "held", "--decision", "approve") == 7
        assert "busy" in capsys.readouterr().err
    finally:
        holder.kill()
        holder.wait()
    # Released: the lock file is still there, and its existence alone is not busy.
    assert _cli(tmp_path, "status", "--thread-id", "held") == 3


def test_status_holds_the_lock_while_it_classifies(tmp_path: Path, monkeypatch):
    """Nothing can start on the thread between status reading and classifying it."""
    import agent_team_graph.cli as cli_module

    _models(tmp_path, monkeypatch)
    state_dir = (tmp_path / "state").resolve()
    seen: list[bool] = []
    real_view = cli_module._view

    def view_while_probing(graph, thread_id):
        with _thread_lock(state_dir, thread_id) as held:
            seen.append(held)
        return real_view(graph, thread_id)

    monkeypatch.setattr(cli_module, "_view", view_while_probing)
    assert _cli(tmp_path, "status", "--thread-id", "probe") == 5
    assert seen == [False]


def test_a_run_on_a_thread_held_by_another_process_invokes_no_role(
    tmp_path: Path, monkeypatch, capsys
):
    _models(tmp_path, monkeypatch)
    workspace, spec = make_repo(tmp_path)
    state_dir = (tmp_path / "state").resolve()
    state_dir.mkdir()
    holder = subprocess.Popen(
        [sys.executable, "-c", _HOLD_LOCK, str(state_dir)], stdout=subprocess.PIPE, text=True
    )
    try:
        assert holder.stdout.readline().strip() == "True"
        assert _run(tmp_path, workspace, spec, "--thread-id", "held") == 7
        assert "busy" in capsys.readouterr().err
    finally:
        holder.kill()
        holder.wait()
    assert not (state_dir / "artifacts").exists()
    assert _cli(tmp_path, "status", "--thread-id", "held") == 5


def test_a_generated_thread_id_runs_and_can_be_approved(tmp_path: Path, monkeypatch, capsys):
    _models(tmp_path, monkeypatch)
    workspace, spec = make_repo(tmp_path)
    assert _run(tmp_path, workspace, spec) == 3
    thread_id = json.loads(capsys.readouterr().out)["thread_id"]
    assert thread_id.startswith("demo-")
    assert _cli(tmp_path, "approve", "--thread-id", thread_id, "--decision", "approve") == 0


_MAIN = "import sys; from agent_team_graph.cli import main; sys.exit(main(sys.argv[1:]))"


def test_a_second_run_is_refused_while_the_first_is_inside_a_role(
    tmp_path: Path, monkeypatch
):
    """The winning run keeps the lock while its roles execute, not just while it checks."""
    started, release = tmp_path / "planner.started", tmp_path / "planner.release"
    blocking_planner = [
        "-c",
        (
            "import pathlib, sys, time\n"
            f"pathlib.Path({str(started)!r}).open('a').write('x')\n"
            f"while not pathlib.Path({str(release)!r}).exists(): time.sleep(0.05)\n"
            "print('plan')"
        ),
        "{prompt}",
    ]
    _models(tmp_path, monkeypatch)
    config = json.loads((tmp_path / "models.json").read_text())
    config["models"]["blocking"] = {"command": sys.executable, "args": blocking_planner}
    config["roles"]["langgraph-conductor.planner"] = "blocking"
    (tmp_path / "models.json").write_text(json.dumps(config))
    workspace, spec = make_repo(tmp_path)
    args = [
        "run", "--project-id", "demo", "--workspace", str(workspace), "--spec", str(spec),
        "--task", "t", "--test-command", "true", "--allow-path", "README.md",
        "--thread-id", "race", "--state-dir", str(tmp_path / "state"),
    ]
    first = subprocess.Popen(
        [sys.executable, "-c", _MAIN, *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 60
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert started.exists(), "the first run never reached its planner"
        assert main(args) == 7
        assert started.read_text() == "x"
    finally:
        release.touch()
        assert first.wait(timeout=60) == 3
    assert started.read_text() == "x"
