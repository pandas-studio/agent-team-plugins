#!/usr/bin/env python3
"""Real spec driver and dev-trio wrappers; replace only external model CLIs."""

import hashlib
import io
import json
import math
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack, contextmanager
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "spec-trio/bin/spec-trio.sh"


# Test harness budgets only; never change the driver's --max-runtime clock.
TIMEOUT_SCALE_ENV = "SPEC_TRIO_TEST_TIMEOUT_SCALE"
TIMEOUTS = {"execution": 120, "ready": 60, "interrupt": 30, "cleanup": 10}


def timeout_scale():
    raw = os.environ.get(TIMEOUT_SCALE_ENV, "1")
    scale = (
        float(raw)
        if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", raw)
        else 0
    )
    if scale < 0.1 or not math.isfinite(scale * max(TIMEOUTS.values())):
        raise ValueError(
            f"{TIMEOUT_SCALE_ENV} must be a decimal number >= 0.1 "
            f"with finite timeouts (no whitespace or underscores); got {raw!r}"
        )
    return scale


# Validate on import as well as direct execution, before unittest can run any
# fixtures. check.sh uses --check-config before its other checks.
try:
    CONFIGURED_SCALE = timeout_scale()
except ValueError as exc:
    raise SystemExit(str(exc)) from None


# Keep the session leader alive after the driver exits. Its unreaped PID pins
# the process-group identity until cleanup signals it, even for orphaned output
# writers. Only the supervisor is reaped; poll/wait below read the result pipe.
SUPERVISOR = r"""
import os, select, signal, subprocess, sys, traceback
signal.signal(signal.SIGINT, lambda *_: None)
signal.signal(signal.SIGTERM, lambda *_: None)
owner_fd = int(sys.argv[2])
def watch_owner(timeout):
    if select.select([owner_fd], [], [], timeout)[0] and not os.read(owner_fd, 1):
        # The runner closed its sole writer (including on SIGKILL). Signal our
        # current group from inside it; no external/recycled identifier is used.
        os.kill(0, signal.SIGKILL)
watch_owner(0)
try:
    child = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL)
    while child.poll() is None:
        watch_owner(0.1)
    status = f"exit:{child.returncode}\n".encode()
except BaseException:
    traceback.print_exc()
    status = b"error\n"
try:
    os.write(int(sys.argv[1]), status)
except BrokenPipeError:
    os.kill(0, signal.SIGKILL)
os.close(int(sys.argv[1]))
while True:
    watch_owner(None)
"""


class OwnedProcess:
    """Observe driver completion without reaping the process-group leader."""

    def __init__(self, args, *, cwd, env, stdout, stderr):
        self.args = args
        self.returncode = None
        self.status_fd, writer = os.pipe()
        owner_reader = self.owner_writer = None
        self.status = b""
        self.status_error = None
        self.reaped = False
        try:
            owner_reader, self.owner_writer = os.pipe()
            self.owner = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    SUPERVISOR,
                    str(writer),
                    str(owner_reader),
                    *args,
                ],
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                pass_fds=(writer, owner_reader),
                start_new_session=True,
            )
        except BaseException:
            try:
                self.close()
            except OSError:
                pass  # Preserve the process-creation failure.
            raise
        finally:
            os.close(writer)
            if owner_reader is not None:
                os.close(owner_reader)

    def poll(self, timeout=0):
        """Observe a result, blocking at most one second per call."""
        if self.status_error is not None:
            raise RuntimeError(self.status_error)
        if self.returncode is None:
            if self.status_fd is None:
                raise RuntimeError("process control pipe already closed")
            # Keep very large valid scales within the OS timeout range.
            readable, _, _ = select.select([self.status_fd], [], [], min(timeout, 1))
            if readable:
                chunk = os.read(self.status_fd, 64)
                self.status += chunk
                if not chunk:
                    self.status_error = (
                        "supervisor exited without a complete driver result"
                    )
                elif self.status == b"error\n":
                    self.status_error = (
                        "supervisor internal failure (see captured stderr)"
                    )
                elif len(self.status) >= 64 or b"\n" in self.status:
                    match = re.fullmatch(rb"exit:(-?[0-9]+)\n", self.status)
                    if len(self.status) < 64 and match:
                        self.returncode = int(match[1])
                    else:
                        self.status_error = "invalid supervisor status message"
                if self.status_error is not None:
                    raise RuntimeError(self.status_error)
        return self.returncode

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while self.poll(max(0, deadline - time.monotonic())) is None:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(self.args, timeout)
        return self.returncode

    def signal_group(self, sig):
        # Never signal an identity after releasing it for PID reuse.
        if not self.reaped:
            os.killpg(self.owner.pid, sig)

    def reap(self, timeout):
        code = self.owner.wait(timeout=timeout)
        self.reaped = True
        # A status failure has no driver result; do not substitute the
        # supervisor's cleanup signal. Retain the fallback for timeouts.
        if self.returncode is None and self.status_error is None:
            self.returncode = code

    def close(self):
        errors = []
        for name in ("owner_writer", "status_fd"):
            fd = getattr(self, name)
            if fd is None:
                continue
            # A failed close may already have released the descriptor. Never
            # retry its number after another thread could have reused it.
            setattr(self, name, None)
            try:
                os.close(fd)
            except OSError as exc:
                errors.append(f"{name}: {exc}")
        if errors:
            raise OSError("; ".join(errors))


