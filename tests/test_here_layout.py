"""team-3pane.sh / team-layout.sh --here against a stateful fake tmux (#100)."""

import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAKE = Path(__file__).resolve().parent / "fake_tmux.py"

SCRIPTS = {
    "debate-3pane": (ROOT / "debate-conductor/bin/team-3pane.sh",
                     {"DEBATE_CONDUCTOR_PM_HOST": "claude"}),
    "dev-trio-layout": (ROOT / "dev-trio/bin/team-layout.sh",
                        {"DEV_TRIO_PM_HOST": "claude"}),
}
TEAMS = {"debate-3pane": "debate-conductor", "dev-trio-layout": "dev-trio"}



def non_atomic_mkdir(tools):
    """A mkdir that always succeeds, like uutils' under a race (Ubuntu 26.04:
    two concurrent mkdirs both succeeded in 131 of 200 runs)."""
    real = shutil.which("mkdir")
    path = tools / "mkdir"
    path.write_text(f'#!/bin/sh\nexec {shlex.quote(real)} -p "$@"\n')
    path.chmod(0o755)
    return path

class HereLayoutTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # A cleanup, not tearDown: cleanups run last-registered first, so every
        # run a test started is reaped (popen_here) before the fixture goes.
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "tmux").write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE} \"$@\"\n")
        (tools / "tmux").chmod(0o755)
        self.state_path = self.root / "tmux.json"
        self.tools = tools

    # ---- fixture ---------------------------------------------------------

    def state(self, windows=None, current="%0", nxt=1, fail=None, delay=None):
        s = {"current": current, "next": nxt, "calls": [], "fail": fail or {}, "delay": delay or {},
             "windows": windows or {"@0": {"options": {}, "panes": ["%0"]}}}
        self.state_path.write_text(json.dumps(s))

    def read(self):
        return json.loads(self.state_path.read_text())

    def reset_calls(self):
        s = self.read()
        s["calls"], s["counts"], s["splits"], s["fail"] = [], {}, [], {}
        self.state_path.write_text(json.dumps(s))

    def run_here(self, layout, *args, pane="%0", **env):
        script, host_env = SCRIPTS[layout]
        full = {k: v for k, v in os.environ.items()
                if k not in ("TMUX_PANE", "AGENT_TEAM") and not k.startswith(("DEV_TRIO_", "DEBATE_CONDUCTOR_"))}
        full.update(host_env)
        full.update(PATH=str(self.tools) + os.pathsep + os.environ["PATH"], TMUX="fake,1,0",
                    FAKE_TMUX_STATE=str(self.state_path), TMPDIR=str(self.root))
        if pane is not None:
            full["TMUX_PANE"] = pane
        full.update(env)
        return subprocess.run(["bash", str(script), "--here", *args], cwd=self.root, env=full,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)

    def tmux(self, *args):
        """Change the fake window the way a user would, through the fake itself."""
        env = dict(os.environ, FAKE_TMUX_STATE=str(self.state_path))
        subprocess.run([str(self.tools / "tmux"), *args], env=env, check=True,
                       stdin=subprocess.DEVNULL)

    def built(self, layout):
        """A fresh one-pane window with LAYOUT built in it: returns its pane ids."""
        self.state()
        r = self.run_here(layout)
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.window()["panes"]

    def window(self, wid="@0"):
        return self.read()["windows"][wid]

    def assert_targeted(self, allow_untargeted_lookup=False):
        for call in self.read()["calls"]:
            if allow_untargeted_lookup and call == ["display-message", "-p", "#{pane_id}"]:
                continue
            self.assertIn("-t", call, call)

    # ---- cases -------------------------------------------------------------

    def test_fresh_window_builds_and_records(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state()
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 0, r.stderr)
                win = self.window()
                self.assertEqual(win["panes"], ["%0", "%1", "%2"])
                self.assertEqual(win["options"]["@team-name"], TEAMS[layout])
                self.assertEqual(win["options"]["@team-layout"], f"{layout} %0 %1 %2")
                self.assert_targeted()

    def test_split_geometry(self):
        self.state()
        self.run_here("debate-3pane")
        self.assertEqual([(s["target"], s["dir"]) for s in self.read()["splits"]],
                         [("%0", "h"), ("%1", "h")])
        self.assertEqual(self.window()["active"], "%0")
        self.state()
        self.run_here("dev-trio-layout")
        self.assertEqual([(s["target"], s["dir"]) for s in self.read()["splits"]],
                         [("%0", "h"), ("%1", "v")])
        self.assertEqual(self.window()["active"], "%0")

    def test_rerun_of_complete_layout_is_a_noop(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state()
                self.run_here(layout)
                self.reset_calls()
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("already present", r.stdout)
                self.assertNotIn("split-window", [c[0] for c in self.read()["calls"]])
                self.assert_targeted()

    def test_both_created_panes_closed_builds_again(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                main, a, b = self.built(layout)
                self.tmux("kill-pane", "-t", a)
                self.tmux("kill-pane", "-t", b)
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.window()["options"]["@team-layout"], f"{layout} %0 %3 %4")

    def test_one_created_pane_closed_is_refused(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                main, a, b = self.built(layout)
                self.tmux("kill-pane", "-t", a)
                self.reset_calls()
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 2)
                self.assertIn(f"tmux kill-pane -t {b}", r.stderr)
                self.assertNotIn("split-window", [c[0] for c in self.read()["calls"]])

    def test_main_pane_moved_away_is_refused(self):
        # The PM pane is broken out into its own window; re-run from a side pane.
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                main, a, b = self.built(layout)
                self.tmux("break-pane", "-s", main)
                r = self.run_here(layout, pane=a)
                self.assertEqual(r.returncode, 2)
                self.assertIn(f"tmux kill-pane -t {b}", r.stderr)

    def test_hand_split_untagged_window_is_refused(self):
        self.state(windows={"@0": {"options": {}, "panes": ["%0", "%7"]}}, nxt=8)
        r = self.run_here("dev-trio-layout")
        self.assertEqual(r.returncode, 2)
        self.assertIn("tmux kill-pane -t %7", r.stderr)
        self.assertEqual(self.window()["panes"], ["%0", "%7"])
        self.assertNotIn("@team-name", self.window()["options"])

    def test_other_team_is_refused_even_in_one_pane(self):
        for panes in (["%0"], ["%0", "%1", "%2"]):
            with self.subTest(panes=panes):
                self.state(windows={"@0": {"options": {"@team-name": "dev-trio"}, "panes": panes}}, nxt=3)
                r = self.run_here("debate-3pane")
                self.assertEqual(r.returncode, 2)
                self.assertIn("belongs to team dev-trio", r.stderr)
                self.assertIn("tmux set-option -wu -t %0 @team-name", r.stderr)
                self.assertEqual(self.window()["options"], {"@team-name": "dev-trio"})

    def test_same_team_other_layout_is_refused(self):
        self.state(windows={"@0": {"options": {"@team-name": "shared",
                                               "@team-layout": "dev-trio-layout %0 %1 %2"},
                                   "panes": ["%0", "%1", "%2"]}}, nxt=3)
        r = self.run_here("debate-3pane", "-n", "shared")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a complete debate-3pane layout", r.stderr)

    def test_failed_second_split_leaves_no_record_and_rerun_refuses(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(fail={"split-window": 2})
                r = self.run_here(layout)
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn("@team-layout", self.window()["options"])
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 2)
                self.assertIn("tmux kill-pane -t %1", r.stderr)

    def test_failed_send_keys_leaves_no_record(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(fail={"send-keys": 2})
                r = self.run_here(layout)
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn("@team-layout", self.window()["options"])
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 2)
                self.assertIn("tmux kill-pane -t %1", r.stderr)

    def test_window_changed_during_build_is_not_recorded(self):
        # Another run split the window meanwhile: the final check refuses to record.
        # list-panes runs twice: in the guard, then in the stamp's check. The
        # wrapper adds a stray pane to the second answer only.
        self.state()
        fake = self.tools / "tmux"
        fake.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = list-panes ]; then\n"
            f"  n=$(cat {self.root}/lp 2>/dev/null || echo 0); n=$((n+1)); echo $n > {self.root}/lp\n"
            f"  [ $n -ge 2 ] && {{ {sys.executable} {FAKE} \"$@\"; echo %99; exit 0; }}\n"
            "fi\n"
            f"exec {sys.executable} {FAKE} \"$@\"\n")
        r = self.run_here("debate-3pane")
        self.assertEqual(r.returncode, 2)
        self.assertIn("changed while the layout was being built", r.stderr)
        self.assertNotIn("@team-layout", self.window()["options"])

    def test_failed_tag_read_changes_nothing(self):
        # errexit is off inside the guard; a failed read must not look like "untagged".
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(windows={"@0": {"options": {"@team-name": "someone-else"}, "panes": ["%0"]}},
                           fail={"show-options": 1})
                r = self.run_here(layout)
                self.assertEqual(r.returncode, 1)
                self.assertIn("cannot read the state", r.stderr)
                self.assertEqual(self.window()["options"], {"@team-name": "someone-else"})
                self.assertEqual(self.window()["panes"], ["%0"])

    def test_tagged_one_pane_window_without_record_builds(self):
        self.state(windows={"@0": {"options": {"@team-name": "dev-trio"}, "panes": ["%0"]}})
        r = self.run_here("dev-trio-layout")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.window()["options"]["@team-layout"], "dev-trio-layout %0 %1 %2")

    def test_unset_tmux_pane_falls_back_to_current_pane(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(windows={"@0": {"options": {}, "panes": ["%0"]},
                                    "@1": {"options": {}, "panes": ["%5"]}}, current="%5", nxt=6)
                r = self.run_here(layout, pane=None)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.window("@1")["panes"], ["%5", "%6", "%7"])
                self.assertEqual(self.window("@0")["panes"], ["%0"])
                self.assert_targeted(allow_untargeted_lookup=True)

    def test_tmux_pane_wins_over_the_current_pane(self):
        # A window switch mid-run must not move the layout: everything targets TMUX_PANE.
        self.state(windows={"@0": {"options": {}, "panes": ["%0"]},
                            "@1": {"options": {}, "panes": ["%5"]}}, current="%5", nxt=6)
        r = self.run_here("dev-trio-layout", pane="%0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.window("@0")["panes"], ["%0", "%6", "%7"])
        self.assertEqual(self.window("@1")["panes"], ["%5"])
        self.assertEqual(self.window("@1")["options"], {})


    # ---- round-2 review of #180 --------------------------------------------

    def start_here(self, layout):
        script, host_env = SCRIPTS[layout]
        full = {k: v for k, v in os.environ.items()
                if k not in ("TMUX_PANE", "AGENT_TEAM") and not k.startswith(("DEV_TRIO_", "DEBATE_CONDUCTOR_"))}
        full.update(host_env, PATH=str(self.tools) + os.pathsep + os.environ["PATH"], TMUX="fake,1,0",
                    FAKE_TMUX_STATE=str(self.state_path), TMPDIR=str(self.root), TMUX_PANE="%0")
        return subprocess.Popen(["bash", str(script), "--here"], cwd=self.root, env=full, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)

    def test_concurrent_runs_build_one_layout(self):
        # Both see one pane; the slow first split keeps them overlapping. The
        # lock makes the second wait, then find the layout complete.
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(delay={"split-window": 0.4})
                runs = [self.start_here(layout), self.start_here(layout)]
                results = [(p.communicate(timeout=60) and p.returncode, *p.communicate()) for p in runs]
                for rc, out, err in results:
                    self.assertEqual(rc, 0, err)
                self.assertEqual(len(self.window()["panes"]), 3)
                self.assertEqual(sum("already present" in out for _, out, _ in results), 1)
                self.assertEqual([c[0] for c in self.read()["calls"]].count("split-window"), 2)

    def test_concurrent_runs_build_one_layout_with_a_non_atomic_mkdir(self):
        # The pid file, created with noclobber, is what the lock owns; a mkdir
        # that reports success for an existing directory must not admit both.
        shim = non_atomic_mkdir(self.tools)
        try:
            self.test_concurrent_runs_build_one_layout()
        finally:
            shim.unlink()

    # ---- #222: a held lock is waited out and reported, never taken over -----

    # here_lock polls 100 times and sleeps between polls: a lock it waited out
    # costs exactly 99 sleeps.
    WAITED_OUT = 99

    def lock_path(self, wid="@0", tmpdir=None):
        name = subprocess.run(
            ["bash", "-c", 'printf "%s %s" "${TMUX%%,*}" "$1" | cksum | cut -d" " -f1', "_", wid],
            env={"TMUX": "fake,1,0", "PATH": os.environ["PATH"]}, capture_output=True, text=True, check=True)
        return Path(tmpdir or self.root) / f"agent-team-layout.{os.getuid()}.{name.stdout.strip()}"

    @staticmethod
    def bash_q(text):
        """What bash's printf %q prints for `text`, computed outside the scripts."""
        return subprocess.run(["bash", "-c", 'printf %q "$1"', "_", text], capture_output=True,
                              text=True, check=True).stdout

    @staticmethod
    def dead_pid():
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def plant_lock(self, content, wid="@0", tmpdir=None):
        lock = self.lock_path(wid, tmpdir)
        shutil.rmtree(lock, ignore_errors=True)
        lock.mkdir()
        if content is not None:
            (lock / "pid").write_text(content)
        return lock

    @staticmethod
    def snapshot(lock):
        """The lock as a later run must leave it: inodes, and the pid file's bytes when readable."""
        pid = lock / "pid"
        content = None
        if pid.is_file() and not pid.is_symlink() and os.access(pid, os.R_OK):
            content = pid.read_bytes()
        return (os.lstat(lock).st_ino, os.lstat(pid).st_ino if os.path.lexists(pid) else None, content)

    def sleep_tools(self):
        """A `sleep` that counts the calls a run makes (one line per call in $SLEEP_LOG)."""
        tools = self.root / "sleep tools"
        if not tools.exists():
            tools.mkdir()
            (tools / "sleep").write_text(
                "#!/bin/sh\n"
                '[ -z "${SLEEP_LOG:-}" ] || echo "$*" >> "$SLEEP_LOG"\n'
                f'exec {shlex.quote(shutil.which("sleep"))} "$@"\n')
            (tools / "sleep").chmod(0o755)
        return tools

    @staticmethod
    def sleeps(log):
        return len(log.read_text().splitlines()) if log.exists() else 0

    def popen_here(self, layout, pane="%0", path=(), **env):
        script, host_env = SCRIPTS[layout]
        full = {k: v for k, v in os.environ.items()
                if k not in ("TMUX_PANE", "AGENT_TEAM") and not k.startswith(("DEV_TRIO_", "DEBATE_CONDUCTOR_"))}
        full.update(host_env, TMUX="fake,1,0", FAKE_TMUX_STATE=str(self.state_path), TMPDIR=str(self.root),
                    TMUX_PANE=pane,
                    PATH=os.pathsep.join([*map(str, path), str(self.tools), os.environ["PATH"]]))
        full.update(env)
        # Its own session, so every process of the run can be killed at once:
        # a subshell blocked opening a FIFO would otherwise keep the pipes open.
        proc = subprocess.Popen(["bash", str(script), "--here"], cwd=self.root, env=full, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                start_new_session=True)
        self.addCleanup(self.reap, proc)
        return proc

    @staticmethod
    def kill_group(proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def reap(self, proc):
        # Only a run not yet reaped: until it is waited for, its PID (and so
        # its process group id) cannot be reused, even if it already exited
        # and a descendant still holds the pipes. Once reaped, the id may name
        # an unrelated group.
        if proc.returncode is not None:
            return
        self.kill_group(proc)
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    def finish(self, proc, timeout=40):
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill_group(proc)
            try:
                _, err = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                err = "(stderr not drained)"
            self.fail(f"--here did not finish within {timeout}s; stderr:\n{err}")
        return proc.returncode, out, err

    def splits(self):
        return [c[0] for c in self.read()["calls"]].count("split-window")

    def held_lines(self, lock):
        return [f"error: the layout lock for this window ({self.bash_q(str(lock))}) is still held: another "
                "layout run is setting up this window, or one was killed before it could release the lock.",
                "Retry when it finishes, or open a new tmux window (prefix + c) and run this there; "
                "remove the lock once no layout run for this window is active."]

    def gate_tools(self, name):
        """`cat` and `tmux` shims that force the interleave #222 describes, with
        bounded waits (a timeout leaves a timeout.* marker: a harness failure).

        cat: the first two reads of a pid file capture its content, then wait
        until both have read; the second then also waits until the first run
        reached the protected section (entered.*), and only then returns what
        it captured.
        tmux: a run's first call after here_lock (anything but display-message;
        measured: the only calls before it are two display-message) marks
        entered.<RUN_ID> and waits for the other run's mark.
        """
        tools = self.root / f"gate tools {name}"
        tools.mkdir()
        gate = self.root / f"gate {name}"
        gate.mkdir()
        real_sleep = shlex.quote(shutil.which("sleep"))
        wait = ('wait_for() { i=0; while ! eval "$1"; do i=$((i + 1)); '
                'if [ "$i" -ge 200 ]; then : > "$GATE/timeout.$2"; return 1; fi; '
                f'{real_sleep} 0.05; done; }}\n')
        (tools / "cat").write_text(
            "#!/bin/sh\n"
            f"real={shlex.quote(shutil.which('cat'))}\n"
            'last=; for a do last=$a; done\n'
            'case "$last" in */pid) ;; *) exec "$real" "$@" ;; esac\n'
            'content=$("$real" "$@"); rc=$?\n'
            'n=1; while ! (set -C; : > "$GATE/read.$n") 2>/dev/null; do\n'
            '  n=$((n + 1)); [ "$n" -le 50 ] || { : > "$GATE/timeout.read-marker"; exec "$real" "$@"; }\n'
            'done\n'
            + wait +
            'if [ "$n" -le 2 ]; then\n'
            '  wait_for \'[ -e "$GATE/read.2" ]\' barrier.$n\n'
            '  [ "$n" != 2 ] || wait_for \'ls "$GATE" | grep -q "^entered\\."\' release\n'
            'fi\n'
            '[ -z "$content" ] || printf "%s\\n" "$content"\n'
            'exit "$rc"\n')
        (tools / "tmux").write_text(
            "#!/bin/sh\n"
            f"real={shlex.quote(str(self.tools / 'tmux'))}\n"
            'case "$1" in display-message) exec "$real" "$@" ;; esac\n'
            + wait +
            'if [ ! -e "$GATE/entered.$RUN_ID" ]; then\n'
            '  : > "$GATE/entered.$RUN_ID"\n'
            '  wait_for \'[ "$(ls "$GATE" | grep -c "^entered\\.")" -ge 2 ]\' tmux.$RUN_ID'
            ' && : > "$GATE/both"\n'
            'fi\n'
            'exec "$real" "$@"\n')
        for shim in ("cat", "tmux"):
            (tools / shim).chmod(0o755)
        return tools, gate

    def test_two_runs_that_saw_the_same_dead_owner_never_both_enter(self):
        # #222: both waiters read the same dead PID; the first removed the lock
        # and took it, then the second removed the first's live lock and took
        # it too. Now neither reads the record nor removes anything: both wait
        # the lock out, report it and leave it as it was.
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state()
                tools, gate = self.gate_tools(layout)
                lock = self.plant_lock(f"{self.dead_pid()}\n")
                before = self.snapshot(lock)
                logs = {run_id: self.root / f"sleeps {layout} {run_id}" for run_id in ("A", "B")}
                runs = [self.popen_here(layout, path=[tools, self.sleep_tools()], GATE=str(gate),
                                        RUN_ID=run_id, SLEEP_LOG=str(log))
                        for run_id, log in logs.items()]
                results = [self.finish(p, timeout=60) for p in runs]
                marks = sorted(p.name for p in gate.iterdir())
                self.assertEqual([m for m in marks if m.startswith("timeout.")], [], "harness timeout")
                self.assertNotIn("both", marks, "both runs were inside the protected section at once")
                self.assertEqual(marks, [])
                for rc, _, err in results:
                    self.assertEqual(rc, 2, err)
                    self.assertEqual(err.splitlines(), self.held_lines(lock))
                self.assertEqual([self.sleeps(log) for log in logs.values()], [self.WAITED_OUT] * 2)
                self.assertEqual(self.snapshot(lock), before)
                self.assertEqual(self.splits(), 0)

    def test_a_held_lock_is_waited_out_reported_and_left_alone(self):
        # Whatever the lock records, it is not interpreted: every case waits
        # out the limit (about 10 s, so all run at once, each in its own
        # window and so on its own lock), prints the same report and leaves
        # the lock as it was.
        mkdir_tools = self.root / "mkdir tools"
        mkdir_tools.mkdir()
        non_atomic_mkdir(mkdir_tools)
        cases = {
            "dead owner": (f"{self.dead_pid()}\n", ()),
            "live owner": (f"{os.getpid()}\n", ()),
            "empty pid file": ("", ()),
            "no pid file": (None, ()),
            "not a PID": ("12ab\n", ()),
            "symlinked pid file": ("symlink", ()),
            # noclobber does not refuse a FIFO: opening it would block the claim.
            "FIFO pid file, non-atomic mkdir": ("fifo", (mkdir_tools,)),
            "dead owner, non-atomic mkdir": (f"{self.dead_pid()}\n", (mkdir_tools,)),
        }
        runs = [(name, layout) for name in cases for layout in SCRIPTS]
        self.state(windows={f"@{i}": {"options": {}, "panes": [f"%{i}"]} for i in range(len(runs))},
                   nxt=len(runs))
        procs = []
        for i, (name, layout) in enumerate(runs):
            content, path = cases[name]
            lock = self.plant_lock(None if content in ("symlink", "fifo") else content, wid=f"@{i}")
            if content == "symlink":
                (self.root / f"pid target {i}").write_text(f"{os.getpid()}\n")
                (lock / "pid").symlink_to(self.root / f"pid target {i}")
            elif content == "fifo":
                os.mkfifo(lock / "pid")
            log = self.root / f"sleeps {i}"
            procs.append((name, layout, lock, log, self.snapshot(lock),
                          self.popen_here(layout, pane=f"%{i}", path=[*path, self.sleep_tools()],
                                          SLEEP_LOG=str(log))))
        for name, layout, lock, log, before, proc in procs:
            with self.subTest(case=name, layout=layout):
                rc, _, err = self.finish(proc)
                self.assertEqual(rc, 2, err)
                self.assertEqual(err.splitlines(), self.held_lines(lock))
                self.assertEqual(self.sleeps(log), self.WAITED_OUT)
                self.assertEqual(self.snapshot(lock), before)
        self.assertEqual(self.splits(), 0)

    def test_a_new_window_is_not_blocked_by_another_windows_lock(self):
        for layout in SCRIPTS:
            with self.subTest(layout=layout):
                self.state(windows={"@0": {"options": {}, "panes": ["%0"]},
                                    "@1": {"options": {}, "panes": ["%1"]}}, nxt=2)
                lock = self.plant_lock(f"{self.dead_pid()}\n")
                before = self.snapshot(lock)
                rc, _, err = self.finish(self.popen_here(layout, pane="%1"))
                self.assertEqual(rc, 0, err)
                self.assertEqual(len(self.window("@1")["panes"]), 3)
                self.assertEqual(self.window("@0")["panes"], ["%0"])
                self.assertEqual(self.snapshot(lock), before)

    def test_the_lock_path_is_quoted_in_the_report(self):
        # A TMPDIR with a space, a quote and a control character: the report is
        # exactly the expected text with bash's own %q of the path, and no raw
        # control character reaches the terminal.
        tmpdir = self.root / "tmp a b'c\x01d"
        tmpdir.mkdir()
        self.state(windows={f"@{i}": {"options": {}, "panes": [f"%{i}"]} for i in range(len(SCRIPTS))},
                   nxt=len(SCRIPTS))
        procs = []
        for i, layout in enumerate(SCRIPTS):
            lock = self.plant_lock(f"{self.dead_pid()}\n", wid=f"@{i}", tmpdir=tmpdir)
            procs.append((layout, lock, self.popen_here(layout, pane=f"%{i}", TMPDIR=str(tmpdir))))
        for layout, lock, proc in procs:
            with self.subTest(layout=layout):
                rc, _, err = self.finish(proc)
                self.assertEqual(rc, 2, err)
                self.assertNotIn("\x01", err)
                self.assertEqual(err.splitlines(), self.held_lines(lock))

    def test_new_session_layout_is_recorded(self):
        for layout, session in (("debate-3pane", "debate-conductor"), ("dev-trio-layout", "dev-trio")):
            with self.subTest(layout=layout):
                self.state(windows={"@0": {"options": {}, "panes": ["%0"]}})
                script, host_env = SCRIPTS[layout]
                full = {k: v for k, v in os.environ.items()
                        if k not in ("TMUX_PANE", "AGENT_TEAM", "TMUX")
                        and not k.startswith(("DEV_TRIO_", "DEBATE_CONDUCTOR_"))}
                full.update(host_env, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                            FAKE_TMUX_STATE=str(self.state_path), TMPDIR=str(self.root))
                args = ["--new-session", "--no-attach"] if layout == "debate-3pane" else ["--no-attach"]
                r = subprocess.run(["bash", str(script), *args], cwd=self.root, env=full, text=True,
                                   capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(r.returncode, 0, r.stderr)
                wid, win = next((w, v) for w, v in self.read()["windows"].items() if v.get("session") == session)
                self.assertEqual(win["options"]["@team-layout"], f"{layout} {' '.join(win['panes'])}")
                r = self.run_here(layout, pane=win["panes"][0])
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("already present", r.stdout)


if __name__ == "__main__":
    unittest.main()
