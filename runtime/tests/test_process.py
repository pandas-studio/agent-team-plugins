"""Use real child processes, with test-owned lifetimes and bounded waits."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

import pytest

from agent_team_graph.process import Cancellation, run_process, signal_handlers


def test_binary_output_and_closed_stdin(tmp_path):
    result = run_process([sys.executable, "-c", (
        "import os,sys; assert sys.stdin.read()==''; "
        "os.write(1,b'out\\xff\\r\\n'); os.write(2,b'err\\xfe\\n')"
    )], cwd=tmp_path, timeout=5)
    assert result.returncode == 0
    assert result.stdout == "out\ufffd\r\n"
    assert result.stderr == "err\ufffd\n"


def test_explicit_input_and_nonzero_exit(tmp_path):
    result = run_process([sys.executable, "-c", "import sys; print(sys.stdin.read()); sys.exit(7)"],
                         cwd=tmp_path, timeout=5, input_bytes=b"context")
    assert result.returncode == 7 and result.stdout == "context\n"


def test_timeout_retains_decoded_partial_output(tmp_path):
    result = run_process([sys.executable, "-c", (
        "import os,time; os.write(1,b'OUT\\xff\\n'); os.write(2,b'ERR\\n'); time.sleep(10)"
    )], cwd=tmp_path, timeout=0.2, terminate_grace=0.1)
    assert result.returncode == 124 and result.timed_out
    assert result.stdout == "OUT\ufffd\n" and result.stderr == "ERR\n"


def _not_running(pid):
    result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                            capture_output=True, text=True, check=False)
    return result.returncode != 0 or not result.stdout.strip() or result.stdout.strip().startswith("Z")


@pytest.mark.parametrize("parent_exits", [False, True])
def test_descendants_are_killed_even_when_leader_exits(tmp_path, parent_exits):
    marker = tmp_path / "pid"
    # Child ignores TERM and inherits stdout/stderr. Its marker proves the
    # handler is installed before the leader exits or waits for its timeout.
    child = ("import os,signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
             f"pathlib.Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)")
    parent = ("import subprocess,sys,time,pathlib; "
              f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
              f"marker=pathlib.Path({str(marker)!r});\n"
              "while not marker.exists(): time.sleep(.01)\n" +
              ("sys.exit(0)" if parent_exits else "time.sleep(30)"))
    started = time.monotonic()
    result = run_process([sys.executable, "-c", parent], cwd=tmp_path, timeout=1,
                         terminate_grace=0.15)
    pid = int(marker.read_text())
    try:
        deadline = time.monotonic() + 3
        while not _not_running(pid) and time.monotonic() < deadline:
            time.sleep(0.02)
        assert _not_running(pid)
        assert result.returncode == (0 if parent_exits else 124)
        assert time.monotonic() - started < 5
    finally:
        if not _not_running(pid):
            os.kill(pid, signal.SIGKILL)


def test_cancellation_before_spawn_and_handler_restoration(tmp_path):
    cancellation = Cancellation(signal.SIGINT)
    before = signal.getsignal(signal.SIGTERM)
    with signal_handlers(cancellation):
        result = run_process(["does-not-exist"], cwd=tmp_path, timeout=5,
                             cancellation=cancellation)
    assert signal.getsignal(signal.SIGTERM) == before
    assert result.cancelled_signal == signal.SIGINT and result.returncode == 130


def test_launch_failure_is_a_result(tmp_path):
    result = run_process(["/no/such/program"], cwd=tmp_path, timeout=1)
    assert result.returncode == 127 and "FileNotFoundError" in result.stderr


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM, signal.SIGHUP])
def test_already_ignored_signal_stays_ignored(signum):
    """nohup (SIGHUP) or a background job (SIGINT) must not start cancelling runs."""
    handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    original = {s: signal.getsignal(s) for s in handled}
    try:
        # Known starting point, even if pytest itself runs under nohup.
        for s in handled:
            signal.signal(s, signal.SIG_DFL)
        signal.signal(signum, signal.SIG_IGN)
        with signal_handlers(Cancellation()):
            assert signal.getsignal(signum) is signal.SIG_IGN
            for other in handled:
                if other != signum:
                    assert signal.getsignal(other) not in (signal.SIG_IGN, signal.SIG_DFL)
        assert signal.getsignal(signum) is signal.SIG_IGN
        for other in handled:
            if other != signum:
                assert signal.getsignal(other) is signal.SIG_DFL
    finally:
        for s, handler in original.items():
            signal.signal(s, handler)


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM, signal.SIGHUP])
def test_cli_signal_cleans_child_and_preserves_nonapproval_status(tmp_path, signum):
    import json

    from helpers import make_repo

    workspace, spec = make_repo(tmp_path)
    marker = tmp_path / "model-pid"
    config = tmp_path / "models.json"
    # Written under a temporary name and renamed, so the test never reads it half-written.
    code = ("import os,time,pathlib; "
            f"tmp = pathlib.Path({str(marker)!r} + '.tmp'); tmp.write_text(str(os.getpid())); "
            f"os.replace(tmp, {str(marker)!r}); time.sleep(30)")
    config.write_text(json.dumps({
        "models": {"fake": {"command": sys.executable, "args": ["-c", code]}},
        "roles": {f"langgraph-conductor.{role}": "fake"
                  for role in ("planner", "researcher", "coder", "reviewer")},
    }))
    env = dict(os.environ, AGENT_TEAM_MODELS_CONFIG=str(config))
    for name in list(env):
        if name.startswith("LANGGRAPH_CONDUCTOR_") or name == "REGISTRY_CMD_OVERRIDE":
            env.pop(name)
    state = tmp_path / "state"
    args = [sys.executable, "-m", "agent_team_graph.cli", "run", "--state-dir", str(state),
            "--thread-id", "signal", "--workspace", str(workspace), "--project-id", "demo",
            "--spec", str(spec), "--task", "test", "--test-command", "true",
            "--allow-path", "README.md"]
    process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    try:
        deadline = time.monotonic() + 10
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.025)
        assert marker.exists()
        pid = int(marker.read_text())
        process.send_signal(signum)
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 128 + signum, (stdout, stderr)
        assert _not_running(pid)
        view = json.loads(stdout)
        assert not view["awaiting_approval"]
        assert view["status"] == "needs-human"
        inspected = subprocess.run(
            [sys.executable, "-m", "agent_team_graph.cli", "status", "--state-dir", str(state),
             "--thread-id", "signal"], capture_output=True, text=True, env=env, check=False,
        )
        assert inspected.returncode == 4
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if marker.exists() and not _not_running(int(marker.read_text())):
            os.kill(int(marker.read_text()), signal.SIGKILL)


def test_cleanup_error_keeps_timeout_and_reaps_direct_child(tmp_path, monkeypatch):
    def denied_group(*args):
        raise PermissionError("simulated group cleanup denial")

    monkeypatch.setattr(os, "killpg", denied_group)
    result = run_process([sys.executable, "-c", "import time; time.sleep(10)"], cwd=tmp_path,
                         timeout=.1, terminate_grace=.1)
    assert result.returncode == 124 and result.timed_out
    assert "cleanup denial" in result.cleanup_error


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS reports EPERM for zombie-only groups")
@pytest.mark.parametrize("signum", [0, signal.SIGTERM, signal.SIGKILL])
def test_unreaped_zombie_group_is_not_a_cleanup_denial(signum):
    from agent_team_graph.process import _signal_group

    process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                               start_new_session=True)
    try:
        process.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-p", str(process.pid), "-o", "stat="],
                                   capture_output=True, text=True, check=False)
            if state.stdout.strip().startswith("Z"):
                break
            time.sleep(.01)
        else:
            pytest.fail("child did not become an unreaped zombie")
        # Do not poll/wait: reaping the leader would hide the cleanup race.
        assert _signal_group(process.pid, signum) is False
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)


@pytest.mark.parametrize("members,gone", [
    ("", True),
    ("123 Z\n", True),
    ("123 Z+\n123 Z\n", True),
    ("123 Z\n123 S\n", False),
    ("123 S\n", False),
    ("123\n", False),
])
def test_group_permission_denial_distinguishes_zombies_from_live_members(monkeypatch, members, gone):
    from agent_team_graph import process as module

    def denied(*args):
        raise PermissionError("group signal denied")

    monkeypatch.setattr(os, "killpg", denied)
    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs:
                        subprocess.CompletedProcess(args[0], 0, members, ""))
    if gone:
        assert module._signal_group(123, 0) is False
    else:
        with pytest.raises(PermissionError, match="group signal denied"):
            module._signal_group(123, 0)


@pytest.mark.parametrize("denials", [1, 2])
def test_cleanup_rechecks_a_denial_once_but_preserves_persistent_denials(tmp_path, monkeypatch, denials):
    original = os.killpg
    term_calls = []

    def deny_term(pgid, signum):
        if signum == signal.SIGTERM:
            term_calls.append(pgid)
            if len(term_calls) <= denials:
                raise PermissionError("simulated transient group denial")
        return original(pgid, signum)

    monkeypatch.setattr(os, "killpg", deny_term)
    result = run_process([sys.executable, "-c", "import time; time.sleep(30)"], cwd=tmp_path,
                         timeout=.1, terminate_grace=.1)
    assert result.returncode == 124 and result.timed_out
    assert len(term_calls) == 2
    assert bool(result.cleanup_error) == (denials == 2)
