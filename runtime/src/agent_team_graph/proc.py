"""Bounded child processes: a timeout ends the whole process group, output is text."""

from __future__ import annotations

import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

# After the group is killed, how long to keep draining the pipes. A descendant
# that moved to its own session survives the kill and may hold a pipe open.
DRAIN_SECONDS = 5


@dataclass(frozen=True)
class Bounded:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool


def _text(value: bytes | None) -> str:
    # errors="replace": a model or test command that prints invalid UTF-8 is
    # recorded, not a crash.
    return (value or b"").decode("utf-8", errors="replace")


def run_bounded(argv: list[str], cwd: Path | str, timeout: float) -> Bounded:
    """Run `argv` without a shell; on timeout kill its process group.

    `subprocess.run(timeout=...)` kills only the direct child, so a grandchild
    (a model CLI's tool call, a test runner's worker) keeps running. The child
    leads a new session here, and the timeout signals the whole group.
    """

    process = subprocess.Popen(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        try:
            stdout, stderr = process.communicate(timeout=DRAIN_SECONDS)
        except subprocess.TimeoutExpired as exc:
            # The exception carries everything read so far.
            stdout, stderr = exc.stdout, exc.stderr
            _close_and_reap(process)
        return Bounded(process.returncode, _text(stdout), _text(stderr), True)
    except BaseException:
        # The new session also keeps a terminal's Ctrl-C from reaching the child,
        # so an interrupted caller must end the group itself: otherwise the child
        # keeps writing the workspace after the thread lock is released.
        _kill_group(process)
        _close_and_reap(process)
        raise
    return Bounded(process.returncode, _text(stdout), _text(stderr), False)


def _kill_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _close_and_reap(process: subprocess.Popen) -> None:
    for stream in (process.stdout, process.stderr):
        if stream:
            stream.close()
    process.wait()