class DriverProcess:
    def __init__(self, proc, stdout, stderr, scale, test_id):
        self.proc = proc
        self.stdout = stdout
        self.stderr = stderr
        self.limits = {phase: seconds * scale for phase, seconds in TIMEOUTS.items()}
        self.test_id = test_id
        self.cleaned = False
        self.cleanup_error = ""

    def result(self, max_bytes=None):
        def snapshot(stream):
            # Fixed-size positional reads cannot disturb a surviving writer.
            fd = stream.fileno()
            size = os.fstat(fd).st_size
            if max_bytes is not None and size > max_bytes:
                half = max_bytes // 2
                data = (
                    os.pread(fd, half, 0)
                    + f"\n... {size - 2 * half} bytes omitted ...\n".encode()
                    + os.pread(fd, half, size - half)
                )
            else:
                data = os.pread(fd, size, 0)
            return data.decode("utf-8", errors="replace")

        return subprocess.CompletedProcess(
            self.proc.args,
            self.proc.returncode,
            snapshot(self.stdout),
            snapshot(self.stderr),
        )

    def cleanup(self):
        if self.cleaned:
            return self.cleanup_error
        self.cleaned = True
        errors = []
        try:
            self.proc.signal_group(signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            errors.append(f"process group cleanup failed: {exc}")
        collected = False
        try:
            self.proc.reap(timeout=self.limits["cleanup"])
            collected = True
        except subprocess.TimeoutExpired:
            errors.append(f"process reap exceeded {self.limits['cleanup']:g}s")
        except OSError as exc:
            errors.append(f"process reap failed: {exc}")
        try:
            self.proc.close()
        except OSError as exc:
            errors.append(f"descriptor cleanup failed: {exc}")
        if not collected:
            # Owner EOF lets the supervisor kill its own group. Collect it
            # explicitly, without another signal or reliance on Popen.__del__.
            try:
                self.proc.reap(timeout=self.limits["cleanup"])
            except subprocess.TimeoutExpired:
                errors.append(
                    f"final process reap exceeded {self.limits['cleanup']:g}s"
                )
            except OSError as exc:
                errors.append(f"final process reap failed: {exc}")
        self.cleanup_error = "; ".join(errors)
        return self.cleanup_error

    def failure(self, phase, reason, limit=None):
        cleanup_error = self.cleanup()
        result = self.result(max_bytes=8192)
        budget = self.limits[phase] if limit is None else limit
        return AssertionError(
            f"{self.test_id}: {phase}: {reason} "
            f"(limit={budget:g}s, returncode={result.returncode})\n"
            f"command: {shlex.join(self.proc.args)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}\n"
            f"{cleanup_error}"
        )

    def wait(self, phase="execution", *, limit=None):
        budget = self.limits[phase] if limit is None else limit
        try:
            self.proc.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            raise self.failure(phase, "timed out", budget) from None
        except RuntimeError as exc:
            raise self.failure(phase, str(exc), budget) from None
        if self.cleanup():
            raise self.failure("cleanup", "could not finish process cleanup")
        return self.result()

    def wait_ready(self, path):
        deadline = time.monotonic() + self.limits["ready"]
        while True:
            if path.exists():
                return
            try:
                exited = self.proc.poll() is not None
            except RuntimeError as exc:
                raise self.failure("ready", str(exc)) from None
            if exited:
                # The marker may have appeared between the first check and exit.
                if path.exists():
                    return
                raise self.failure("ready", "driver exited before readiness")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise self.failure("ready", "timed out waiting for readiness")
            time.sleep(min(0.05, remaining))


@contextmanager
def driver_process(args, *, cwd, env, scale, test_id):
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        proc = OwnedProcess(args, cwd=cwd, env=env, stdout=stdout, stderr=stderr)
        driver = DriverProcess(proc, stdout, stderr, scale, test_id)
        try:
            yield driver
        except BaseException:
            try:
                cleanup_error = driver.cleanup()
            except BaseException as exc:  # noqa: BLE001 - preserve the body exception
                cleanup_error = f"{type(exc).__name__}: {exc}"
            if cleanup_error:
                print(
                    f"{test_id}: cleanup also failed: {cleanup_error}",
                    file=sys.stderr,
                )
            raise
        else:
            if driver.cleanup():
                raise driver.failure("cleanup", "could not finish process cleanup")
        finally:
            # Even KeyboardInterrupt during cleanup must release the sole
            # ownership writer. close() is idempotent, including after errors.
            try:
                proc.close()
            except OSError:
                pass  # Never replace an exception already escaping cleanup.


STUB = r"""#!/usr/bin/env python3
import os, sys, signal, subprocess
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ['FIXTURE_STATE'])
role = 'reviewer' if '--output-last-message' in args else 'planner' if '# Role: Spec-driven Planner' in args[-1] else 'researcher' if Path(sys.argv[0]).name == 'researcher' else 'coder'
counter = state / (role + '.count')
n = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(n))
(state / (role + str(n) + '.prompt')).write_text(args[-1])
mutate = os.environ.get('MUTATE')
if mutate == role:
    Path(os.environ['FIXTURE_SPEC']).write_text('changed contract')
if mutate == role + '-snapshot':
    target = next(state.glob('logs/log/verify/contract-*/spec.md'))
    target.chmod(0o644)
    target.write_text('changed snapshot')
if mutate == role + '-delete':
    Path(os.environ['FIXTURE_SPEC']).unlink()
if mutate == role + '-worktree':
    Path('spec.md').write_text('changed worktree contract')
if mutate == role + '-backlog':
    Path('BACKLOG.md').write_text('- [x] falsely completed\n')
if role == 'planner':
    if os.environ.get('PLANNER_FAIL'):
        sys.exit(7)
    paths = 'file.txt,retained.txt' if os.environ.get('COMMIT_RETRY') and not (os.environ.get('NARROW_RETRY') and n > 1) else 'file.txt'
    print('<allowed-paths>' + paths + '</allowed-paths>')
    if os.environ.get('PLAN_RESEARCH'):
        print('## NEED RESEARCH\n- lookup')
elif role == 'coder':
    if os.environ.get('INTERRUPT'):
        (state / 'ready').touch()
        while True:
            signal.pause()
    Path('file.txt').write_text('good\n' if not os.environ.get('RETRY_TEST') or n > 1 else 'bad\n')
    if os.environ.get('COMMIT_RETRY') and n == 1:
        Path('retained.txt').write_text('first implementation remains\n')
        subprocess.run(['git', 'add', 'file.txt', 'retained.txt'], check=True)
        subprocess.run(['git', 'commit', '-qm', 'failed attempt implementation'], check=True)
        (state / 'failed.sha').write_text(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip())
    if os.environ.get('STRAY'):
        Path('other.txt').write_text('outside scope')
    if os.environ.get('PROMISE'):
        Path(os.environ['FIXTURE_FIX']).write_text('<promise>COMPLETE</promise>\n')
    if os.environ.get('CODER_FAIL') == str(n):
        sys.exit(13)
    print('fixture implementation checked; may already satisfy task')
elif role == 'researcher':
    print('fixture evidence')
else:
    final = Path(args[args.index('--output-last-message') + 1])
    verdict = os.environ.get('VERDICT', 'SHIP')
    if os.environ.get('RESEARCH_RETRY') and n == 1:
        verdict = 'NEEDS-FIX'
    body = 'invalid review' if verdict == 'UNKNOWN' else '## Verdict\n' + verdict + ' — fixture verdict\n'
    if os.environ.get('RESEARCH_RETRY') and n == 1:
        body += '## NEED RESEARCH\n- lookup\n'
    final.write_text(body)
    print(body)
"""


class DriverProcessTests(unittest.TestCase):
    def test_driver_exit_codes_are_not_supervisor_errors(self):
        for code in (0, 7, 125):
            with (
                self.subTest(code=code),
                driver_process(
                    [sys.executable, "-c", f"raise SystemExit({code})"],
                    cwd=ROOT,
                    env=os.environ.copy(),
                    scale=CONFIGURED_SCALE,
                    test_id=self.id(),
                ) as driver,
            ):
                result = driver.wait()
                self.assertEqual(result.returncode, code)
                self.assertEqual(result.stderr, "")
                self.assertTrue(driver.proc.reaped)

    def test_supervisor_failure_preserves_traceback_and_cleans_up(self):
        for phase in ("execution", "ready"):
            with (
                self.subTest(phase=phase),
                tempfile.TemporaryDirectory(prefix="spec supervisor failure ") as tmp,
                driver_process(
                    [str(Path(tmp) / "missing-command")],
                    cwd=ROOT,
                    env=os.environ.copy(),
                    scale=CONFIGURED_SCALE,
                    test_id=self.id(),
                ) as driver,
            ):
                with self.assertRaises(AssertionError) as caught:
                    if phase == "ready":
                        driver.wait_ready(Path(tmp) / "ready")
                    else:
                        driver.wait()
                message = str(caught.exception)
                for fragment in (
                    f"{phase}: supervisor internal failure",
                    "Traceback (most recent call last)",
                    "FileNotFoundError",
                    "missing-command",
                ):
                    self.assertIn(fragment, message)
                self.assertIn("returncode=None", message)
                self.assertNotIn("returncode=-9", message)
                self.assertIsNone(driver.result().returncode)
                self.assertTrue(driver.proc.reaped)
                self.assertEqual(driver.proc.owner.returncode, -signal.SIGKILL)

    def fake_status_process(self):
        # Keep these fields in sync with the state read by OwnedProcess.poll().
        proc = OwnedProcess.__new__(OwnedProcess)
        proc.returncode = None
        proc.status = b""
        proc.status_error = None
        proc.status_fd = 123  # All reads/selects are mocked; no real descriptor.
        return proc

    def test_status_pipe_accumulates_partial_exit_messages(self):
        for code in (0, 7, 125, -signal.SIGTERM):
            proc = self.fake_status_process()
            chunks = [b"ex", b"it:", str(code).encode(), b"\n"]
            with (
                self.subTest(code=code),
                mock.patch.object(select, "select", return_value=([123], [], [])),
                mock.patch.object(os, "read", side_effect=chunks) as read,
            ):
                for _ in chunks[:-1]:
                    self.assertIsNone(proc.poll())
                self.assertEqual(proc.poll(), code)
                self.assertEqual(proc.poll(), code)
                self.assertEqual(read.call_count, len(chunks))

    def test_status_pipe_reports_internal_errors_and_invalid_messages(self):
        cases = (
            ([b"err", b"or\n"], "supervisor internal failure"),
            ([b""], "without a complete driver result"),
            ([b"exit:12", b""], "without a complete driver result"),
            ([b"125\n"], "invalid supervisor status"),
            ([b"exit:abc\n"], "invalid supervisor status"),
            ([b"exit:7\nextra"], "invalid supervisor status"),
            ([b"x" * 64], "invalid supervisor status"),
        )
        for chunks, message in cases:
            proc = self.fake_status_process()
            with (
                self.subTest(chunks=chunks),
                mock.patch.object(select, "select", return_value=([123], [], [])),
                mock.patch.object(os, "read", side_effect=chunks) as read,
            ):
                for _ in chunks[:-1]:
                    self.assertIsNone(proc.poll())
                for _ in range(2):
                    with self.assertRaisesRegex(RuntimeError, message):
                        proc.poll()
                self.assertIsNone(proc.returncode)
                self.assertEqual(read.call_count, len(chunks))

    def test_timeout_scale_default_and_overrides(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(timeout_scale(), 1)
            for value, expected in (
                ("2", 2),
                ("0.5", 0.5),
                ("0.1", 0.1),
                ("1e1", 10),
                ("1e+1", 10),
                ("1e-1", 0.1),
                ("01.0E+1", 10),
            ):
                os.environ[TIMEOUT_SCALE_ENV] = value
                self.assertEqual(timeout_scale(), expected)

    def test_invalid_timeout_scales(self):
        for value in (
            "0",
            "-1",
            "",
            "invalid",
            "nan",
            "inf",
            "-inf",
            "1e308",
            "2_0",
            " 2 ",
            "1e-300",
            "0.099",
            "2\n",
            "+1",
            ".5",
            "1.",
            "１",
            "١",
        ):
            with (
                self.subTest(value=value),
                mock.patch.dict(os.environ, {TIMEOUT_SCALE_ENV: value}),
                self.assertRaisesRegex(ValueError, TIMEOUT_SCALE_ENV),
            ):
                timeout_scale()

    def fake_driver(self, scale=1):
        proc = mock.Mock(
            spec=OwnedProcess, args=["fixture", "argument with spaces"], returncode=7
        )
        proc.poll.return_value = None
        streams = []
        with ExitStack() as stack:
            for content in ("partial output ✓".encode(), b"partial error"):
                stream = stack.enter_context(tempfile.TemporaryFile())
                stream.write(content)
                stream.flush()
                streams.append(stream)
            self.addCleanup(stack.pop_all().close)
        return DriverProcess(proc, *streams, scale, self.id())

    def test_fake_driver_cannot_signal_real_processes(self):
        with mock.patch.object(os, "killpg", side_effect=AssertionError("real signal")):
            driver = self.fake_driver()
            self.assertEqual(driver.cleanup(), "")
            driver.proc.signal_group.assert_called_once_with(signal.SIGKILL)

    def test_ready_marker_wins_over_exit(self):
        for observations in ([True], [False, True]):
            with self.subTest(observations=observations):
                driver = self.fake_driver()
                driver.proc.poll.return_value = 0
                ready = mock.Mock()
                ready.exists.side_effect = observations
                driver.wait_ready(ready)
                driver.proc.signal_group.assert_not_called()

    def test_successful_wait_reports_cleanup_permission_error(self):
        driver = self.fake_driver()
        driver.proc.signal_group.side_effect = PermissionError("denied")
        with self.assertRaisesRegex(
            AssertionError, "cleanup:.*could not finish"
        ) as caught:
            driver.wait()
        self.assertIn("process group cleanup failed: denied", str(caught.exception))
        self.assertIn("partial output", str(caught.exception))
        driver.proc.reap.assert_called_once_with(timeout=10)

    def test_cleanup_errors_have_separator(self):
        driver = self.fake_driver()
        driver.proc.signal_group.side_effect = PermissionError("denied")
        driver.proc.reap.side_effect = subprocess.TimeoutExpired(driver.proc.args, 10)
        self.assertEqual(
            driver.cleanup(),
            "process group cleanup failed: denied; process reap exceeded 10s; "
            "final process reap exceeded 10s",
        )

    def test_context_exit_reports_cleanup_failure_and_closes_status(self):
        driver = self.fake_driver()
        driver.proc.signal_group.side_effect = PermissionError("denied")
        with (
            mock.patch(__name__ + ".OwnedProcess", return_value=driver.proc),
            self.assertRaisesRegex(
                AssertionError, "process group cleanup failed: denied"
            ),
            driver_process(["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()),
        ):
            pass
        self.assertEqual(driver.proc.close.call_count, 2)

    def test_context_cleanup_does_not_mask_body_failure(self):
        driver = self.fake_driver()
        driver.proc.signal_group.side_effect = PermissionError("denied")
        with (
            mock.patch(__name__ + ".OwnedProcess", return_value=driver.proc),
            self.assertRaisesRegex(ValueError, "original failure"),
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            driver_process(["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()),
        ):
            raise ValueError("original failure")
        self.assertEqual(driver.proc.close.call_count, 2)
        self.assertIn(
            "cleanup also failed: process group cleanup failed: denied",
            stderr.getvalue(),
        )

    def test_cleanup_failure_inside_existing_exception_is_not_swallowed(self):
        driver = self.fake_driver()
        driver.proc.signal_group.side_effect = PermissionError("denied")
        try:
            raise LookupError("outer exception")
        except LookupError:
            with (
                mock.patch(__name__ + ".OwnedProcess", return_value=driver.proc),
                self.assertRaisesRegex(AssertionError, "cleanup:.*could not finish"),
                driver_process(
                    ["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()
                ),
            ):
                pass

    def test_descriptor_close_failures_attempt_both_without_retrying(self):
        for failures in ((True, False), (False, True), (True, True)):
            with self.subTest(failures=failures):
                proc = OwnedProcess.__new__(OwnedProcess)
                proc.owner_writer, proc.status_fd = 101, 102
                failed_fds = {fd for fd, fail in zip((101, 102), failures) if fail}
                real_close = os.close

                def close_fd(fd, failed_fds=failed_fds, real_close=real_close):
                    if fd in failed_fds:
                        raise OSError("injected close failure")
                    if fd not in (101, 102):
                        return real_close(fd)
                    return None

                with mock.patch.object(os, "close", side_effect=close_fd) as close:
                    with self.assertRaises(OSError) as caught:
                        proc.close()
                    proc.close()
                self.assertEqual(close.call_args_list, [mock.call(101), mock.call(102)])
                self.assertIsNone(proc.owner_writer)
                self.assertIsNone(proc.status_fd)
                for name, failed in zip(("owner_writer", "status_fd"), failures):
                    self.assertEqual(name in str(caught.exception), failed)

    def test_closed_control_pipe_reports_runtime_error_unless_result_known(self):
        proc = self.fake_status_process()
        proc.status_fd = None
        with self.assertRaisesRegex(RuntimeError, "control pipe already closed"):
            proc.poll()
        proc.returncode = -signal.SIGTERM
        self.assertEqual(proc.poll(), -signal.SIGTERM)

    def test_process_creation_failure_closes_owned_descriptors(self):
        proc = OwnedProcess.__new__(OwnedProcess)
        original = RuntimeError("process creation failed")

        def close_fd(fd):
            if fd == 104:
                raise OSError("owner close failed")

        with (
            mock.patch.object(os, "pipe", side_effect=[(101, 102), (103, 104)]),
            mock.patch.object(os, "close", side_effect=close_fd) as close,
            mock.patch.object(subprocess, "Popen", side_effect=original),
            self.assertRaises(RuntimeError) as caught,
        ):
            proc.__init__(["fixture"], cwd=ROOT, env={}, stdout=None, stderr=None)
        self.assertIs(caught.exception, original)
        self.assertIsNone(proc.owner_writer)
        self.assertIsNone(proc.status_fd)
        self.assertEqual(
            close.call_args_list, [mock.call(fd) for fd in (104, 101, 102, 103)]
        )

    def test_interrupted_cleanup_closes_descriptors_and_preserves_exception(self):
        for phase in ("signal_group", "reap"):
            for body_fails in (False, True):
                with self.subTest(phase=phase, body_fails=body_fails):
                    driver = self.fake_driver()
                    interruption = KeyboardInterrupt("cleanup interrupted")
                    getattr(driver.proc, phase).side_effect = interruption
                    driver.proc.close.side_effect = OSError("close failed too")
                    original = (
                        ValueError("original test failure")
                        if body_fails
                        else interruption
                    )
                    with (
                        mock.patch(
                            __name__ + ".OwnedProcess", return_value=driver.proc
                        ),
                        mock.patch("sys.stderr", new_callable=io.StringIO),
                        self.assertRaises(type(original)) as caught,
                        driver_process(
                            ["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()
                        ),
                    ):
                        if body_fails:
                            raise original
                    self.assertIs(caught.exception, original)
                    driver.proc.close.assert_called_once()

    def test_interrupted_reap_still_delivers_owner_eof(self):
        proc = None
        try:
            with ExitStack() as patches:
                interruption = KeyboardInterrupt("reap interrupted")
                with (
                    self.assertRaises(KeyboardInterrupt) as caught,
                    driver_process(
                        [sys.executable, "-c", "raise SystemExit(7)"],
                        cwd=ROOT,
                        env=os.environ.copy(),
                        scale=CONFIGURED_SCALE,
                        test_id=self.id(),
                    ) as driver,
                ):
                    proc = driver.proc
                    self.assertEqual(
                        proc.wait(timeout=TIMEOUTS["execution"] * CONFIGURED_SCALE), 7
                    )
                    patches.enter_context(mock.patch.object(proc, "signal_group"))
                    patches.enter_context(
                        mock.patch.object(proc, "reap", side_effect=interruption)
                    )
                self.assertIs(caught.exception, interruption)
                self.assertIsNone(proc.owner_writer)
                self.assertIsNone(proc.status_fd)
                # The context's owner EOF is the only termination mechanism;
                # this explicit wait collects the interrupted test's fixture.
                OwnedProcess.reap(proc, timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE)
                self.assertEqual(proc.owner.returncode, -signal.SIGKILL)
        finally:
            if proc is not None and not proc.reaped:
                try:
                    proc.close()
                finally:
                    try:
                        OwnedProcess.reap(
                            proc, timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE
                        )
                    except subprocess.TimeoutExpired:
                        pass

    def test_combined_cleanup_errors_preserve_original_exception(self):
        for reap_error in (
            subprocess.TimeoutExpired(["fixture"], 10),
            OSError("injected reap failure"),
        ):
            with self.subTest(reap_error=reap_error):
                driver = self.fake_driver()
                driver.proc.signal_group.side_effect = PermissionError("denied")
                driver.proc.reap.side_effect = reap_error
                driver.proc.close.side_effect = OSError("injected close failure")
                original = ValueError("original failure")
                with (
                    mock.patch(__name__ + ".OwnedProcess", return_value=driver.proc),
                    mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                    self.assertRaises(ValueError) as caught,
                    driver_process(
                        ["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()
                    ) as context_driver,
                ):
                    raise original
                self.assertIs(caught.exception, original)
                self.assertIn("process group cleanup failed: denied", stderr.getvalue())
                self.assertIn("descriptor cleanup failed", stderr.getvalue())
                self.assertIn("final process reap", stderr.getvalue())
                context_driver.cleanup()
                self.assertEqual(
                    driver.proc.method_calls,
                    [
                        mock.call.signal_group(signal.SIGKILL),
                        mock.call.reap(timeout=10),
                        mock.call.close(),
                        mock.call.reap(timeout=10),
                        mock.call.close(),
                    ],
                )

    def test_close_failure_fails_successful_context(self):
        driver = self.fake_driver()
        driver.proc.close.side_effect = OSError("injected close failure")
        with (
            mock.patch(__name__ + ".OwnedProcess", return_value=driver.proc),
            self.assertRaisesRegex(AssertionError, "descriptor cleanup failed"),
            driver_process(["fixture"], cwd=ROOT, env={}, scale=1, test_id=self.id()),
        ):
            pass
        driver.proc.reap.assert_called_once_with(timeout=10)
        self.assertEqual(driver.proc.close.call_count, 2)

    def test_reap_timeout_then_owner_eof_collects_supervisor(self):
        for body_fails in (False, True):
            with self.subTest(body_fails=body_fails), ExitStack() as patches:
                proc = None
                original = ValueError("original failure")
                patches.enter_context(
                    mock.patch("sys.stderr", new_callable=io.StringIO)
                )
                try:
                    with (
                        self.assertRaises(
                            ValueError if body_fails else AssertionError
                        ) as caught,
                        driver_process(
                            [sys.executable, "-c", "raise SystemExit(7)"],
                            cwd=ROOT,
                            env=os.environ.copy(),
                            scale=CONFIGURED_SCALE,
                            test_id=self.id(),
                        ) as driver,
                    ):
                        proc = driver.proc
                        self.assertEqual(
                            proc.wait(timeout=TIMEOUTS["execution"] * CONFIGURED_SCALE),
                            7,
                        )
                        real_reap = proc.reap
                        attempts = []

                        def reap(
                            *,
                            timeout,
                            proc=proc,
                            attempts=attempts,
                            real_reap=real_reap,
                        ):
                            attempts.append(timeout)
                            if len(attempts) == 1:
                                raise subprocess.TimeoutExpired(proc.args, timeout)
                            self.assertIsNone(proc.owner_writer)
                            self.assertIsNone(proc.status_fd)
                            return real_reap(timeout)

                        # Suppress the first group signal so only owner EOF
                        # can stop the supervisor; inject timeout without sleeping.
                        signal_group = patches.enter_context(
                            mock.patch.object(proc, "signal_group")
                        )
                        patches.enter_context(
                            mock.patch.object(proc, "reap", side_effect=reap)
                        )
                        if body_fails:
                            raise original
                    if body_fails:
                        self.assertIs(caught.exception, original)
                    else:
                        self.assertIn("process reap exceeded", str(caught.exception))
                    self.assertTrue(proc.reaped)
                    self.assertEqual(proc.owner.returncode, -signal.SIGKILL)
                    self.assertEqual(proc.returncode, 7)
                    # Unlike a stopped/zombie check, this proves wait collected
                    # the child before context exit, with Popen still referenced.
                    with self.assertRaises(ChildProcessError):
                        os.waitpid(proc.owner.pid, os.WNOHANG)
                    driver.cleanup()
                    self.assertEqual(attempts, [10 * CONFIGURED_SCALE] * 2)
                    signal_group.assert_called_once_with(signal.SIGKILL)
                finally:
                    if proc is not None and not proc.reaped:
                        try:
                            proc.close()
                        finally:
                            try:
                                OwnedProcess.reap(
                                    proc, timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE
                                )
                            except subprocess.TimeoutExpired:
                                pass  # Keep the failed regression's assertion.

    def test_parent_death_terminates_supervisor_and_driver_tree(self):
        for finished in (False, True):
            with (
                self.subTest(finished=finished),
                tempfile.TemporaryDirectory(prefix="spec parent death ") as tmp,
                tempfile.TemporaryFile() as errors,
            ):
                root = Path(tmp)
                state, ready, stop = (
                    root / name for name in ("state", "ready", "stop")
                )
                # A descendant provides independent emergency cleanup: it signals
                # its OWN current group, never a recorded/recycled external PID.
                watcher = (
                    "import os, signal, time\nfrom pathlib import Path\n"
                    f"while not Path({str(stop)!r}).exists(): time.sleep(0.01)\n"
                    "os.kill(0, signal.SIGKILL)\n"
                )
                child = (
                    "import os, json, signal, subprocess, sys\nfrom pathlib import Path\n"
                    f"watcher = subprocess.Popen([sys.executable, '-c', {watcher!r}])\n"
                    f"path = Path({str(ready)!r})\n"
                    "path.with_suffix('.tmp').write_text(json.dumps([os.getpid(), watcher.pid]))\n"
                    "path.with_suffix('.tmp').replace(path)\n"
                    + ("sys.exit(7)\n" if finished else "while True: signal.pause()\n")
                )
                parent = (
                    "import os, sys, signal, json\nfrom pathlib import Path\n"
                    f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
                    "import test_verification as t\n"
                    f"with t.driver_process([sys.executable, '-c', {child!r}], "
                    f"cwd={str(root)!r}, env=os.environ.copy(), scale=t.CONFIGURED_SCALE, "
                    "test_id='parent death fixture') as driver:\n"
                    + (
                        "    driver.proc.wait(timeout=t.TIMEOUTS['execution'] * t.CONFIGURED_SCALE)\n"
                        if finished
                        else f"    driver.wait_ready(Path({str(ready)!r}))\n"
                    )
                    + f"    pids = [driver.proc.owner.pid] + json.loads(Path({str(ready)!r}).read_text())\n"
                    + f"    state = Path({str(state)!r})\n"
                    + "    state.with_suffix('.tmp').write_text(json.dumps(pids))\n"
                    + "    state.with_suffix('.tmp').replace(state)\n"
                    + "    while True: signal.pause()\n"
                )
                proc = subprocess.Popen(
                    [sys.executable, "-c", parent],
                    cwd=ROOT,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=errors,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + TIMEOUTS["ready"] * CONFIGURED_SCALE
                    while (
                        not state.exists()
                        and proc.poll() is None
                        and time.monotonic() < deadline
                    ):
                        time.sleep(0.05)
                    if not state.exists():
                        details = os.pread(errors.fileno(), 8192, 0).decode(
                            "utf-8", errors="replace"
                        )
                        self.fail(
                            f"parent-death fixture did not become ready\n{details}"
                        )
                    pids = json.loads(state.read_text())
                    proc.kill()
                    proc.wait(timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE)
                    for pid in pids:
                        self.assert_process_stopped(pid)
                finally:
                    stop.touch()
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE)
                    if state.exists():
                        for pid in json.loads(state.read_text()):
                            self.assert_process_stopped(pid)

    def test_failure_output_is_bounded_with_head_and_tail(self):
        driver = self.fake_driver()
        for stream in (driver.stdout, driver.stderr):
            stream.seek(0)
            stream.truncate()
            stream.write(b"HEAD" + b"x" * 200000 + b"TAIL")
            stream.flush()
        message = str(driver.failure("execution", "timed out"))
        self.assertLess(len(message), 18000)
        self.assertEqual(message.count("HEAD"), 2)
        self.assertEqual(message.count("TAIL"), 2)
        self.assertEqual(message.count("191816 bytes omitted"), 2)
        self.assertEqual(len(driver.result().stdout), 200008)

    def test_preflight_rejects_invalid_config_for_all_entrypoints(self):
        commands = (
            [sys.executable, str(Path(__file__).resolve()), "--check-config"],
            [sys.executable, "-m", "unittest", "spec-trio.tests.test_verification"],
            [sys.executable, "-m", "unittest", "discover", "-s", "spec-trio/tests"],
            ["bash", str(ROOT / "scripts/check.sh")],
        )
        with tempfile.TemporaryDirectory(prefix="spec preflight ") as tmp:
            # The marker detects whether check.sh reached the source scan.
            # exit 99 inside process substitution does not abort check.sh under
            # set -e; marker absence, not the stub exit code, is the assertion.
            marker = Path(tmp) / "scan-started"
            find = Path(tmp) / "find"
            find.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 99\n")
            find.chmod(0o755)
            env = os.environ | {
                TIMEOUT_SCALE_ENV: "2_0",
                "PATH": tmp + ":" + os.environ["PATH"],
            }
            for command in commands:
                with self.subTest(command=command):
                    result = subprocess.run(
                        command,
                        cwd=ROOT,
                        env=env,
                        text=True,
                        capture_output=True,
                        timeout=TIMEOUTS["execution"] * CONFIGURED_SCALE,
                        check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(TIMEOUT_SCALE_ENV, result.stderr)
                    self.assertNotIn("setUpClass", result.stderr)
                    if "discover" in command:
                        # unittest discovery wraps import failures in one
                        # _FailedTest; no verification fixture was constructed.
                        self.assertIn("unittest.loader._FailedTest", result.stderr)
                    else:
                        self.assertNotIn("Ran ", result.stderr)
                    self.assertFalse(marker.exists())

    def test_supervisor_retains_group_identity_until_cleanup(self):
        with driver_process(
            [sys.executable, "-c", "raise SystemExit(7)"],
            cwd=ROOT,
            env=os.environ.copy(),
            scale=CONFIGURED_SCALE,
            test_id=self.id(),
        ) as driver:
            self.assertEqual(
                driver.proc.wait(timeout=TIMEOUTS["execution"] * CONFIGURED_SCALE), 7
            )
            # The actual driver exited, but the supervisor is still a live
            # session leader; no reaped identifier is signalled later.
            self.assertEqual(os.getpgid(driver.proc.owner.pid), driver.proc.owner.pid)
            status = self.process_status(driver.proc.owner.pid)
            self.assertTrue(status)
            self.assertFalse(status.startswith("Z"), status)
            self.assertEqual(driver.wait().returncode, 7)
            with mock.patch.object(os, "killpg") as kill:
                driver.proc.signal_group(signal.SIGKILL)
                kill.assert_not_called()

    def test_child_stdin_is_eof_and_signal_returncode_is_preserved(self):
        script = (
            "import os, signal, sys; "
            "print('stdin=' + repr(sys.stdin.read()), flush=True); "
            "os.kill(os.getpid(), signal.SIGTERM)"
        )
        with driver_process(
            [sys.executable, "-c", script],
            cwd=ROOT,
            env=os.environ.copy(),
            scale=CONFIGURED_SCALE,
            test_id=self.id(),
        ) as driver:
            result = driver.wait()
        self.assertEqual(result.returncode, -signal.SIGTERM)
        self.assertEqual(result.stdout, "stdin=''\n")

    def test_output_snapshot_preserves_writer_offset(self):
        driver = self.fake_driver()
        fd = driver.stdout.fileno()
        position = os.lseek(fd, 0, os.SEEK_CUR)
        self.assertEqual(driver.result().stdout, "partial output ✓")
        self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), position)
        driver.stdout.write(b" later output")
        driver.stdout.flush()
        self.assertEqual(driver.result().stdout, "partial output ✓ later output")

    def test_wait_budgets_and_completed_process_contract(self):
        for phase, seconds in (("execution", 240), ("interrupt", 60)):
            with self.subTest(phase=phase):
                driver = self.fake_driver(scale=2)
                result = driver.wait(phase)
                self.assertIsInstance(result, subprocess.CompletedProcess)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout, "partial output ✓")
                self.assertEqual(result.stderr, "partial error")
                self.assertEqual(
                    driver.proc.wait.call_args_list, [mock.call(timeout=seconds)]
                )
                self.assertEqual(
                    driver.proc.reap.call_args_list,
                    [mock.call(timeout=20)],
                )

    def test_timeout_reports_output_and_bounds_cleanup(self):
        driver = self.fake_driver(scale=2)
        driver.proc.wait.side_effect = subprocess.TimeoutExpired(driver.proc.args, 240)
        driver.proc.reap.side_effect = subprocess.TimeoutExpired(driver.proc.args, 20)
        with self.assertRaises(AssertionError) as caught:
            driver.wait()
        driver.proc.signal_group.assert_called_once_with(signal.SIGKILL)
        driver.cleanup()
        driver.proc.signal_group.assert_called_once()
        for fragment in (
            self.id(),
            "execution",
            "limit=240s",
            "fixture 'argument with spaces'",
            "partial output ✓",
            "partial error",
            "process reap exceeded 20s",
        ):
            self.assertIn(fragment, str(caught.exception))
        driver.proc.wait.assert_called_once_with(timeout=240)
        self.assertEqual(
            driver.proc.reap.call_args_list,
            [mock.call(timeout=20), mock.call(timeout=20)],
        )
        driver.proc.close.assert_called_once()

    def test_ready_wait_uses_scaled_monotonic_deadline(self):
        driver = self.fake_driver(scale=2)
        ready = mock.Mock()
        ready.exists.return_value = False
        with (
            mock.patch.object(time, "monotonic", side_effect=[100, 101, 220]),
            mock.patch.object(time, "sleep") as sleep,
        ):
            with self.assertRaisesRegex(AssertionError, "ready:.*limit=120s"):
                driver.wait_ready(ready)
            sleep.assert_called_once_with(0.05)

    def test_ready_early_exit_reports_output(self):
        driver = self.fake_driver()
        driver.proc.poll.return_value = 7
        driver.proc.signal_group.side_effect = ProcessLookupError
        ready = mock.Mock()
        ready.exists.return_value = False
        with self.assertRaises(AssertionError) as caught:
            driver.wait_ready(ready)
        for fragment in ("exited before readiness", "returncode=7", "partial error"):
            self.assertIn(fragment, str(caught.exception))

    def test_file_capture_preserves_large_output_and_nonzero_exit(self):
        with driver_process(
            [
                sys.executable,
                "-c",
                (
                    "import sys; print('o' * 200000); "
                    "print('e' * 200000, file=sys.stderr); sys.exit(7)"
                ),
            ],
            cwd=ROOT,
            env=os.environ.copy(),
            scale=CONFIGURED_SCALE,
            test_id=self.id(),
        ) as driver:
            result = driver.wait()
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "o" * 200000 + "\n")
        self.assertEqual(result.stderr, "e" * 200000 + "\n")

    def process_status(self, pid):
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=TIMEOUTS["cleanup"] * CONFIGURED_SCALE,
            check=False,
        )
        self.assertIn(status.returncode, (0, 1), status.stderr)
        return status.stdout.strip()

    def assert_process_stopped(self, pid):
        deadline = time.monotonic() + TIMEOUTS["cleanup"] * CONFIGURED_SCALE
        while True:
            status = self.process_status(pid)
            # An orphan may be a zombie until the OS reaps it; it cannot run or
            # retain output descriptors. Both Linux and macOS expose Z via ps.
            if not status or status.startswith("Z"):
                return
            if time.monotonic() >= deadline:
                self.fail(f"descendant {pid} survived process-group cleanup")
            time.sleep(0.05)

    def check_descendant_cleanup(self, *, early_exit):
        with tempfile.TemporaryDirectory(prefix="spec harness ") as tmp:
            root = Path(tmp)
            ready = root / "ready"
            child_ready = root / "child-ready"
            child = (
                "import os, signal, sys\nfrom pathlib import Path\n"
                "print('child stderr', file=sys.stderr, flush=True)\n"
                "ready = Path(sys.argv[1])\n"
                "ready.with_suffix('.tmp').write_text(str(os.getpid()))\n"
                "ready.with_suffix('.tmp').replace(ready)\n"
                "while True: signal.pause()\n"
            )
            parent = (
                "import subprocess, sys, time, signal\nfrom pathlib import Path\n"
                f"subprocess.Popen([sys.executable, '-c', {child!r}, {str(child_ready)!r}])\n"
                f"while not Path({str(child_ready)!r}).exists(): time.sleep(0.01)\n"
                "print('parent stdout', flush=True)\n"
                f"Path({str(ready)!r}).touch()\n"
                + ("sys.exit(7)\n" if early_exit else "while True: signal.pause()\n")
            )
            with driver_process(
                [sys.executable, "-c", parent],
                cwd=root,
                env=os.environ.copy(),
                scale=CONFIGURED_SCALE,
                test_id=self.id(),
            ) as driver:
                # Best-effort fallback while the group identity is still owned.
                # Once reaped, signal_group must never target that PID again.
                try:
                    if early_exit:
                        result = driver.wait()
                        self.assertEqual(result.returncode, 7)
                        self.assertIn("parent stdout", result.stdout)
                        self.assertIn("child stderr", result.stderr)
                    else:
                        driver.wait_ready(ready)
                        # The fixture is known to be alive and signal-blocked.
                        # Expire immediately, without a load-sensitive sleep.
                        with self.assertRaises(AssertionError) as caught:
                            driver.wait(limit=0)
                        self.assertIn("execution: timed out", str(caught.exception))
                        self.assertIn("parent stdout", str(caught.exception))
                        self.assertIn("child stderr", str(caught.exception))
                        self.assertEqual(driver.proc.returncode, -signal.SIGKILL)
                    self.assert_process_stopped(int(child_ready.read_text()))
                finally:
                    try:
                        driver.proc.signal_group(signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_real_timeout_kills_descendant_and_preserves_output(self):
        self.check_descendant_cleanup(early_exit=False)

    def test_exited_leader_with_output_inheriting_child_does_not_hang(self):
        self.check_descendant_cleanup(early_exit=True)


class VerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Alias the setting already captured and validated at module import.
        cls.timeout_scale = CONFIGURED_SCALE

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="spec-verification-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo with spaces"
        self.repo.mkdir()
        self.state = self.base / "state"
        self.state.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(
                ("DEV_TRIO_", "MANIFEST_", "SPEC_TRIO_", "RALPH_", "AGENT_TEAM", "GIT_")
            ) or key in (
                "PLANNER_CLI",
                "CODER_CLI",
                "REVIEWER_CLI",
                "REVIEWER_ROLE_FILE",
                "RESEARCHER_CLI",
            ):
                self.env.pop(key, None)
        self.env.update(
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            PATH=f"{self.bin}:{ROOT / 'dev-trio/bin'}:" + os.environ["PATH"],
            AGENT_TEAM="verify",
            TMUX="",
            AGENT_TEAM_MODELS_CONFIG=str(self.base / "absent.json"),
            SPEC_TRIO_WORKSPACE=str(self.state / "logs"),
            FIXTURE_STATE=str(self.state),
            FIXTURE_SPEC=str(self.repo / "spec.md"),
            FIXTURE_FIX=str(self.repo / "fix_plan.md"),
            DEV_TRIO_REVIEWER_MODEL="codex",
            DEV_TRIO_RESEARCHER_MODEL="agy",
            # An agy home that does not exist: the researcher gets --add-dir
            # but no --log-file, so no run leaves a log in the real one (#103).
            DEV_TRIO_AGY_HOME=str(self.base / "no-agy-home"),
        )
        for name in ("worker", "reviewer", "researcher"):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env.update(
            CLAUDE_CLI=str(self.bin / "worker"),
            CODEX_CLI=str(self.bin / "reviewer"),
            AGY_CLI=str(self.bin / "researcher"),
        )
        real_git = shutil.which("git")
        (self.bin / "git").write_text(
            '#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\nf=os.environ.get("GIT_FAIL")\nif (f=="merge" and "merge" in a and "--ff-only" in a) or (f=="cleanup" and "worktree" in a and "remove" in a): sys.exit(1)\nos.execv('
            + repr(real_git)
            + ',["git"]+a)\n'
        )
        (self.bin / "git").chmod(0o755)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / "file.txt").write_text("baseline\n")
        (self.repo / "spec.md").write_text(
            "# Contract\n## §5 Test criteria\n### §5.1 valid value\nThe file must say good.\n"
        )
        (self.repo / "BACKLOG.md").write_text("- [ ] §5.1 update value\n")
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")
        self.command = 'test "$(cat file.txt)" = good'

    def tearDown(self):
        self.env.pop("GIT_FAIL", None)
        for line in self.git("worktree", "list", "--porcelain").splitlines():
            if (
                line.startswith("worktree ")
                and Path(line[9:]).resolve() != self.repo.resolve()
            ):
                self.git("worktree", "remove", "--force", line[9:])

    def git(self, *args):
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            env=self.env,
            timeout=TIMEOUTS["execution"] * self.timeout_scale,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def args(self, *extra, test=True):
        result = [
            "bash",
            str(DRIVER),
            "--spec",
            str(self.repo / "spec.md"),
            "--backlog",
            str(self.repo / "BACKLOG.md"),
            "--max-iter",
            "1",
            "--no-research",
        ]
        if test:
            result += ["--test-cmd", self.command]
        if "--research" in extra:
            result.remove("--no-research")
            extra = tuple(x for x in extra if x != "--research")
        return result + list(extra)

    def start_driver(self, *extra, test=True):
        return driver_process(
            self.args(*extra, test=test),
            cwd=self.repo,
            env=self.env,
            scale=self.timeout_scale,
            test_id=self.id(),
        )

    def run_driver(self, *extra, test=True):
        with self.start_driver(*extra, test=test) as driver:
            self.result = driver.wait()
        return self.result

    def rc(self, expected):
        self.assertEqual(
            self.result.returncode, expected, self.result.stderr + self.result.stdout
        )

    def pending(self, expected=True):
        self.assertEqual("[ ]" in (self.repo / "BACKLOG.md").read_text(), expected)

    def manifests(self, variant="code"):
        return [
            json.loads(p.read_text())
            for p in sorted(
                (self.state / "logs/log/verify").glob(f"*-{variant}.manifest.json")
            )
        ]

    def test_duplicate_task_rows_complete_independently(self):
        task = "- [ ] §5.1 update value\n"
        (self.repo / "BACKLOG.md").write_text(task * 2)
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), task.replace("[ ]", "[x]") * 2
        )
        self.assertEqual((self.state / "coder.count").read_text(), "2")

    def test_runtime_cap_retains_pending_work(self):
        # Advance the deadline clock only after the first planner attempt;
        # runner startup speed must not determine whether that attempt runs.
        real_date = shutil.which("date")
        (self.bin / "date").write_text(
            "#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
            + "if sys.argv[1:] == ['+%s']:\n"
            + "    print(1002 if (Path(os.environ['FIXTURE_STATE']) / 'planner.count').exists() else 1000)\n"
            + "else:\n"
            + f"    os.execv({real_date!r}, ['date'] + sys.argv[1:])\n"
        )
        (self.bin / "date").chmod(0o755)
        self.env["PLANNER_FAIL"] = "1"
        self.run_driver("--max-iter", "5", "--max-runtime", "1s")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "planner.count").read_text(), "1")
        self.assertIn("reason=max-runtime", self.result.stderr)

    def test_backlog_symlink_is_preserved_across_iterations(self):
        target = self.repo / "tasks.md"
        (self.repo / "BACKLOG.md").rename(target)
        (self.repo / "BACKLOG.md").symlink_to("tasks.md")
        target.write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.git("add", ".")
        self.git("commit", "-qm", "backlog link")
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.assertTrue((self.repo / "BACKLOG.md").is_symlink())
        self.assertEqual(target.read_text(), "- [x] §5.1 one\n- [x] §5.1 two\n")

    def test_worktree_retry_merges_only_passing_attempt(self):
        self.env["RETRY_TEST"] = "1"
        self.run_driver("--worktree", "--max-iter", "2")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_committed_failed_attempt_remains_in_retry_review(self):
        baseline = self.git("rev-parse", "HEAD").strip()
        self.env.update(COMMIT_RETRY="1", RETRY_TEST="1")
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.pending(False)
        failed = (self.state / "failed.sha").read_text()
        prompt = (self.state / "reviewer1.prompt").read_text()
        self.assertIn(f"{baseline}..{failed}", prompt)
        self.assertIn("retained.txt", self.git("diff", "--name-only", baseline, "HEAD"))
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_retry_scope_includes_previous_attempt_commits(self):
        self.env.update(COMMIT_RETRY="1", RETRY_TEST="1", NARROW_RETRY="1")
        self.run_driver("--max-iter", "2")
        self.rc(4)
        self.pending()
        self.assertIn("OUT-OF-SCOPE", self.result.stderr)
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_completed_task_resets_review_baseline(self):
        (self.repo / "BACKLOG.md").write_text("- [ ] first\n- [ ] second\n")
        self.env["COMMIT_RETRY"] = "1"
        self.run_driver("--max-iter", "2")
        self.rc(0)
        completed = (self.state / "failed.sha").read_text()
        prompt = (self.state / "reviewer2.prompt").read_text()
        self.assertIn(f"HEAD is still at `{completed}`", prompt)

    def test_retry_test_failure_does_not_reuse_ship(self):
        self.env["RESEARCH_RETRY"] = "1"
        self.command = 'test "$(cat "$FIXTURE_STATE/coder.count")" = 1'
        self.run_driver("--research")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "1"
                for i in self.manifests("code2")[0]["inputs"]
            )
        )

    def test_atomic_backlog_write_failure_leaves_task_pending(self):
        (self.bin / "mv").write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            'if any(".spec-trio." in a for a in sys.argv[1:]): sys.exit(1)\n'
            + f'os.execv({shutil.which("mv")!r}, ["mv"] + sys.argv[1:])\n'
        )
        (self.bin / "mv").chmod(0o755)
        self.run_driver("--autoship")
        self.rc(1)
        self.pending()
        self.assertIn("completed=0", self.result.stderr)
        self.assertTrue(self.manifests("review"))

    def test_requires_test_before_mutation(self):
        for command in (None, "", "  "):
            with self.subTest(command=command):
                self.command = command or ""
                self.run_driver(test=command is not None)
                self.rc(2)
                self.assertFalse((self.repo / "fix_plan.md").exists())
                self.assertFalse((self.state / "logs").exists())
                self.assertFalse((self.state / "planner.count").exists())

    def test_success_snapshot_and_test_evidence(self):
        self.run_driver()
        self.rc(0)
        self.pending(False)
        inputs = self.manifests()[0]["inputs"]
        self.assertTrue(
            any(i["kind"] == "test-rc" and i["value"] == "0" for i in inputs)
        )
        specs = [
            next(i for i in m["inputs"] if i["kind"] == "spec")
            for v in ("plan", "code", "review")
            for m in self.manifests(v)
        ]
        self.assertEqual(len({i["path"] for i in specs}), 1)
        data = Path(specs[0]["path"]).read_bytes()
        self.assertEqual(data, (self.repo / "spec.md").read_bytes())
        self.assertTrue(
            all(i["sha256"] == hashlib.sha256(data).hexdigest() for i in specs)
        )
        self.assertIn("completed=1 pending=0", self.result.stderr)

    def test_test_failure_blocks_review_and_autoship(self):
        self.command = "exit 9"
        self.run_driver("--autoship", "--no-validate")
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "9"
                for i in self.manifests()[0]["inputs"]
            )
        )

    def test_missing_test_executable(self):
        self.command = "spec_trio_missing_test_executable"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_test_rechecks_scope(self):
        self.command += "; echo stray > other.txt"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_failed_test_retries_same_row_with_context(self):
        self.env["RETRY_TEST"] = "1"
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.pending(False)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] §5.1 update value\n"
        )
        self.assertIn(
            "Previous attempt failed", (self.state / "planner2.prompt").read_text()
        )
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_coder_failure_cannot_ship(self):
        self.env["CODER_FAIL"] = "1"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertTrue(
            any(
                i.get("value") == "skipped-coder-failed"
                for i in self.manifests()[0]["inputs"]
            )
        )

    def test_guard_refusal_before_stage_never_records_stale_evidence(self):
        real_jq = shutil.which("jq")
        wrapper = self.bin / "jq"
        wrapper.write_text(
            "#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
            "a=sys.argv[1:]\n"
            "if '--arg' in a and 'name' in a and any('.roles +=' in x for x in a):\n"
            " role=a[a.index('name')+1]\n"
            " if role==os.environ['REFUSE_ROLE']:\n"
            "  p=Path(os.environ['FIXTURE_STATE'])/'role-count'\n"
            "  n=int(p.read_text())+1 if p.exists() else 1\n"
            "  p.write_text(str(n))\n"
            "  if n==int(os.environ['REFUSE_ATTEMPT']): Path(os.environ['FIXTURE_SPEC']).write_text('changed before stage')\n"
            "os.execv(" + repr(real_jq) + ",[" + repr(real_jq) + "]+a)\n"
        )
        wrapper.chmod(0o755)
        spec = self.repo / "spec.md"
        original = spec.read_text()
        for role, attempt in (("planner", 1), ("worker", 1), ("worker", 2)):
            with self.subTest(role=role, attempt=attempt):
                spec.write_text(original)
                for name in ("role-count", "coder.count", "planner.count", "reviewer.count"):
                    (self.state / name).unlink(missing_ok=True)
                self.env.update(REFUSE_ROLE=role, REFUSE_ATTEMPT=str(attempt))
                if attempt == 2:
                    self.env["RESEARCH_RETRY"] = "1"
                else:
                    self.env.pop("RESEARCH_RETRY", None)
                previous = set((self.state / "logs/log/verify").glob("*.manifest.json"))
                self.run_driver("--worktree", "--research")
                self.rc(4)
                self.pending()
                self.assertIn("Preserved worktree:", self.result.stderr)
                self.assertNotIn("unbound variable", self.result.stderr)
                count = self.state / "coder.count"
                self.assertEqual(int(count.read_text()) if count.exists() else 0, attempt - 1)
                variant = "plan" if role == "planner" else "code" if attempt == 1 else "code2"
                current = set((self.state / "logs/log/verify").glob("*.manifest.json"))
                self.assertFalse([p for p in current - previous if p.name.endswith(f"-{variant}.manifest.json")])
                self.tearDown()  # release the intentionally preserved fixture worktree

    def test_planner_failure_preserves_task(self):
        self.env["PLANNER_FAIL"] = "1"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())

    def test_research_retry_runs_tests_again(self):
        self.env["RESEARCH_RETRY"] = "1"
        self.run_driver("--research")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.state / "coder.count").read_text(), "2")
        self.assertEqual((self.state / "reviewer.count").read_text(), "2")
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "0"
                for i in self.manifests("code2")[0]["inputs"]
            )
        )

    def test_research_retry_coder_failure(self):
        self.env.update(RESEARCH_RETRY="1", CODER_FAIL="2")
        self.run_driver("--research")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_human_verdict_stops_before_next_task(self):
        for verdict in ("DISCUSS", "UNKNOWN", "OUT-OF-SCOPE"):
            with self.subTest(verdict=verdict):
                self.env["VERDICT"] = verdict
                self.run_driver("--max-iter", "4")
                self.rc(4)
                self.pending()
        self.assertEqual((self.state / "coder.count").read_text(), "3")

    def test_original_mutation_stops_stages(self):
        self.env["MUTATE"] = "planner"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())
        self.assertEqual((self.repo / "spec.md").read_text(), "changed contract")

    def test_snapshot_mutation(self):
        self.env["MUTATE"] = "coder-snapshot"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_deleted_spec(self):
        self.env["MUTATE"] = "coder-delete"
        self.run_driver()
        self.rc(4)
        self.pending()

    def test_reviewer_spec_mutation(self):
        self.env["MUTATE"] = "reviewer"
        self.run_driver()
        self.rc(4)
        self.pending()

    def test_test_spec_mutation(self):
        self.command = 'echo changed > "$FIXTURE_SPEC"'
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_research_spec_mutation(self):
        self.env.update(PLAN_RESEARCH="1", MUTATE="researcher")
        self.run_driver("--research")
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())

    def test_backlog_conflict_not_overwritten(self):
        self.env["MUTATE"] = "coder-backlog"
        self.run_driver()
        self.rc(4)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] falsely completed\n"
        )
        self.assertIn("completed=0", self.result.stderr)

    def test_stale_promise_does_not_complete_remaining_task(self):
        (self.repo / "BACKLOG.md").write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.env["PROMISE"] = "1"
        self.run_driver()
        self.rc(3)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] §5.1 one\n- [ ] §5.1 two\n"
        )

    def test_dry_run_does_not_requeue_or_execute(self):
        before = (self.repo / "BACKLOG.md").read_bytes()
        self.run_driver("--dry-run", "--coverage-requeue", test=False)
        self.rc(0)
        self.assertEqual(before, (self.repo / "BACKLOG.md").read_bytes())
        self.assertFalse((self.state / "planner.count").exists())
        self.assertIn("status=dry-run completed=0", self.result.stderr)

    def coverage_hook(self, body):
        # Run a deterministic concurrent-edit fixture during classification,
        # without replacing the actual coverage helper or production driver.
        git = shutil.which("git")
        marker = self.state / "coverage-hook-fired"
        (self.bin / "git").write_text(
            "#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
            + f"marker=Path({str(marker)!r})\n"
            + 'if "log" in sys.argv[1:] and not marker.exists():\n'
            + "    marker.touch()\n"
            + "\n".join("    " + line for line in body.splitlines())
            + f'\nos.execv({git!r}, ["git"] + sys.argv[1:])\n'
        )
        (self.bin / "git").chmod(0o755)

    def check_coverage_backlog_conflict(self, flag):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.coverage_hook(
            f"p=Path({str(backlog)!r})\np.write_text(p.read_text().replace('[ ]', '[x]'))"
        )
        self.run_driver(flag)
        self.rc(4)
        self.assertEqual((self.state / "coder.count").read_text(), "1")
        self.assertIn("status=blocked completed=1", self.result.stderr)
        self.assertEqual(backlog.read_text(), "- [x] §5.1 one\n- [x] §5.1 two\n")
        self.assertNotIn("spec coverage gap", backlog.read_text())

    def test_read_only_coverage_rejects_backlog_changes(self):
        self.check_coverage_backlog_conflict("--coverage-check")

    def test_requeue_rejects_backlog_changes_before_applying_additions(self):
        self.check_coverage_backlog_conflict("--coverage-requeue")

    def test_coverage_requeue_persistence_failure(self):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [x] already complete\n")
        backlog.chmod(0o444)
        self.addCleanup(backlog.chmod, 0o644)
        if os.access(backlog, os.W_OK):
            self.skipTest("requires a user without write access to a read-only file")
        self.run_driver("--coverage-requeue")
        self.rc(1)
        self.assertIn("reason=coverage-persistence-failed", self.result.stderr)
        self.assertEqual(backlog.read_text(), "- [x] already complete\n")
        self.assertNotIn("status=completed", self.result.stderr)

    def test_standalone_coverage_propagates_append_failure(self):
        destination = self.base / "read-only-backlog"
        destination.write_text("- [x] already complete\n")
        destination.chmod(0o444)
        self.addCleanup(destination.chmod, 0o644)
        if os.access(destination, os.W_OK):
            self.skipTest("requires a user without write access to a read-only file")
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "spec-trio/bin/spec-coverage.sh"),
                "--spec",
                str(self.repo / "spec.md"),
                "--no-partial",
                "--requeue",
                str(destination),
            ],
            cwd=self.repo,
            env=self.env,
            timeout=TIMEOUTS["execution"] * self.timeout_scale,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("0 additions written", result.stderr)
        self.assertNotIn("appended 1", result.stderr)
        self.assertEqual(destination.read_text(), "- [x] already complete\n")

    def test_requeue_uses_guarded_atomic_publication(self):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [x] already complete")
        self.run_driver("--coverage-requeue")
        self.rc(3)
        self.assertEqual(
            backlog.read_text(),
            "- [x] already complete\n- [ ] (spec coverage gap §5.1) valid value\n",
        )
        self.assertFalse((self.state / "coder.count").exists())

    def check_intermediate_symlink_retarget(self, name):
        original = self.repo / name
        old = self.base / ("old-" + name)
        new = self.base / ("new-" + name)
        chain = self.base / ("middle-" + name)
        content = original.read_text()
        old.write_text(content)
        new.write_text(content)
        chain.symlink_to(old)
        original.unlink()
        original.symlink_to(chain)
        self.git("add", name)
        self.git("commit", "-qm", "chain fixture")
        self.env.update(FIXTURE_CHAIN=str(chain), FIXTURE_NEW=str(new))
        self.command = 'ln -sfn "$FIXTURE_NEW" "$FIXTURE_CHAIN"; ' + self.command
        self.run_driver()
        self.rc(4)
        self.assertEqual(old.read_text(), content)
        self.assertEqual(new.read_text(), content)
        self.assertEqual(original.resolve(), new)
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertIn("completed=0", self.result.stderr)

    def test_backlog_chain_retarget_cannot_complete_old_destination(self):
        self.check_intermediate_symlink_retarget("BACKLOG.md")

    def test_spec_chain_retarget_is_a_contract_change(self):
        self.check_intermediate_symlink_retarget("spec.md")

    def physical_parent_fixture(self, name, *, direct=False):
        local = self.base / "local"
        remote = self.base / "remote"
        local.mkdir()
        (remote / "child").mkdir(parents=True)
        content = (self.repo / name).read_text()
        actual = remote / name
        decoy = local / name
        actual.write_text(content)
        decoy.write_text(content)
        (local / "dirlink").symlink_to(remote / "child")
        if direct:
            supplied = local / "dirlink" / ".." / name
        else:
            supplied = local / "input"
            supplied.symlink_to("dirlink/../" + name)
        self.assertEqual(supplied.read_text(), content)
        return supplied, actual, decoy, content

    def test_physical_parent_spec_guard(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("spec.md")
        self.env.update(MUTATE="coder", FIXTURE_SPEC=str(actual))
        self.run_driver("--spec", str(supplied))
        self.rc(4)
        self.assertEqual(decoy.read_text(), content)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_physical_parent_completion(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("BACKLOG.md")
        self.run_driver("--backlog", str(supplied))
        self.rc(0)
        self.assertEqual(actual.read_text(), content.replace("[ ]", "[x]"))
        self.assertEqual(decoy.read_text(), content)
        self.assertTrue(supplied.is_symlink())

    def test_physical_parent_requeue(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("BACKLOG.md")
        actual.write_text("- [x] already complete\n")
        self.run_driver("--backlog", str(supplied), "--coverage-requeue")
        self.rc(3)
        self.assertEqual(
            actual.read_text(),
            "- [x] already complete\n- [ ] (spec coverage gap §5.1) valid value\n",
        )
        self.assertEqual(decoy.read_text(), content)
        self.assertFalse((self.state / "coder.count").exists())

    def test_direct_physical_parent_backlog_path(self):
        supplied, actual, decoy, content = self.physical_parent_fixture(
            "BACKLOG.md", direct=True
        )
        self.run_driver("--backlog", str(supplied))
        self.rc(0)
        self.assertEqual(actual.read_text(), content.replace("[ ]", "[x]"))
        self.assertEqual(decoy.read_text(), content)

    def test_post_publication_edit_is_not_adopted_as_expected_content(self):
        real_mv = shutil.which("mv")
        (self.bin / "mv").write_text(
            "#!/usr/bin/env python3\nimport sys,subprocess\nfrom pathlib import Path\n"
            + f"subprocess.run([{real_mv!r}] + sys.argv[1:], check=True)\n"
            + 'if any(".spec-trio." in a for a in sys.argv[1:]):\n'
            + '    Path(sys.argv[-1]).write_text("external replacement\\n")\n'
        )
        (self.bin / "mv").chmod(0o755)
        self.run_driver("--autoship")
        self.rc(4)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "external replacement\n"
        )
        self.assertNotIn("status=completed", self.result.stderr)

    def test_coverage_requeue_makes_run_pending(self):
        self.run_driver("--coverage-requeue")
        self.rc(3)
        self.assertIn("spec coverage gap §5.1", (self.repo / "BACKLOG.md").read_text())
        self.assertIn("reason=coverage-requeued", self.result.stderr)

    def test_worktree_success(self):
        self.run_driver("--worktree")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")

    def test_worktree_spec_mutation(self):
        self.env["MUTATE"] = "coder-worktree"
        self.run_driver("--worktree")
        self.rc(4)
        self.pending()
        self.assertEqual((self.repo / "file.txt").read_text(), "baseline\n")

    def test_worktree_merge_failure(self):
        self.env["GIT_FAIL"] = "merge"
        self.run_driver("--worktree")
        self.rc(1)
        self.pending()
        self.assertEqual((self.repo / "file.txt").read_text(), "baseline\n")

    def test_worktree_cleanup_failure_after_merge(self):
        self.env["GIT_FAIL"] = "cleanup"
        self.run_driver("--worktree")
        self.rc(1)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")
        self.assertIn("completed=1", self.result.stderr)

    def test_interrupt_retains_pending_task(self):
        self.env["INTERRUPT"] = "1"
        with self.start_driver() as driver:
            driver.wait_ready(self.state / "ready")
            driver.proc.signal_group(signal.SIGINT)
            self.result = driver.wait("interrupt")
            self.rc(130)
            self.pending()

    def test_coverage_uses_complete_identifier(self):
        (self.repo / "file.txt").write_text("changed\n")
        self.git("add", "file.txt")
        self.git("commit", "-qm", "spec §5.10, §5.100 and §5.1.2 only")
        args = [
            "bash",
            str(ROOT / "spec-trio/bin/spec-coverage.sh"),
            "--spec",
            str(self.repo / "spec.md"),
            "--no-partial",
        ]
        result = subprocess.run(
            args,
            cwd=self.repo,
            env=self.env,
            timeout=TIMEOUTS["execution"] * self.timeout_scale,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("NOT-COVERED", result.stdout)
        self.git("commit", "--allow-empty", "-qm", "spec §5.1. Also §5.10.")
        result = subprocess.run(
            args,
            cwd=self.repo,
            env=self.env,
            timeout=TIMEOUTS["execution"] * self.timeout_scale,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertNotIn("NOT-COVERED", result.stdout)
        self.assertIn("COVERED", result.stdout)


if __name__ == "__main__" and sys.argv[1:] != ["--check-config"]:
    unittest.main()
