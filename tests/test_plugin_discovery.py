"""Finding dev-trio / debate-conductor scripts outside a Claude Code session (#101).

A plugin's bin/ is on PATH only inside a session with the plugin enabled, so the
drivers resolve their sibling scripts through lib/plugin-deps.sh: an override
variable, then PATH, then `claude plugin list --json`. Every run here uses a PATH
that is checked to hold none of the sibling scripts, because the machine running
the suite may well have the installed plugins' bins on its own PATH.
"""

import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPERS = [ROOT / "ralph-trio/lib/plugin-deps.sh", ROOT / "spec-trio/lib/plugin-deps.sh"]
SIBLINGS = ("ask-reviewer.sh", "ask-researcher.sh", "debate.sh")
BARE_CALL = re.compile(r'(?:^|[;&|({]|\bthen\b|\bdo\b|\bspec_run_stage\b)\s*'
                       r'(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\S+)\s+)*'
                       r'(?:ask-reviewer|ask-researcher|debate)\.sh(?=\s|$)')
DRIVERS = ["ralph-trio/bin/ralph-trio.sh", "ralph-trio/bin/ralph-meta.sh", "ralph-trio/bin/ralph-debate.sh",
           "spec-trio/bin/spec-trio.sh"]

RESOLVE = r'''
set -uo pipefail
. "$1"
cd "$2" || exit 99
rc=0
resolve_plugin_script "$3" "$4" "$5" || rc=$?
jq -cn --argjson rc "$rc" --arg script "$RESOLVED_SCRIPT" --arg source "$RESOLVED_SOURCE" \
  --arg why "$RESOLVED_WHY" '{rc:$rc,script:$script,source:$source,why:$why}'
'''

CLAUDE_STUB = r'''#!/bin/sh
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$STUB_LOG"
if [ "$1 $2" = "plugin list" ]; then
  cat "$PLUGIN_LIST"
  exit "${PLUGIN_LIST_RC:-0}"
fi
exit 0
'''

SIBLING_STUB = '#!/bin/sh\necho "$0" >> "$CALLED_LOG"\nexit 0\n'


def scrubbed_path():
    dirs = ["/usr/bin", "/bin"]
    for tool in ("jq", "git"):
        found = shutil.which(tool)
        if found and os.path.dirname(found) not in dirs:
            dirs.append(os.path.dirname(found))
    return os.pathsep.join(dirs)


class DiscoveryCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="plugin-discovery-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(os.path.realpath(self.tmp.name))
        # `claude` must be absent too: step 3 runs the one on PATH, and the stub
        # below has to be the only one the helper can reach.
        self.bare_path = scrubbed_path()
        for name in (*SIBLINGS, "claude"):
            self.assertIsNone(shutil.which(name, path=self.bare_path),
                              f"{name} is on the scrubbed PATH {self.bare_path}")
        self.stub_log = self.dir / "claude.log"
        self.called_log = self.dir / "called.log"
        self.plugin_list = self.dir / "plugin-list.json"
        self.set_plugin_list([])
        self.claude = self.executable(self.dir / "claude-bin/claude", CLAUDE_STUB)
        self.path = f"{self.claude.parent}{os.pathsep}{self.bare_path}"
        home = self.dir / "home"
        home.mkdir()
        self.env = {
            "PATH": self.path,
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"),
            "STUB_LOG": str(self.stub_log),
            "CALLED_LOG": str(self.called_log),
            "PLUGIN_LIST": str(self.plugin_list),
            "TMUX": "",
            "AGENT_TEAM": "discovery",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.com",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.com",
        }

    def executable(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)
        return path

    def plugin_tree(self, name, scripts, lib=None):
        """A fake installed plugin: bin/<scripts> stubs and an optional real lib file."""
        root = self.dir / name
        for script in scripts:
            self.executable(root / "bin" / script, SIBLING_STUB)
        if lib:
            (root / "lib").mkdir(parents=True, exist_ok=True)
            (root / "lib" / Path(lib).name).symlink_to(lib)
        return root

    def set_plugin_list(self, entries):
        self.plugin_list.write_text(json.dumps(entries))

    def claude_calls(self):
        if not self.stub_log.exists():
            return []
        return [line for line in self.stub_log.read_text().splitlines() if line]

    def called(self):
        if not self.called_log.exists():
            return []
        return self.called_log.read_text().splitlines()


