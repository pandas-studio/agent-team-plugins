#!/usr/bin/env python3
"""Real spec driver and dev-trio wrappers; replace only external model CLIs."""

import hashlib
import json
import math
import os
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
    try:
        scale = float(raw)
    except ValueError:
        scale = 0
    if scale <= 0 or not math.isfinite(scale * max(TIMEOUTS.values())):
        raise ValueError(
            f"{TIMEOUT_SCALE_ENV} must be a finite positive number "
            f"with finite timeouts; got {raw!r}"
        )
    return scale


class DriverProcess:
    def __init__(self, proc, stdout, stderr, scale, test_id):
        self.proc = proc
        self.stdout = stdout
        self.stderr = stderr
        self.limits = {phase: seconds * scale for phase, seconds in TIMEOUTS.items()}
        self.test_id = test_id
        self.cleaned = False
        self.cleanup_error = ""

    def result(self):
        def snapshot(stream):
            # Even if cleanup fails, read only the current file size without
            # moving an offset shared with a surviving writer.
            fd = stream.fileno()
            return os.pread(fd, os.fstat(fd).st_size, 0).decode(
                "utf-8", errors="replace"
            )

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
        # A leader may already have exited while children still hold output open.
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            self.cleanup_error = f"process group cleanup failed: {exc}"
        try:
            self.proc.wait(timeout=self.limits["cleanup"])
        except subprocess.TimeoutExpired:
            self.cleanup_error += f" process reap exceeded {self.limits['cleanup']:g}s"
        return self.cleanup_error

    def failure(self, phase, reason):
        cleanup_error = self.cleanup()
        result = self.result()
        return AssertionError(
            f"{self.test_id}: {phase}: {reason} "
            f"(limit={self.limits[phase]:g}s, returncode={result.returncode})\n"
            f"command: {shlex.join(self.proc.args)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}\n"
            f"{cleanup_error}"
        )

    def wait(self, phase="execution"):
        try:
            self.proc.wait(timeout=self.limits[phase])
        except subprocess.TimeoutExpired:
            raise self.failure(phase, "timed out") from None
        # Stop any descendants even if the leader has already exited.
        if self.cleanup():
            raise self.failure("cleanup", "could not finish process cleanup")
        return self.result()

    def wait_ready(self, path):
        deadline = time.monotonic() + self.limits["ready"]
        while True:
            if self.proc.poll() is not None:
                raise self.failure("ready", "driver exited before readiness")
            if path.exists():
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise self.failure("ready", "timed out waiting for readiness")
            time.sleep(min(0.05, remaining))


@contextmanager
def driver_process(args, *, cwd, env, scale, test_id):
    # File-backed capture avoids a full pipe during readiness waits and avoids
    # unbounded communicate() when an orphan inherits the output descriptors.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        proc = subprocess.Popen(
            args,
            cwd=cwd,
            env=env,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        driver = DriverProcess(proc, stdout, stderr, scale, test_id)
        try:
            yield driver
        finally:
            cleanup_error = driver.cleanup()
            if cleanup_error and sys.exc_info()[0] is None:
                raise driver.failure("cleanup", "could not finish process cleanup")


