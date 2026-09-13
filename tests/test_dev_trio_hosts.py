"""Exercise the real wrappers with recording CLIs, never provider calls."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1] / "dev-trio"
REVIEW = "## Verdict\nSHIP — inspected fixture\n\n## Findings\n### Blocker\n- none\n"


class HostTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dev trio ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.plugin = self.root / "installed plugin"
        shutil.copytree(PLUGIN, self.plugin)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.config = self.root / "models.json"
        self.config.write_text('{"models":{},"roles":{}}')
        self.stub = self.root / "record cli"
        self.stub.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args)+'\\n')\n"
            "if args == ['auth','status','--json']:\n"
            "    print(os.environ['STUB_AUTH'])\n"
            "    sys.exit(int(os.environ.get('STUB_AUTH_RC','0')))\n"
            "response = os.environ['STUB_RESPONSE']\n"
            "if '--output-last-message' in args and not os.environ.get('STUB_NO_FINAL'):\n"
            "    pathlib.Path(args[args.index('--output-last-message')+1]).write_text(response)\n"
            "print(response)\n"
            "sys.exit(int(os.environ.get('STUB_RC','0')))\n"
        )
        self.stub.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("DEV_TRIO_", "AGENT_TEAM", "ANTHROPIC_", "CLAUDE_", "CODEX_",
             "REVIEWER_", "RESEARCHER_", "MANIFEST_", "AGY_", "STUB_"))}
        self.env.update(
            AGENT_TEAM="host-test", TMUX="", AGENT_TEAM_MODELS_CONFIG=str(self.config),
            CLAUDE_CLI=str(self.stub), CODEX_CLI=str(self.stub), AGY_CLI=str(self.stub),
            STUB_CALLS=str(self.calls), STUB_RESPONSE=REVIEW,
            STUB_AUTH=json.dumps(dict(loggedIn=True, authMethod="claude.ai",
                                     apiProvider="firstParty", subscriptionType="max")),
        )

    def run_cli(self, script="ask-codex.sh", *args, **env):
        before = self.config.read_bytes()
        result = subprocess.run(
            [str(self.plugin / "bin" / script), *args], cwd=self.workspace,
            env=self.env | env, input="", text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(self.config.read_bytes(), before, "wrapper changed role config")
        return result

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def assert_model(self, model):
        manifests = list(self.workspace.glob(".dev-trio/log/host-test/*.manifest.json"))
        self.assertEqual(len(manifests), 1)
        self.assertEqual(json.loads(manifests[0].read_text())["roles"][0]["model"], model)

    def assert_no_inference(self, result):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(all(call == ["auth", "status", "--json"] for call in self.recorded()))
        self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_legacy_default_uses_codex_without_claude_auth(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[0][0], "exec")
        self.assert_model("codex")

    def test_codex_pm_uses_claude_and_produces_final_artifact(self):
        evidence, spec = self.workspace / "research notes.md", self.workspace / "contract spec.md"
        evidence.write_text("source-backed finding")
        spec.write_text("retain §1")
        focus = "review spaces; $(touch BAD) `touch BAD2`"
        result = self.run_cli("ask-codex.sh", focus, "--with-research", str(evidence),
                              "--with-spec", str(spec), DEV_TRIO_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        auth, review = self.recorded()
        self.assertEqual(auth, ["auth", "status", "--json"])
        self.assertEqual(review[0], "-p")
        self.assertEqual(len(review), 2)
        for text in (focus, "source-backed finding", "retain §1"):
            self.assertIn(text, review[1])
        self.assertFalse((self.workspace / "BAD").exists())
        self.assertFalse((self.workspace / "BAD2").exists())
        self.assert_model("claude")
        final = self.workspace / ".dev-trio/log/host-test/latest-codex.final.md"
        self.assertEqual(final.read_text().strip(), REVIEW.strip())

    def test_config_overrides_codex_host_default(self):
        self.config.write_text('{"roles":{"dev-trio.reviewer":"codex"}}')
        result = self.run_cli(DEV_TRIO_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[0][0], "exec")
        self.assert_model("codex")

    def test_role_env_overrides_config(self):
        self.config.write_text('{"roles":{"dev-trio.reviewer":"codex"}}')
        result = self.run_cli(DEV_TRIO_PM_HOST="codex", DEV_TRIO_REVIEWER_MODEL="claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_model("claude")

    def test_unknown_host_fails_before_auth(self):
        self.assert_no_inference(self.run_cli(DEV_TRIO_PM_HOST="invalid"))

    def test_no_memories_rejected_for_default_claude(self):
        self.assert_no_inference(self.run_cli("ask-codex.sh", "--no-memories", DEV_TRIO_PM_HOST="codex"))

    def test_codex_override_can_use_no_memories(self):
        result = self.run_cli("ask-codex.sh", "--no-memories", DEV_TRIO_PM_HOST="codex",
                              DEV_TRIO_REVIEWER_MODEL="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("features.memories=false", self.recorded()[0])

    def test_api_login_is_accepted_and_secret_not_logged(self):
        result = self.run_cli(DEV_TRIO_PM_HOST="codex", ANTHROPIC_API_KEY="secret-sentinel",
                              STUB_AUTH='{"loggedIn":true,"authMethod":"api_key"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("secret-sentinel", result.stdout + result.stderr)
        self.assert_model("claude")

    def test_custom_claude_arguments_are_preserved(self):
        self.config.write_text(json.dumps({"models": {"claude": {
            "command": str(self.stub), "args": ["--bare", "-p", "{prompt}"]}}}))
        result = self.run_cli(DEV_TRIO_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[1][:2], ["--bare", "-p"])

    def test_missing_login_refused(self):
        self.assert_no_inference(self.run_cli(DEV_TRIO_PM_HOST="codex", STUB_AUTH='{"loggedIn":false}'))

    def test_auth_failure_refused(self):
        self.assert_no_inference(self.run_cli(DEV_TRIO_PM_HOST="codex", STUB_AUTH_RC="1"))

    def test_invalid_auth_json_refused(self):
        self.assert_no_inference(self.run_cli(DEV_TRIO_PM_HOST="codex", STUB_AUTH="not json"))

    def test_missing_cli_refused(self):
        self.assert_no_inference(self.run_cli(DEV_TRIO_PM_HOST="codex", CLAUDE_CLI="/absent/claude"))

    def test_provider_failure_is_returned_even_with_ship_text(self):
        result = self.run_cli(DEV_TRIO_PM_HOST="codex", STUB_RC="7")
        self.assertEqual(result.returncode, 7, result.stderr)
        log = self.workspace / ".dev-trio/log/host-test/latest-codex.log"
        self.assertIn("=== END (rc=7) ===", log.read_text())

    def test_research_without_tmux_keeps_model(self):
        result = self.run_cli("ask-agy.sh", "research question", DEV_TRIO_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[0][0], "-p")
        self.assert_model("agy")

    def test_layout_quotes_installed_path_and_identifies_codex_pm(self):
        import shlex
        tools = self.root / "tools"
        tools.mkdir()
        tmux = tools / "tmux"
        tmux.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "if sys.argv[1] == 'split-window': print('%2')\n"
            "elif sys.argv[1] == 'display-message': print('fixture')\n"
        )
        tmux.chmod(0o755)
        result = self.run_cli("team-layout.sh", "--here", DEV_TRIO_PM_HOST="codex",
                              TMUX="fixture", PATH=str(tools) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Run 'codex'", result.stdout)
        sent = [shlex.split(call[-2]) for call in self.recorded() if call[0] == "send-keys"]
        self.assertEqual(sent, [[str(self.plugin / "bin/dashboard.sh"), role] for role in ("agy", "codex")])

    def test_dashboard_displays_actual_reviewer_from_run(self):
        logdir = self.workspace / ".dev-trio/log/host-test"
        logdir.mkdir(parents=True)
        (logdir / "latest-codex.log").write_text(
            "=== FOCUS ===\nfixture\n=== MODEL: claude ===\n=== RESPONSE ===\n" + REVIEW + "=== END (rc=0) ===\n")
        result = subprocess.run([str(self.plugin / "bin/dashboard.sh"), "codex"],
                                cwd=self.workspace, env=self.env, input="q", text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Reviewer · claude", result.stdout)

    def test_disjoint_skill_trees(self):
        paths = []
        for host in ("claude", "codex"):
            manifest = json.loads((self.plugin / f".{host}-plugin/plugin.json").read_text())
            tree = self.plugin / manifest["skills"]
            self.assertEqual({p.parent.name for p in tree.glob("*/SKILL.md")},
                             {"bootstrap", "research", "review", "install-pm"})
            paths.append(tree.resolve())
        self.assertNotEqual(*paths)
        self.assertFalse((self.plugin / "skills").exists(), "default scan would leak host-specific skills")


class PolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dev-trio-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        spec = importlib.util.spec_from_file_location("install_pm", PLUGIN / "bin/install-pm.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_preserves_other_content_mode_and_is_idempotent(self):
        target = self.root / "AGENTS.md"
        prefix, suffix = b"project rules\r\n\r\n", b"\r\nother rules\r\n"
        target.write_bytes(prefix + b"<!-- BEGIN dev-trio PM policy -->\nold\n<!-- END dev-trio PM policy -->" + suffix)
        target.chmod(0o640)
        claude = self.root / "CLAUDE.md"
        claude.write_text("existing Claude rules")
        self.module.install(self.root, "codex")
        first = target.read_bytes()
        self.assertTrue(first.startswith(prefix))
        self.assertTrue(first.endswith(suffix))
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.module.install(self.root, "codex")
        self.assertEqual(first, target.read_bytes())
        self.assertEqual(claude.read_text(), "existing Claude rules")

    def test_append_and_create_for_selected_host(self):
        agents = self.root / "AGENTS.md"
        agents.write_text("existing rules")
        self.module.install(self.root, "codex")
        self.assertTrue(agents.read_text().startswith("existing rules\n\n"))
        self.module.install(self.root, "claude")
        self.assertTrue((self.root / "CLAUDE.md").exists())

    def test_malformed_markers_leave_file_unchanged(self):
        begin, end = "<!-- BEGIN dev-trio PM policy -->", "<!-- END dev-trio PM policy -->"
        for old in (begin, end, end + begin, begin + begin + end):
            with self.subTest(old=old):
                target = self.root / "AGENTS.md"
                target.write_text(old)
                with self.assertRaises(ValueError):
                    self.module.install(self.root, "codex")
                self.assertEqual(target.read_text(), old)

    def test_symlink_target_is_not_followed(self):
        other = self.root / "other.md"
        other.write_text("other policy")
        (self.root / "AGENTS.md").symlink_to(other)
        with self.assertRaises(ValueError):
            self.module.install(self.root, "codex")
        self.assertEqual(other.read_text(), "other policy")


if __name__ == "__main__":
    unittest.main()