def entry(install, scope="user", enabled=True, plugin="dev-trio@pandas-studio", version="1.0.0", project=None):
    item = {"id": plugin, "version": version, "scope": scope, "enabled": enabled,
            "installPath": str(install)}
    if project is not None:
        item["projectPath"] = str(project)
    return item


class ResolveTests(DiscoveryCase):
    def setUp(self):
        super().setUp()
        self.cwd = self.dir / "project"
        self.cwd.mkdir()

    def resolve(self, script="ask-reviewer.sh", var="DEV_TRIO_BIN", plugin="dev-trio@pandas-studio",
                cwd=None, env=None, helper=HELPERS[0]):
        run_env = dict(self.env, **(env or {}))
        proc = subprocess.run(["/bin/bash", "-c", RESOLVE, "resolve", str(helper), str(cwd or self.cwd),
                               var, plugin, script],
                              env=run_env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def test_copies_are_identical(self):
        self.assertEqual(HELPERS[0].read_bytes(), HELPERS[1].read_bytes())

    def test_override_wins_over_path_and_plugin_list(self):
        chosen = self.plugin_tree("chosen", ["ask-reviewer.sh"])
        on_path = self.plugin_tree("on-path", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(self.plugin_tree("listed", ["ask-reviewer.sh"]))])
        for helper in HELPERS:
            with self.subTest(helper=helper.parent.parent.name):
                got = self.resolve(helper=helper, env={"DEV_TRIO_BIN": str(chosen / "bin"),
                                                       "PATH": f"{on_path / 'bin'}:{self.path}"})
                self.assertEqual((got["rc"], got["source"]), (0, "DEV_TRIO_BIN"))
                self.assertEqual(got["script"], str(chosen / "bin/ask-reviewer.sh"))
        self.assertEqual(self.claude_calls(), [])

    def test_relative_override_becomes_absolute(self):
        self.plugin_tree("project/rel", ["ask-reviewer.sh"])
        got = self.resolve(env={"DEV_TRIO_BIN": "rel/bin"})
        self.assertEqual(got["rc"], 0)
        self.assertEqual(got["script"], str(self.cwd / "rel/bin/ask-reviewer.sh"))

    def test_override_without_the_script_is_an_error_not_a_fallthrough(self):
        empty = self.dir / "empty-bin"
        empty.mkdir()
        on_path = self.plugin_tree("on-path", ["ask-reviewer.sh"])
        got = self.resolve(env={"DEV_TRIO_BIN": str(empty), "PATH": f"{on_path / 'bin'}:{self.path}"})
        self.assertEqual(got["rc"], 2)
        self.assertEqual(got["script"], "")
        self.assertIn(f"DEV_TRIO_BIN={empty} has no executable ask-reviewer.sh", got["why"])

    def test_path_hit_does_not_start_claude(self):
        on_path = self.plugin_tree("on-path", ["ask-reviewer.sh"])
        got = self.resolve(env={"PATH": f"{on_path / 'bin'}:{self.path}"})
        self.assertEqual((got["rc"], got["source"]), (0, "PATH"))
        self.assertEqual(self.claude_calls(), [])

    def test_relative_path_entry_becomes_absolute(self):
        self.plugin_tree("project/relbin", ["ask-reviewer.sh"])
        got = self.resolve(env={"PATH": f"relbin/bin:{self.path}"})
        self.assertEqual((got["rc"], got["source"]), (0, "PATH"))
        self.assertEqual(got["script"], str(self.cwd / "relbin/bin/ask-reviewer.sh"))

    def test_plugin_list_hit_runs_in_the_callers_directory(self):
        installed = self.plugin_tree("installed", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(installed, version="0.8.8")])
        got = self.resolve()
        self.assertEqual(got["rc"], 0)
        self.assertEqual(got["script"], str(installed / "bin/ask-reviewer.sh"))
        self.assertEqual(got["source"], "plugin list: dev-trio@pandas-studio 0.8.8 (user)")
        self.assertEqual(self.claude_calls(), [f"plugin list --json|{self.cwd}"])

    def test_disabled_install_is_not_used(self):
        self.set_plugin_list([entry(self.plugin_tree("installed", ["ask-reviewer.sh"]), enabled=False)])
        got = self.resolve()
        self.assertEqual(got["rc"], 1)
        self.assertIn(f"dev-trio@pandas-studio is installed but not enabled for {self.cwd}", got["why"])

    def test_other_ids_are_ignored(self):
        tree = self.plugin_tree("installed", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(tree, plugin="dev-trio@someone-else"),
                              entry(tree, plugin="debate-conductor@pandas-studio")])
        got = self.resolve()
        self.assertEqual(got["rc"], 1)
        self.assertIn("dev-trio@pandas-studio is not installed", got["why"])

    def test_another_projects_install_does_not_apply_here(self):
        # Claude Code reports `enabled` per plugin id, so both entries say true
        # even though projA's install is not active in this directory.
        user = self.plugin_tree("user-install", ["ask-reviewer.sh"])
        other = self.plugin_tree("projA-install", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(user), entry(other, scope="project", project=self.dir / "projA")])
        got = self.resolve()
        self.assertEqual(got["script"], str(user / "bin/ask-reviewer.sh"))

    def test_only_another_projects_install(self):
        other = self.plugin_tree("projA-install", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(other, scope="local", project=self.dir / "projA")])
        got = self.resolve()
        self.assertEqual(got["rc"], 1)
        self.assertIn("no dev-trio@pandas-studio install that applies to", got["why"])

    def test_scope_ranking_for_this_directory(self):
        # installPath order runs against rank, so only the rank can pick the winner.
        trees = {name: self.plugin_tree(f"{prefix}-{name}", ["ask-reviewer.sh"])
                 for prefix, name in (("a", "managed"), ("b", "user"), ("c", "project"), ("d", "local"))}
        entries = [entry(trees["managed"], scope="managed"), entry(trees["user"]),
                   entry(trees["project"], scope="project", project=self.cwd),
                   entry(trees["local"], scope="local", project=self.cwd)]
        expected = ["local", "project", "user", "managed"]
        for winner in expected:
            with self.subTest(winner=winner):
                self.set_plugin_list(entries)
                got = self.resolve()
                self.assertEqual(got["script"], str(trees[winner] / "bin/ask-reviewer.sh"))
                entries = [e for e in entries if e["installPath"] != str(trees[winner])]

    def test_ties_break_on_install_path(self):
        b = self.plugin_tree("b", ["ask-reviewer.sh"])
        a = self.plugin_tree("a", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(b), entry(a)])
        self.assertEqual(self.resolve()["script"], str(a / "bin/ask-reviewer.sh"))

    def test_project_path_matches_through_a_symlinked_directory(self):
        link = self.dir / "link-to-project"
        link.symlink_to(self.cwd)
        project = self.plugin_tree("project-install", ["ask-reviewer.sh"])
        user = self.plugin_tree("user-install", ["ask-reviewer.sh"])
        for project_path in (self.cwd, link):
            with self.subTest(projectPath=project_path.name):
                self.set_plugin_list([entry(user), entry(project, scope="project", project=project_path)])
                got = self.resolve(cwd=link)
                self.assertEqual(got["script"], str(project / "bin/ask-reviewer.sh"))

    def test_entry_without_the_script_is_skipped(self):
        without = self.plugin_tree("local-install", ["ask-researcher.sh"])
        user = self.plugin_tree("user-install", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(without, scope="local", project=self.cwd), entry(user)])
        self.assertEqual(self.resolve()["script"], str(user / "bin/ask-reviewer.sh"))

    def test_unusable_plugin_list(self):
        cases = {
            "no claude on PATH": ({"PATH": self.bare_path}, "no claude on PATH to ask for its plugin list"),
            "non-zero exit": ({"PLUGIN_LIST_RC": "3"}, "failed (rc=3)"),
        }
        for name, (env, reason) in cases.items():
            with self.subTest(name):
                got = self.resolve(env=env)
                self.assertEqual(got["rc"], 1)
                self.assertIn(reason, got["why"])
        self.plugin_list.write_text("Error: not logged in\n")
        got = self.resolve()
        self.assertEqual(got["rc"], 1)
        self.assertIn("plugin list --json' failed (rc=0)", got["why"])

    def test_reasons_list_every_step(self):
        got = self.resolve()
        self.assertEqual(got["rc"], 1)
        self.assertTrue(got["why"].startswith("DEV_TRIO_BIN unset or empty; not on PATH; "), got["why"])

    def test_non_executable_path_match_is_skipped(self):
        # bash 3.2's `command -v` returns such a file when nothing executable matches.
        broken = self.dir / "broken-bin"
        broken.mkdir()
        (broken / "ask-reviewer.sh").write_text("#!/bin/sh\n")
        installed = self.plugin_tree("installed", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(installed)])
        got = self.resolve(env={"PATH": f"{broken}:{self.path}"})
        self.assertEqual(got["script"], str(installed / "bin/ask-reviewer.sh"))

    def test_claude_cli_is_never_asked(self):
        # CLAUDE_CLI is the planner/coder override; a wrapper there could take
        # `plugin list --json` as a prompt, so step 3 uses the claude on PATH.
        decoy_log = self.dir / "decoy.log"
        decoy = self.executable(self.dir / "decoy/claude", f'#!/bin/sh\necho "$*" >> "{decoy_log}"\nexit 1\n')
        installed = self.plugin_tree("installed", ["ask-reviewer.sh"])
        self.set_plugin_list([entry(installed)])
        got = self.resolve(env={"CLAUDE_CLI": str(decoy)})
        self.assertEqual(got["script"], str(installed / "bin/ask-reviewer.sh"))
        self.assertFalse(decoy_log.exists())
        self.assertEqual(self.claude_calls(), [f"plugin list --json|{self.cwd}"])
        self.assertIsNone(shutil.which("claude", path=self.bare_path))

    def test_empty_version_and_scope_keep_the_label_readable(self):
        installed = self.plugin_tree("installed", ["ask-reviewer.sh"])
        item = entry(installed, version="")
        self.set_plugin_list([item])
        self.assertEqual(self.resolve()["source"], "plugin list: dev-trio@pandas-studio ? (user)")


