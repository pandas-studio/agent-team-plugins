"""scripts/check-version-bump.py against throwaway repositories (#151)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check-version-bump.py"


class VersionBumpTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.plugin("alpha", "1.0.0", codex=True)
        self.runtime("0.1.0")
        self.write("README.md", "top\n")
        self.commit("base")
        self.git("branch", "base")

    def tearDown(self):
        self._tmp.cleanup()

    # ---- fixture helpers ---------------------------------------------------

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True,
                       capture_output=True, stdin=subprocess.DEVNULL)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def manifest(self, plugin, version, kind="claude"):
        self.write(f"{plugin}/.{kind}-plugin/plugin.json",
                   json.dumps({"name": plugin, "version": version}) + "\n")

    def plugin(self, name, version, codex=False):
        self.manifest(name, version)
        if codex:
            self.manifest(name, version, "codex")
        self.write(f"{name}/bin/tool.sh", "echo 1\n")
        self.write(f"{name}/tests/test_tool.sh", "true\n")

    def runtime(self, version, **override):
        versions = {k: version for k in ("manifest", "pyproject", "dunder", "lock")}
        versions.update(override)
        self.manifest("runtime", versions["manifest"])
        self.write("runtime/pyproject.toml",
                   f'[project]\nname = "agent-team-graph"\nversion = "{versions["pyproject"]}"\n'
                   '\n[tool.ruff]\ntarget-version = "py312"\n')
        self.write("runtime/src/agent_team_graph/__init__.py",
                   f'__version__ = "{versions["dunder"]}"\n')
        self.write("runtime/uv.lock",
                   'version = 1\n\n[[package]]\nname = "agent-team-graph"\n'
                   f'version = "{versions["lock"]}"\nsource = {{ editable = "." }}\n')

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def run_check(self, base="base", **env):
        full = {k: v for k, v in os.environ.items() if k not in ("CI", "VERSION_BUMP_BASE", "VERSION_BUMP_DIRECT")}
        if base is not None:
            full["VERSION_BUMP_BASE"] = base
        full.update(env)
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root)],
                              capture_output=True, text=True, env=full,
                              stdin=subprocess.DEVNULL)

    def assert_rc(self, result, rc, needle=None):
        self.assertEqual(result.returncode, rc, result.stderr)
        if needle is not None:
            self.assertIn(needle, result.stderr)

    # ---- cases -------------------------------------------------------------

    def test_no_change_passes(self):
        self.assert_rc(self.run_check(), 0)

    def test_bin_change_without_bump_fails(self):
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.commit("change")
        self.assert_rc(self.run_check(), 1, "alpha: changed (alpha/bin/tool.sh)")

    def test_uncommitted_and_untracked_changes_count(self):
        self.write("alpha/bin/new.sh", "echo new\n")
        self.assert_rc(self.run_check(), 1, "alpha/bin/new.sh")

    def test_bump_in_every_manifest_passes(self):
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "1.0.1")
        self.manifest("alpha", "1.0.1", "codex")
        self.commit("change")
        self.assert_rc(self.run_check(), 0)

    def test_bump_in_one_manifest_fails(self):
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "1.0.1")
        self.commit("change")
        self.assert_rc(self.run_check(), 1, "alpha: versions disagree")

    def test_tests_only_change_passes(self):
        self.write("alpha/tests/test_tool.sh", "false\n")
        self.commit("tests")
        self.assert_rc(self.run_check(), 0)

    def test_move_from_bin_into_tests_needs_a_bump(self):
        self.git("mv", "alpha/bin/tool.sh", "alpha/tests/tool.sh")
        self.commit("move")
        self.assert_rc(self.run_check(), 1, "alpha/bin/tool.sh")

    def test_lower_version_fails(self):
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "0.9.9")
        self.manifest("alpha", "0.9.9", "codex")
        self.commit("down")
        self.assert_rc(self.run_check(), 1, "not greater than 1.0.0")

    def test_numeric_not_lexical_comparison(self):
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "1.0.10")
        self.manifest("alpha", "1.0.10", "codex")
        self.commit("bump")
        self.git("branch", "-f", "base")
        self.write("alpha/bin/tool.sh", "echo 3\n")
        self.manifest("alpha", "1.0.9")
        self.manifest("alpha", "1.0.9", "codex")
        self.commit("lexically greater, numerically lower")
        self.assert_rc(self.run_check(), 1, "not greater than 1.0.10")

    def test_each_runtime_copy_must_agree(self):
        for source in ("pyproject", "dunder", "lock"):
            with self.subTest(source=source):
                self.runtime("0.1.1", **{source: "0.1.0"})
                self.write("runtime/src/agent_team_graph/graph.py", f"# {source}\n")
                result = self.run_check()
                self.assert_rc(result, 1, "runtime: versions disagree")
        self.runtime("0.1.1")
        self.assert_rc(self.run_check(), 0)

    def test_disagreement_fails_even_without_a_change(self):
        self.manifest("alpha", "1.0.1", "codex")
        self.commit("codex only")
        self.git("branch", "-f", "base")
        self.assert_rc(self.run_check(), 1, "alpha: versions disagree")

    def test_new_plugin_passes(self):
        self.plugin("beta", "0.1.0")
        self.commit("add beta")
        self.assert_rc(self.run_check(), 0)

    def test_change_outside_plugins_passes(self):
        self.write("README.md", "changed\n")
        self.write("scripts/x.sh", "true\n")
        self.commit("repo files")
        self.assert_rc(self.run_check(), 0)

    def test_base_is_the_merge_base(self):
        # main moves on with its own bump; the branch has none of its own.
        self.git("switch", "-q", "-c", "feature")
        self.write("README.md", "feature\n")
        self.commit("feature")
        self.git("switch", "-q", "base")
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "1.0.1")
        self.manifest("alpha", "1.0.1", "codex")
        self.commit("base moves")
        self.git("switch", "-q", "feature")
        self.assert_rc(self.run_check(), 0)

    def test_removed_manifest_with_files_left_fails(self):
        self.git("rm", "-q", "alpha/.claude-plugin/plugin.json")
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.commit("drop manifest")
        self.assert_rc(self.run_check(), 1, "alpha: .claude-plugin/plugin.json was removed")

    def test_removed_plugin_passes(self):
        self.git("rm", "-q", "-r", "alpha")
        self.commit("drop plugin")
        self.assert_rc(self.run_check(), 0)

    def test_unstaged_plugin_deletion_passes(self):
        import shutil
        shutil.rmtree(self.root / "alpha")
        self.assert_rc(self.run_check(), 0)

    def test_top_level_submodule_is_refused(self):
        self.git("update-index", "--add", "--cacheinfo",
                 "160000,1111111111111111111111111111111111111111,gamma")
        self.assert_rc(self.run_check(), 1, "gamma: a top-level submodule is not supported")

    def test_inherited_direct_mode_does_not_leak(self):
        full = dict(os.environ, VERSION_BUMP_DIRECT="true")
        with unittest.mock.patch.dict(os.environ, full):
            self.test_base_is_the_merge_base()

    def test_ignored_plugin_copy_is_not_a_plugin(self):
        self.write(".gitignore", "scratch/\n")
        self.commit("ignore scratch")
        self.git("branch", "-f", "base")
        self.manifest("scratch", "1.0.0")
        self.manifest("scratch", "2.0.0", "codex")
        self.assert_rc(self.run_check(), 0)

    def test_direct_mode_catches_a_force_pushed_rollback(self):
        # main was at 1.0.1; a force push replaces it with an older line at 1.0.0.
        self.write("alpha/bin/tool.sh", "echo 2\n")
        self.manifest("alpha", "1.0.1")
        self.manifest("alpha", "1.0.1", "codex")
        self.commit("1.0.1")
        self.git("branch", "old-tip")
        self.git("reset", "-q", "--hard", "base")
        self.write("README.md", "rewritten\n")
        self.commit("rewrite")
        self.assert_rc(self.run_check(base="old-tip"), 0)  # merge base hides it
        self.assert_rc(self.run_check(base="old-tip", VERSION_BUMP_DIRECT="true"), 1,
                       "not greater than 1.0.1")

    def test_toml_is_parsed_not_pattern_matched(self):
        self.write("runtime/pyproject.toml",
                   "[project]\nversion = '0.1.1'\nname = 'agent-team-graph'\n")
        self.write("runtime/uv.lock",
                   'version = 1\n\n[[package]]\nversion = "0.1.1"\n'
                   'name = "agent-team-graph"\n')
        self.write("runtime/src/agent_team_graph/__init__.py", '__version__ = "0.1.1"\n')
        self.manifest("runtime", "0.1.1")
        self.assert_rc(self.run_check(), 0)
        self.write("runtime/uv.lock", "not = [toml\n")
        self.assert_rc(self.run_check(), 1, "runtime/uv.lock: cannot parse")

    def test_missing_base(self):
        self.assert_rc(self.run_check(base=None), 0, "not found; skipping")
        self.assert_rc(self.run_check(base=None, CI="true"), 2, "does not resolve")
        self.assert_rc(self.run_check(base="nope"), 2, "does not resolve")

    def test_all_zero_base_falls_back_to_default(self):
        # A branch-creating push reports before=000...; the default base
        # (origin/main) does not exist here, so CI mode must fail, not pass.
        result = self.run_check(base="0" * 40, CI="true")
        self.assert_rc(result, 2, "'origin/main' does not resolve")


if __name__ == "__main__":
    unittest.main()
