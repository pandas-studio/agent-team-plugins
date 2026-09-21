"""The bounded runner: group kill on timeout, text output, no decode crash."""

from __future__ import annotations

import os
import signal
import sys
import time
from pathlib import Path

import pytest

import agent_team_graph.proc as proc_module
from agent_team_graph.proc import run_bounded

# Generous against a loaded CI runner: each child only has to start Python and
# spawn one process before the timeout fires. The processes it spawns sleep far
# longer than any bound asserted below.
TIMEOUT = 3
SLEEP = "120"


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _spawner(pidfile: Path, *, new_session: bool, leader_waits: bool) -> list[str]:
    """A child that starts `sleep` and records its pid via rename (never half-written)."""
    code = (
        "import os, subprocess, sys, time\n"
        f"child = subprocess.Popen(['sleep', '{SLEEP}'], start_new_session={new_session})\n"
        "open(sys.argv[1] + '.tmp', 'w').write(str(child.pid))\n"
        "os.rename(sys.argv[1] + '.tmp', sys.argv[1])\n"
        + (f"time.sleep({SLEEP})\n" if leader_waits else "")
    )
    return [sys.executable, "-c", code, str(pidfile)]


@pytest.fixture
def pidfile(tmp_path: Path):
    """Where the spawned `sleep` records its pid; it is killed whatever the test does."""
    path = tmp_path / "descendant.pid"
    yield path
    if path.exists():
        try:
            os.kill(int(path.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass


def _descendant(pidfile: Path) -> int:
    assert pidfile.exists(), "the child did not start its descendant before the timeout"
    return int(pidfile.read_text())


def _gone_within(pid: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while _alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    return not _alive(pid)


def test_timeout_kills_the_grandchild_too(tmp_path: Path, pidfile: Path):
    """subprocess.run(timeout=) killed only the direct child; a grandchild survived."""
    argv = _spawner(pidfile, new_session=False, leader_waits=True)
    result = run_bounded(argv, tmp_path, timeout=TIMEOUT)
    assert result.timed_out is True
    assert _gone_within(_descendant(pidfile), 5)


def test_a_leader_that_already_exited_still_has_its_group_killed(tmp_path: Path, pidfile: Path):
    """The leader exits at once; its grandchild keeps the pipe open until the timeout."""
    argv = _spawner(pidfile, new_session=False, leader_waits=False)
    result = run_bounded(argv, tmp_path, timeout=TIMEOUT)
    assert result.timed_out is True
    # The leader is reaped by now, so killpg reached the group through the grandchild.
    assert result.returncode == 0
    assert _gone_within(_descendant(pidfile), 5)


def test_an_escaped_descendant_holding_the_pipe_does_not_hang_the_runner(
    tmp_path: Path, pidfile: Path, monkeypatch
):
    """A descendant in its own session survives killpg; draining is bounded anyway."""
    monkeypatch.setattr(proc_module, "DRAIN_SECONDS", 0.5)
    argv = _spawner(pidfile, new_session=True, leader_waits=True)
    started = time.monotonic()
    result = run_bounded(argv, tmp_path, timeout=TIMEOUT)
    elapsed = time.monotonic() - started
    assert result.timed_out is True
    # Without the drain bound this waits for the escaped sleep (120 s).
    assert elapsed < 60
    assert _alive(_descendant(pidfile))


def test_timeout_keeps_partial_output_as_text(tmp_path: Path):
    """TimeoutExpired.stdout is bytes even under text=True; it reached artifacts as b'...'."""
    code = f"import time; print('partial', flush=True); time.sleep({SLEEP})"
    result = run_bounded([sys.executable, "-c", code], tmp_path, timeout=TIMEOUT)
    assert result.timed_out is True
    assert result.stdout == "partial\n"


def test_invalid_utf8_output_is_replaced_not_raised(tmp_path: Path):
    code = "import sys; sys.stdout.buffer.write(b'\\xff ok'); sys.stderr.buffer.write(b'\\xfe')"
    result = run_bounded([sys.executable, "-c", code], tmp_path, timeout=10)
    assert result.timed_out is False
    assert result.returncode == 0
    assert result.stdout == "\ufffd ok"
    assert result.stderr == "\ufffd"
