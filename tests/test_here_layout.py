"""team-3pane.sh / team-layout.sh --here against a stateful fake tmux (#100)."""

import json
import os
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


class HereLayoutTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "tmux").write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE} \"$@\"\n")
        (tools / "tmux").chmod(0o755)
        self.state_path = self.root / "tmux.json"
        self.tools = tools

    def tearDown(self):
        self._tmp.cleanup()

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

    def test_a_dead_runs_lock_is_taken_over(self):
        # A run killed mid-build leaves its lock behind; a later run must take
        # it over, not wait on it.
        self.state()
        r = self.run_here("debate-3pane")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([p for p in self.root.iterdir() if p.name.startswith("agent-team-layout.")], [],
                         "the lock is released at exit")
        dead = subprocess.Popen(["true"])
        dead.wait()
        name = subprocess.run(
            ["bash", "-c", 'printf "%s %s" "${TMUX%%,*}" "@0" | cksum | cut -d" " -f1'],
            env={"TMUX": "fake,1,0", "PATH": os.environ["PATH"]}, capture_output=True, text=True, check=True)
        stale = self.root / f"agent-team-layout.{os.getuid()}.{name.stdout.strip()}"
        stale.mkdir()
        (stale / "pid").write_text(f"{dead.pid}\n")
        self.state()
        r = self.run_here("debate-3pane")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.window()["panes"]), 3)
        self.assertFalse(stale.exists())

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