class DriverTests(DiscoveryCase):
    """Each driver, started with no sibling script on PATH."""

    def setUp(self):
        super().setUp()
        self.repo = self.dir / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        (self.repo / "seed.txt").write_text("seed\n")
        self.git("add", "seed.txt")
        self.git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "ralph iter 1: seed")
        (self.repo / "BACKLOG.md").write_text("- [ ] change the work file\n")
        (self.repo / "spec.md").write_text("# Spec\n\nThe work file changes.\n")
        planner = self.executable(self.dir / "planner", (
            "#!/bin/sh\necho '## Plan'\necho '- Append a line to work.txt (spec: the work file changes).'\n"
            "echo '<allowed-paths>'\necho 'work.txt'\necho '</allowed-paths>'\n"))
        coder = self.executable(self.dir / "coder", "#!/bin/sh\necho change >> work.txt\necho 'Appended a line.'\n")
        self.env.update(PLANNER_CLI=str(planner), CODER_CLI=str(coder))
        self.dev = self.plugin_tree("dev-trio", ["ask-reviewer.sh", "ask-researcher.sh"],
                                    lib=ROOT / "dev-trio/lib/review-result.sh")
        self.debate = self.plugin_tree("debate-conductor", ["debate.sh"],
                                       lib=ROOT / "debate-conductor/lib/debate-result.sh")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True,
                       env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                                GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.com",
                                GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.com"))

    DRIVERS = {
        "ralph-trio": ("DEV_TRIO_BIN", "ask-reviewer.sh",
                       ["ralph-trio/bin/ralph-trio.sh", "--max-iter", "1", "--no-research", "--backlog", "BACKLOG.md"]),
        "spec-trio": ("DEV_TRIO_BIN", "ask-reviewer.sh",
                      ["spec-trio/bin/spec-trio.sh", "--max-iter", "1", "--no-research", "--spec", "spec.md",
                       "--test-cmd", "true", "--backlog", "BACKLOG.md"]),
        "ralph-meta": ("DEV_TRIO_BIN", "ask-reviewer.sh",
                       ["ralph-trio/bin/ralph-meta.sh", "--since", "1 hour ago"]),
        "ralph-debate": ("DEBATE_CONDUCTOR_BIN", "debate.sh",
                         ["ralph-trio/bin/ralph-debate.sh", "--max-iter", "1", "--backlog", "BACKLOG.md"]),
    }

    def run_driver(self, name, env=None):
        argv = self.DRIVERS[name][2]
        return subprocess.run([str(ROOT / argv[0]), *argv[1:]], cwd=self.repo, env=dict(self.env, **(env or {})),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)

    def plugin_dir(self, var):
        return self.dev if var == "DEV_TRIO_BIN" else self.debate

    def test_missing_sibling_names_every_step(self):
        for name, (var, script, _argv) in self.DRIVERS.items():
            with self.subTest(driver=name):
                proc = self.run_driver(name)
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertIn(f"requires {script}", proc.stderr)
                self.assertIn(f"{var} unset or empty; not on PATH;", proc.stderr)
                self.assertIn(f"or set {var}=", proc.stderr)
                self.assertEqual(self.called(), [])

    def test_override_runs_the_sibling(self):
        for name, (var, script, _argv) in self.DRIVERS.items():
            with self.subTest(driver=name):
                self.called_log.unlink(missing_ok=True)
                self.setUp_fresh_repo()
                bin_dir = self.plugin_dir(var) / "bin"
                proc = self.run_driver(name, {var: str(bin_dir)})
                self.assertIn(str(bin_dir / script), self.called(), proc.stderr)
        # Every sibling came from the override: `claude plugin list` never ran.
        self.assertFalse([c for c in self.claude_calls() if c.startswith("plugin list")])

    def test_override_without_the_script_stops_the_driver(self):
        empty = self.dir / "empty-bin"
        empty.mkdir()
        proc = self.run_driver("ralph-meta", {"DEV_TRIO_BIN": str(empty)})
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn(f"ERROR: ralph-meta: DEV_TRIO_BIN={empty} has no executable ask-reviewer.sh", proc.stderr)

    def test_override_runs_the_researcher(self):
        # The planner asks for research; both drivers must run the resolved
        # ask-researcher.sh (--autoship: no reviewer stage).
        planner = self.executable(self.dir / "research-planner", (
            "#!/bin/sh\necho '## Plan'\necho '- Append a line to work.txt (spec: the work file changes).'\n"
            "echo '<allowed-paths>'\necho 'work.txt'\necho '</allowed-paths>'\n"
            "echo '## NEED RESEARCH'\necho '- What does the work file hold?'\n"))
        cases = {
            "ralph-trio": ["ralph-trio/bin/ralph-trio.sh", "--max-iter", "1", "--autoship", "--backlog", "BACKLOG.md"],
            "spec-trio": ["spec-trio/bin/spec-trio.sh", "--max-iter", "1", "--autoship", "--spec", "spec.md",
                          "--test-cmd", "true", "--backlog", "BACKLOG.md"],
        }
        for name, argv in cases.items():
            with self.subTest(driver=name):
                self.called_log.unlink(missing_ok=True)
                self.setUp_fresh_repo()
                proc = subprocess.run([str(ROOT / argv[0]), *argv[1:]], cwd=self.repo,
                                      env=dict(self.env, PLANNER_CLI=str(planner), DEV_TRIO_BIN=str(self.dev / "bin")),
                                      stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
                self.assertIn(str(self.dev / "bin/ask-researcher.sh"), self.called(), proc.stderr)

    def test_no_driver_runs_a_sibling_by_bare_name(self):
        # Driver runs reach only some call sites; this catches the rest. A name in
        # command position (after env assignments, or as spec_run_stage's command)
        # would be looked up on PATH again. Checked to flag all 11 call sites on
        # main f6e53b1.
        for rel in DRIVERS:
            for number, line in enumerate((ROOT / rel).read_text().splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                with self.subTest(file=rel, line=number):
                    self.assertIsNone(BARE_CALL.search(line), line)

    def test_plugin_list_supplies_the_sibling(self):
        self.set_plugin_list([entry(self.dev, version="9.9.9")])
        proc = self.run_driver("ralph-meta")
        self.assertIn(str(self.dev / "bin/ask-reviewer.sh"), self.called(), proc.stderr)
        self.assertEqual(self.claude_calls(), [f"plugin list --json|{self.repo}"])

    def setUp_fresh_repo(self):
        # Drivers consume the backlog; each subtest starts from an open task.
        (self.repo / "BACKLOG.md").write_text("- [ ] change the work file\n")
        for workspace in (".ralph-trio", ".spec-trio"):
            shutil.rmtree(self.repo / workspace, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
