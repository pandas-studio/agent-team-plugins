"""POSIX subprocess ownership, bounded cleanup and binary output capture."""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import threading
import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Cancellation:
    signal: int | None = None


@contextmanager
def signal_handlers(cancellation: Cancellation) -> Iterator[None]:
    """Install only at the CLI boundary; graph nodes may run in worker threads."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def cancel(signum, frame):
        if cancellation.signal is None:
            cancellation.signal = signum

    # SIGHUP too: a closed terminal would otherwise kill the CLI without cleanup,
    # and the role, in its own session, never sees the hangup. A signal already
    # ignored (nohup, a background job's SIGINT) stays ignored.
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(signum) is not signal.SIG_IGN:
            previous[signum] = signal.signal(signum, cancel)
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@dataclass(frozen=True)
class ProcessResult:
    returncode: int
    stdout: str
    stderr: str
    elapsed_ms: int
    timed_out: bool = False
    cancelled_signal: int | None = None
    cleanup_error: str = ""


def _signal_group(pgid: int, signum: int) -> bool:
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # macOS can report EPERM for a group containing only unreaped zombies.
        # Confirm that no live member remains, without hiding a real denial.
        try:
            listed = subprocess.run(
                ["ps", "-g", str(pgid), "-o", "pgid=,stat="], capture_output=True,
                text=True, check=False, timeout=1,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise PermissionError(f"cannot establish whether process group {pgid} exited") from None
        if listed.returncode in (0, 1) and not listed.stderr.strip():
            members = [line.split() for line in listed.stdout.splitlines() if line.strip()]
            if (all(len(member) == 2 and member[0].isdecimal() for member in members)
                    and all(group != str(pgid) or state.startswith("Z")
                            for group, state in members)):
                return False
        raise


def _cleanup(process: subprocess.Popen, grace: float) -> str:
    # The session/group ID is the child's PID, never the caller's group.
    def signal_group(signum: int) -> bool:
        try:
            return _signal_group(process.pid, signum)
        except PermissionError:
            # Exit state can change between poll(), killpg() and ps. Reap the
            # leader and confirm once more; persistent denials still propagate.
            process.poll()
            return _signal_group(process.pid, signum)

    errors = []
    try:
        if signal_group(signal.SIGTERM):
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                process.poll()
                if not signal_group(0):
                    break
                time.sleep(min(0.025, max(0, deadline - time.monotonic())))
            if signal_group(0):
                signal_group(signal.SIGKILL)
    except OSError as exc:
        errors.append(f"process group cleanup failed: {exc}")
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=max(grace, 0.1))
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f"child {process.pid} could not be reaped: {exc}")
    return "; ".join(errors)


def run_process(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout: float,
    cancellation: Cancellation | None = None,
    input_bytes: bytes | None = None,
    terminate_grace: float = 2.0,
) -> ProcessResult:
    """Capture to files: descendants retaining stdout cannot hold a pipe open."""
    cancellation = cancellation or Cancellation()
    started = time.monotonic()
    if cancellation.signal:
        return ProcessResult(128 + cancellation.signal, "", "execution cancelled", 0,
                             cancelled_signal=cancellation.signal)
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr, \
            tempfile.TemporaryFile() as stdin:
        if input_bytes is not None:
            stdin.write(input_bytes)
            stdin.seek(0)
        try:
            process = subprocess.Popen(
                list(argv), cwd=cwd, start_new_session=True,
                stdin=stdin if input_bytes is not None else subprocess.DEVNULL,
                stdout=stdout, stderr=stderr,
            )
        except OSError as exc:
            return ProcessResult(127, "", f"{type(exc).__name__}: {exc}",
                                 round((time.monotonic() - started) * 1000))
        timed_out = False
        try:
            deadline = started + timeout
            while process.poll() is None:
                if cancellation.signal:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    process.wait(timeout=min(0.05, remaining))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            cleanup_error = _cleanup(process, terminate_grace)
        stdout.seek(0)
        stderr.seek(0)
        output = stdout.read(os.fstat(stdout.fileno()).st_size).decode("utf-8", errors="replace")
        diagnostic = stderr.read(os.fstat(stderr.fileno()).st_size).decode("utf-8", errors="replace")
        returncode = process.returncode if process.returncode is not None else 125
        if cleanup_error and returncode == 0:
            returncode = 125
        if cancellation.signal:
            returncode = 128 + cancellation.signal
        elif timed_out:
            returncode = 124
        return ProcessResult(returncode, output, diagnostic,
                             round((time.monotonic() - started) * 1000), timed_out,
                             cancellation.signal, cleanup_error)