STUB = r"""#!/usr/bin/env python3
import os, sys, json, signal, time, subprocess
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
    def test_timeout_scale_default_and_overrides(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(timeout_scale(), 1)
            for value, expected in (("2", 2), ("0.5", 0.5)):
                os.environ[TIMEOUT_SCALE_ENV] = value
                self.assertEqual(timeout_scale(), expected)

    def test_invalid_timeout_scales(self):
        for value in ("0", "-1", "", "invalid", "nan", "inf", "-inf", "1e308"):
            with (
                self.subTest(value=value),
                mock.patch.dict(os.environ, {TIMEOUT_SCALE_ENV: value}),
                self.assertRaisesRegex(ValueError, TIMEOUT_SCALE_ENV),
            ):
                timeout_scale()

    def fake_driver(self, scale=1):
        proc = mock.Mock(
            args=["fixture", "argument with spaces"], pid=12345, returncode=7
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
            with self.subTest(phase=phase), mock.patch.object(os, "killpg"):
                driver = self.fake_driver(scale=2)
                result = driver.wait(phase)
                self.assertIsInstance(result, subprocess.CompletedProcess)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout, "partial output ✓")
                self.assertEqual(result.stderr, "partial error")
                self.assertEqual(
                    driver.proc.wait.call_args_list,
                    [mock.call(timeout=seconds), mock.call(timeout=20)],
                )

    def test_timeout_reports_output_and_bounds_cleanup(self):
        driver = self.fake_driver(scale=2)
        driver.proc.wait.side_effect = [
            subprocess.TimeoutExpired(driver.proc.args, 240),
            subprocess.TimeoutExpired(driver.proc.args, 20),
        ]
        with mock.patch.object(os, "killpg") as kill:
            with self.assertRaises(AssertionError) as caught:
                driver.wait()
            kill.assert_called_once_with(12345, signal.SIGKILL)
            # A second cleanup must not signal a potentially recycled PID.
            driver.cleanup()
            kill.assert_called_once()
        message = str(caught.exception)
        for fragment in (
            self.id(),
            "execution",
            "limit=240s",
            "fixture 'argument with spaces'",
            "partial output ✓",
            "partial error",
            "process reap exceeded 20s",
        ):
            self.assertIn(fragment, message)
        self.assertEqual(
            driver.proc.wait.call_args_list,
            [mock.call(timeout=240), mock.call(timeout=20)],
        )

    def test_ready_wait_uses_scaled_monotonic_deadline(self):
        driver = self.fake_driver(scale=2)
        ready = mock.Mock()
        ready.exists.return_value = False
        with (
            mock.patch.object(time, "monotonic", side_effect=[100, 101, 220]),
            mock.patch.object(time, "sleep") as sleep,
            mock.patch.object(os, "killpg"),
        ):
            with self.assertRaisesRegex(AssertionError, "ready:.*limit=120s"):
                driver.wait_ready(ready)
            sleep.assert_called_once_with(0.05)

    def test_ready_early_exit_reports_output(self):
        driver = self.fake_driver()
        driver.proc.poll.return_value = 7
        with (
            mock.patch.object(os, "killpg", side_effect=ProcessLookupError),
            self.assertRaises(AssertionError) as caught,
        ):
            driver.wait_ready(mock.Mock())
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
            scale=timeout_scale(),
            test_id=self.id(),
        ) as driver:
            result = driver.wait()
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "o" * 200000 + "\n")
        self.assertEqual(result.stderr, "e" * 200000 + "\n")

    def assert_process_stopped(self, pid):
        deadline = time.monotonic() + 10 * timeout_scale()
        while True:
            status = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(pid)],
                capture_output=True,
                text=True,
                timeout=10 * timeout_scale(),
                check=False,
            )
            self.assertIn(status.returncode, (0, 1), status.stderr)
            # An orphan may be a zombie until the OS reaps it; it cannot run or
            # retain output descriptors. Both Linux and macOS expose Z via ps.
            if not status.stdout.strip() or status.stdout.lstrip().startswith("Z"):
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
                scale=timeout_scale(),
                test_id=self.id(),
            ) as driver:
                # Independent fallback cleanup also protects the test runner if
                # a regression disables the harness's process-group kill.
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
                        driver.limits["execution"] = 0
                        with self.assertRaises(AssertionError) as caught:
                            driver.wait()
                        self.assertIn("execution: timed out", str(caught.exception))
                        self.assertIn("parent stdout", str(caught.exception))
                        self.assertIn("child stderr", str(caught.exception))
                        self.assertEqual(driver.proc.returncode, -signal.SIGKILL)
                    self.assert_process_stopped(int(child_ready.read_text()))
                finally:
                    try:
                        os.killpg(driver.proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_real_timeout_kills_descendant_and_preserves_output(self):
        self.check_descendant_cleanup(early_exit=False)

    def test_exited_leader_with_output_inheriting_child_does_not_hang(self):
        self.check_descendant_cleanup(early_exit=True)


class VerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Read from the parent before setUp removes SPEC_TRIO_* from child env.
        cls.timeout_scale = timeout_scale()

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
            os.killpg(driver.proc.pid, signal.SIGINT)
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
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertNotIn("NOT-COVERED", result.stdout)
        self.assertIn("COVERED", result.stdout)


if __name__ == "__main__":
    try:
        timeout_scale()
    except ValueError as exc:
        raise SystemExit(str(exc)) from None
    unittest.main()
