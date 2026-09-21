"""Publication and live-pane selection tests; no model or tmux dependency.

The viewer's sleep is a barrier, not a shortened polling interval. Publishers
can finish any number of switches before the test permits the next observation.
"""

import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1] / "debate-conductor"
BASH = "/bin/bash"


class SelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="debate selection ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.team = self.root / "log" / "test"
        self.team.mkdir(parents=True)
        self.state = self.team / "latest-debate.json"
        self.link = self.team / "latest-debate"
        self.lock = self.team / ".latest-debate.lock"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("DEBATE_", "AGENT_TEAM", "GENERATOR_", "CRITIC_"))}
        self.env.update(TMUX="", AGENT_TEAM="test", DEBATE_LOG_DIR=str(self.root / "log"))
        self.dirs = {}
        for name in "ABCDEF":
            directory = self.team / f"debate-{name}"
            directory.mkdir()
            for role in ("gen", "crit"):
                (directory / f"stream-{role}.log").write_text(f"{name}-INITIAL\n")
            self.dirs[name] = directory
        self.out = self.root / "pane.out"
        self.gate = self.root / "gate"
        self.gate.mkdir()

    def publisher(self, name, *, env=None):
        proc = subprocess.Popen(
            [BASH, "-c", 'set -euo pipefail; . "$1"; debate_selection_publish "$2" "$3"',
             "publish", str(PLUGIN / "lib/selection.sh"), str(self.team), str(self.dirs[name])],
            env=self.env | (env or {}), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        def cleanup():
            if proc.poll() is None:
                proc.terminate()
            proc.communicate(timeout=10)
        self.addCleanup(cleanup)
        return proc

    def publish(self, name, *, env=None, expected=0):
        proc = self.publisher(name, env=env)
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, expected, out + err)
        return err

    def snapshot(self):
        return json.loads(self.state.read_text())

    def await_condition(self, condition, message):
        deadline = time.monotonic() + 15
        while not condition():
            if time.monotonic() >= deadline:
                self.fail(message + "\n" + self.output())
            time.sleep(0.02)

    def output(self):
        return self.out.read_text(errors="replace") if self.out.exists() else ""

    def await_output(self, text):
        self.await_condition(lambda: text in self.output(), f"missing {text!r}: {self.output()}")

    def shim(self, name, body):
        tools = self.root / f"tools-{name}"
        tools.mkdir(exist_ok=True)
        script = tools / name
        script.write_text(f"#!{sys.executable}\n" + body)
        script.chmod(0o755)
        return str(tools) + os.pathsep + self.env["PATH"]

    def viewer(self, role="gen", *, terminal=False, extra_path=None):
        env = self.env.copy()
        master = None
        slave = None
        kwargs = {"start_new_session": True}
        if terminal:
            import fcntl
            import termios
            master, slave = pty.openpty()

            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            kwargs = {"preexec_fn": controlling_terminal}
        else:
            env["PATH"] = self.shim("sleep",
                "import os, pathlib, sys, time\n"
                f"gate = pathlib.Path({str(self.gate)!r})\n"
                f"real_sleep = {shutil.which('sleep')!r}\n"
                "if sys.argv[1:] != ['1']:\n"
                "    os.execv(real_sleep, [real_sleep, *sys.argv[1:]])\n"
                "counter = gate / 'counter'\n"
                "n = int(counter.read_text()) + 1 if counter.exists() else 1\n"
                "counter.write_text(str(n))\n"
                "(gate / f'{n}.ready').touch()\n"
                "deadline = time.monotonic() + 30\n"
                "while not (gate / f'{n}.go').exists() and not (gate / 'all').exists():\n"
                "    if time.monotonic() > deadline: sys.exit(9)\n"
                "    time.sleep(0.01)\n")
        if extra_path:
            env["PATH"] = extra_path + os.pathsep + env["PATH"]
        capture = self.out.open("wb")
        proc = subprocess.Popen(
            [BASH, str(PLUGIN / "bin/tail-role.sh"), role], env=env,
            stdin=slave if terminal else subprocess.DEVNULL,
            stdout=slave if terminal else capture, stderr=subprocess.STDOUT, **kwargs,
        )
        collector = None
        collecting = threading.Event()
        if slave is not None:
            os.close(slave)
            # All three descriptors must belong to the PTY, as in tmux. With
            # stderr redirected, bash 3.2 cannot hand the foreground terminal
            # to its stty child; that child stops on SIGTTOU before startup.
            def collect():
                try:
                    while not collecting.is_set():
                        if not select.select([master], [], [], 0.1)[0]:
                            continue
                        data = os.read(master, 65536)
                        if not data:
                            break
                        capture.write(data)
                        capture.flush()
                except OSError:
                    pass  # PTY EOF is EIO on Linux.
                finally:
                    capture.close()
            collector = threading.Thread(target=collect, daemon=True)
            collector.start()
        else:
            capture.close()

        def cleanup():
            (self.gate / "all").touch()
            # Let the controller terminate its pipeline before PTY hangup.
            # Closing the master first can kill the controller with SIGHUP
            # and orphan its still-running tail/awk process group on macOS.
            if proc.poll() is None:
                proc.send_signal(signal.SIGCONT)
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass  # Closing the PTY also releases a stopped stty.
            if collector is not None:
                collecting.set()
                collector.join(timeout=5)
            if master is not None:
                os.close(master)
            if proc.poll() is None:
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

        self.addCleanup(cleanup)
        if not terminal:
            self.await_poll(1)
        return proc, master

    def await_poll(self, number):
        self.await_condition(lambda: (self.gate / f"{number}.ready").exists(),
                             f"poll {number} not reached: {self.output()}")

    def step(self, number):
        (self.gate / f"{number}.go").touch()
        self.await_poll(number + 1)

    def append(self, name, text, role="gen"):
        with (self.dirs[name] / f"stream-{role}.log").open("a") as stream:
            stream.write(text + "\n")

    def test_sequence_tracks_changes_not_continues(self):
        for name, sequence in (("A", 1), ("A", 1), ("B", 2), ("A", 3)):
            self.publish(name)
            self.assertEqual(self.snapshot(), {"v": 1, "sequence": sequence,
                                              "debate_dir": str(self.dirs[name])})
            self.assertEqual(os.readlink(self.link), f"debate-{name}")
            self.assertFalse(self.lock.is_symlink())

    def test_publish_after_selected_directory_is_pruned(self):
        self.publish("A")
        shutil.rmtree(self.dirs["A"])
        self.publish("B")
        self.assertEqual(self.snapshot()["sequence"], 2)
        self.assertEqual(self.link.resolve(), self.dirs["B"])

    def test_integral_decimal_sequence_is_normalized(self):
        self.publish("A")
        self.state.write_text(self.state.read_text().replace('"sequence":1', '"sequence":1.0'))
        self.viewer()
        self.await_output("A-INITIAL")
        self.publish("B")
        self.step(1)
        self.await_output("B-INITIAL")
        self.assertEqual(self.snapshot()["sequence"], 2)
        self.assertNotIn("integer expression expected", self.output())

    def test_first_rollback_failure_reports_and_cleans_temporary_snapshot(self):
        path = self.shim("mv", "import sys\nsys.exit(17)\n")
        real_rm = shutil.which("rm")
        self.shim("rm", "import os, sys\n"
                  "if sys.argv[-1].endswith('/latest-debate'): sys.exit(18)\n"
                  f"os.execv({real_rm!r}, [{real_rm!r}, *sys.argv[1:]])\n")
        path = str(self.root / "tools-rm") + os.pathsep + path
        err = self.publish("A", env={"PATH": path}, expected=1)
        self.assertIn("selection rollback failed", err)
        self.assertTrue(self.lock.is_symlink())
        self.assertEqual(list(self.team.glob(".latest-debate.json.*")), [])

    def test_snapshot_permissions_follow_umask(self):
        for mask, expected in (("0022", 0o644), ("0002", 0o664), ("0077", 0o600)):
            with self.subTest(mask=mask):
                result = subprocess.run(
                    [BASH, "-c", 'umask "$1"; . "$2"; debate_selection_publish "$3" "$4"',
                     "publish", mask, str(PLUGIN / "lib/selection.sh"),
                     str(self.team), str(self.dirs["A"])], capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.state.stat().st_mode & 0o777, expected)

    def test_missing_directory_at_start_waits_for_next_selection(self):
        self.publish("A")
        shutil.rmtree(self.dirs["A"])
        proc, _ = self.viewer()
        self.await_output("selected debate directory missing")
        self.publish("B")
        self.step(1)
        self.await_output("B-INITIAL")
        self.assertIsNone(proc.poll())
        self.assertNotIn("selection state invalid", self.output())

    def test_active_directory_removal_waits_and_recovers(self):
        self.publish("A")
        proc, _ = self.viewer()
        self.await_output("A-INITIAL")
        shutil.rmtree(self.dirs["A"])
        self.step(1)
        self.await_output("selected debate directory missing")
        self.assertIsNone(proc.poll())
        self.publish("B")
        self.step(2)
        self.await_output("B-INITIAL")
        self.assertNotIn("selection state invalid", self.output())

    def test_jq_failure_is_diagnosed_and_polling_recovers(self):
        self.publish("A")
        path = self.shim("jq", "import sys\nsys.exit(127)\n").split(os.pathsep)[0]
        proc, _ = self.viewer(extra_path=path)
        self.await_output("jq unavailable or failed")
        self.step(1)
        self.assertEqual(self.output().count("jq unavailable or failed"), 1)
        (Path(path) / "jq").unlink()
        self.step(2)
        self.await_output("A-INITIAL")
        self.assertIsNone(proc.poll())
        self.assertNotIn("repair latest-debate.json", self.output())

    def test_aba_without_follower_reports_waiting(self):
        self.publish("A")
        (self.dirs["A"] / "stream-gen.log").unlink()
        self.viewer()
        self.publish("B")
        self.publish("A")
        self.step(1)
        self.await_output("missed 1 intermediate debate selection — waiting for current stream")
        self.append("A", "A-NEW-STREAM")
        self.step(2)
        self.await_output("A-NEW-STREAM")

    def test_rollback_failure_retains_lock_but_cleans_temporary_snapshot(self):
        self.publish("A")
        before = self.state.read_bytes()
        path = self.shim("mv", "import sys\nsys.exit(17)\n")
        real_ln = shutil.which("ln")
        self.shim("ln", "import os, sys\n"
                  "if sys.argv[1:3] == ['-sfn', 'debate-A']: sys.exit(18)\n"
                  f"os.execv({real_ln!r}, [{real_ln!r}, *sys.argv[1:]])\n")
        path = str(self.root / "tools-ln") + os.pathsep + path
        err = self.publish("B", env={"PATH": path}, expected=1)
        self.assertIn("selection rollback failed", err)
        self.assertTrue(self.lock.is_symlink())
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(list(self.team.glob(".latest-debate.json.*")), [])

    def test_concurrent_publishers_leave_whole_monotonic_snapshots(self):
        self.publish("A")
        processes = [self.publisher(name) for name in "BCDEF"]
        previous = 1
        deadline = time.monotonic() + 15
        while any(p.poll() is None for p in processes):
            self.assertLess(time.monotonic(), deadline, "publishers did not exit")
            record = self.snapshot()
            self.assertGreaterEqual(record["sequence"], previous)
            self.assertIn(record["debate_dir"], [str(p) for p in self.dirs.values()])
            previous = record["sequence"]
            time.sleep(0.005)
        for proc in processes:
            out, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, out + err)
        self.assertEqual(self.snapshot()["sequence"], 6)
        self.assertEqual(str(self.link.resolve()), self.snapshot()["debate_dir"])

    def test_failed_commit_rolls_back_link_and_cleans_lock(self):
        self.publish("A")
        before = self.state.read_bytes()
        path = self.shim("mv", "import sys\nsys.exit(17)\n")
        self.publish("B", env={"PATH": path}, expected=1)
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(self.link.resolve(), self.dirs["A"])
        self.assertFalse(self.lock.is_symlink())
        self.assertEqual(list(self.team.glob(".latest-debate.json.*")), [])

    def test_first_failed_commit_leaves_no_selection(self):
        path = self.shim("mv", "import sys\nsys.exit(17)\n")
        self.publish("A", env={"PATH": path}, expected=1)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.link.is_symlink())
        self.assertFalse(self.lock.is_symlink())

    def test_signal_after_commit_preserves_committed_selection(self):
        self.publish("A")
        path = self.shim("mv",
            "import os, signal, subprocess, sys\n"
            f"subprocess.run([{shutil.which('mv')!r}, *sys.argv[1:]], check=True)\n"
            "os.kill(os.getppid(), signal.SIGTERM)\n")
        self.publish("B", env={"PATH": path}, expected=143)
        self.assertEqual(self.snapshot()["sequence"], 2)
        self.assertEqual(self.link.resolve(), self.dirs["B"])
        self.assertFalse(self.lock.is_symlink())

    def test_signal_before_commit_restores_previous_selection(self):
        self.publish("A")
        before = self.state.read_bytes()
        path = self.shim("mv",
            "import os, signal, sys\n"
            "os.kill(os.getppid(), signal.SIGTERM)\n"
            "sys.exit(143)\n")
        self.publish("B", env={"PATH": path}, expected=143)
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(self.link.resolve(), self.dirs["A"])
        self.assertFalse(self.lock.is_symlink())

    def test_integer_sleep_fallback_preserves_lock_timeout(self):
        self.lock.symlink_to("host=gone pid=999999 run=fixture")
        proc = subprocess.run(
            [BASH, "-c", ('set -euo pipefail; . "$1"; '
             'sleep() { if [ "$1" = 0.1 ]; then return 1; fi; '
             '[ "$1" = 1 ] || return 9; SECONDS=$((SECONDS + 5)); }; '
             'debate_selection_publish "$2" "$3"'),
             "publish", str(PLUGIN / "lib/selection.sh"), str(self.team), str(self.dirs["A"])],
            env=self.env, capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("selection lock busy", proc.stderr)
        self.assertEqual(os.readlink(self.lock), "host=gone pid=999999 run=fixture")
        self.assertFalse(self.state.exists())

    def test_stranded_lock_is_not_reclaimed(self):
        self.lock.symlink_to("host=gone pid=999999 run=fixture")
        # Advance bash's elapsed counter through a shell sleep shim, avoiding
        # a five-second wall-clock wait while exercising the real deadline.
        proc = subprocess.run(
            [BASH, "-c", '. "$1"; sleep() { SECONDS=$((SECONDS + 5)); }; debate_selection_publish "$2" "$3"',
             "locked", str(PLUGIN / "lib/selection.sh"), str(self.team), str(self.dirs["A"])],
            env=self.env, capture_output=True, text=True, timeout=5, check=False,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("selection lock busy", proc.stderr)
        self.assertEqual(os.readlink(self.lock), "host=gone pid=999999 run=fixture")
        self.assertFalse(self.state.exists())

    def test_aba_between_polls_notices_gap_without_replaying_a(self):
        self.publish("A")
        proc, _ = self.viewer()
        self.await_output("A-INITIAL")
        self.publish("B")
        self.publish("A")
        self.step(1)
        self.await_output("missed 1 intermediate debate selection — continuing current stream")
        self.append("A", "A-AFTER-RETURN")
        self.await_output("A-AFTER-RETURN")
        self.step(2)
        self.assertIsNone(proc.poll())
        self.assertEqual(self.output().count("A-INITIAL"), 1)
        self.assertEqual(self.output().count("A-AFTER-RETURN"), 1)
        self.assertEqual(self.output().count("missed 1"), 1)
        self.assertNotIn("B-INITIAL", self.output())

    def test_abc_between_polls_follows_latest_after_notice(self):
        self.publish("A")
        self.viewer(role="crit")
        self.await_output("A-INITIAL")
        self.publish("B")
        self.publish("C")
        self.step(1)
        self.await_output("C-INITIAL")
        text = self.output()
        self.assertEqual(text.count("missed 1 intermediate debate selection — following latest"), 1)
        self.assertNotIn("B-INITIAL", text)
        self.assertNotIn("A-INITIAL", text.split("following latest", 1)[1])
        self.assertNotIn("C-INITIAL", text.split("following latest", 1)[0])

    def test_repeated_visits_count_selections_not_unique_debates(self):
        self.publish("A")
        self.viewer()
        self.await_output("A-INITIAL")
        for name in "BABA":
            self.publish(name)
        self.step(1)
        self.await_output("missed 3 intermediate debate selections")
        self.assertEqual(self.output().count("A-INITIAL"), 1)

    def test_continue_and_late_start_do_not_report_old_switches(self):
        for name in "ABA":
            self.publish(name)
        self.viewer()
        self.await_output("A-INITIAL")
        self.publish("A")
        self.step(1)
        self.assertNotIn("missed", self.output())
        self.assertNotIn("new debate run", self.output())
        self.assertEqual(self.output().count("A-INITIAL"), 1)
        self.publish("B")
        self.step(2)
        self.await_output("B-INITIAL")
        self.assertEqual(self.output().count("new debate run detected"), 1)

    def test_legacy_link_upgrades_without_replay(self):
        self.link.symlink_to("debate-A")
        self.viewer()
        self.await_output("A-INITIAL")
        self.publish("A")
        self.step(1)
        self.assertNotIn("new debate run", self.output())
        self.publish("B")
        self.publish("A")
        self.step(2)
        self.await_output("missed 1 intermediate debate selection")
        self.assertEqual(self.output().count("A-INITIAL"), 1)

    def test_invalid_state_stops_follower_instead_of_hiding_gap(self):
        self.publish("A")
        proc, _ = self.viewer()
        self.await_output("A-INITIAL")
        self.state.write_text("{broken")
        (self.gate / "1.go").touch()
        proc.wait(timeout=10)
        self.assertIn("selection state invalid", self.output())
        self.assertNotIn("missed", self.output())

    def test_missing_state_after_baseline_stops_follower(self):
        self.publish("A")
        proc, _ = self.viewer()
        self.await_output("A-INITIAL")
        self.state.unlink()
        (self.gate / "1.go").touch()
        proc.wait(timeout=10)
        self.assertIn("sequence disappeared", self.output())

    def test_switches_while_waiting_for_stream_are_counted(self):
        self.publish("A")
        (self.dirs["A"] / "stream-gen.log").unlink()
        self.viewer()
        self.publish("B")
        self.publish("C")
        self.step(1)
        self.await_output("C-INITIAL")
        self.assertEqual(self.output().count("missed 1 intermediate debate selection"), 1)

    def test_legacy_only_link_can_still_retarget(self):
        self.link.symlink_to("debate-A")
        self.viewer()
        self.await_output("A-INITIAL")
        self.link.unlink()
        self.link.symlink_to("debate-B")
        self.step(1)
        self.await_output("B-INITIAL")
        self.assertEqual(self.output().count("new debate run detected"), 1)

    def test_sequence_regression_is_not_a_missed_count(self):
        for name in "ABA":
            self.publish(name)
        proc, _ = self.viewer()
        self.await_output("A-INITIAL")
        record = self.snapshot() | {"sequence": 1}
        self.state.write_text(json.dumps(record))
        (self.gate / "1.go").touch()
        proc.wait(timeout=10)
        self.assertIn("sequence moved backwards", self.output())
        self.assertNotIn("missed", self.output())

    def test_paused_aba_preserves_pause_and_offset(self):
        self.publish("A")
        proc, master = self.viewer(terminal=True)
        self.await_output("A-INITIAL")
        os.write(master, b" ")
        self.await_output("[paused")
        # Hold the controller, not its pipeline (already paused by the user).
        proc.send_signal(signal.SIGSTOP)
        os.waitpid(proc.pid, os.WUNTRACED)
        self.publish("B")
        self.publish("A")
        self.append("A", "A-WHILE-PAUSED")
        proc.send_signal(signal.SIGCONT)
        self.await_output("missed 1 intermediate debate selection")
        self.assertNotIn("A-WHILE-PAUSED", self.output())
        os.write(master, b" ")
        self.await_output("[resumed]")
        self.await_output("A-WHILE-PAUSED")
        self.assertEqual(self.output().count("A-INITIAL"), 1)


if __name__ == "__main__":
    unittest.main()
