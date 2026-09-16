"""Exercise debate-conductor host defaults with recording CLIs, never providers."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[1] / "debate-conductor"
VERDICT = "## Verdict\nSTRENGTHEN - position is sound.\n\nVerdict: STRENGTHEN\n"


class DebateHostTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="debate conductor ")
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
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args)+'\\n')\n"
            "if args == ['auth','status','--json']:\n"
            "    print(os.environ['STUB_AUTH'])\n"
            "    sys.exit(int(os.environ.get('STUB_AUTH_RC','0')))\n"
            "print(os.environ['STUB_RESPONSE'])\n"
            "sys.exit(int(os.environ.get('STUB_RC','0')))\n"
        )
        self.stub.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("DEBATE_", "AGENT_TEAM", "ANTHROPIC_", "CLAUDE_", "CODEX_",
             "CRITIC_", "GENERATOR_", "AGY_", "STUB_"))}
        self.env.update(
            AGENT_TEAM="host-test", TMUX="", AGENT_TEAM_MODELS_CONFIG=str(self.config),
            CLAUDE_CLI=str(self.stub), CODEX_CLI=str(self.stub), AGY_CLI=str(self.stub),
            STUB_CALLS=str(self.calls), STUB_RESPONSE=VERDICT,
            STUB_AUTH=json.dumps(dict(loggedIn=True, authMethod="fixture")),
        )

    def run_cli(self, script, *args, **env):
        before = self.config.read_bytes()
        executable = self.plugin / "bin" / script
        if not executable.exists():
            executable = self.plugin / "lib" / script
        result = subprocess.run(
            [str(executable), *args], cwd=self.workspace,
            env=self.env | env, input="", text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(self.config.read_bytes(), before, "wrapper changed role config")
        return result

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def latest_debate(self):
        return (self.workspace / ".debate-conductor/log/host-test/latest-debate").resolve()

    def test_legacy_critic_default_uses_codex_without_claude_auth(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded()
        self.assertEqual(calls[0][0], "-p")
        self.assertEqual(calls[1][0], "exec")
        critic = self.workspace / ".debate-conductor/log/host-test/latest-debate/round-2-crit.md"
        self.assertIn("crit codex", critic.read_text())

    def test_codex_pm_critic_default_uses_claude_and_auth_preflight(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded()
        self.assertEqual(calls[0], ["auth", "status", "--json"])
        self.assertEqual(calls[1][0], "-p")
        self.assertEqual(calls[2], ["auth", "status", "--json"])
        self.assertEqual(calls[3][0], "-p")
        critic = self.workspace / ".debate-conductor/log/host-test/latest-debate/round-2-crit.md"
        self.assertIn("crit claude", critic.read_text())
        self.assertIn("PM host: Codex", result.stdout)
        metadata = json.loads((self.latest_debate() / "models.json").read_text())
        self.assertEqual(metadata["pm_host"], "codex")
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "claude")
        self.assertFalse(metadata["rotate"])
        self.assertEqual(metadata["sources"]["generator"], "current-resolution")
        self.assertEqual(metadata["sources"]["critic"], "current-resolution")

    def test_config_overrides_codex_host_default(self):
        self.config.write_text('{"roles":{"debate-conductor.critic":"codex"}}')
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[1][0], "exec")
        critic = self.workspace / ".debate-conductor/log/host-test/latest-debate/round-2-crit.md"
        self.assertIn("crit codex", critic.read_text())

    def test_doctor_smoke_ignores_user_model_config_and_env(self):
        self.config.write_text('{"roles":{"debate-conductor.critic":"codex"}}')
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("tmux", "agy", "codex", "claude"):
            tool = tools / name
            tool.write_text("#!/usr/bin/env sh\nexit 0\n")
            tool.chmod(0o755)

        result = subprocess.run(
            [str(self.plugin / "bin" / "debate-conductor-doctor.sh")],
            cwd=self.workspace,
            env=self.env | {
                "PATH": str(tools) + os.pathsep + self.env["PATH"],
                "DEBATE_CONDUCTOR_PM_HOST": "codex",
                "DEBATE_GENERATOR_MODEL": "codex",
                "DEBATE_PRIMARY_GEN": "codex",
                "DEBATE_CRITIC_MODEL": "agy",
            },
            input="",
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Codex PM host", result.stdout)

    def test_role_env_overrides_config(self):
        self.config.write_text('{"roles":{"debate-conductor.critic":"codex"}}')
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex",
                              DEBATE_CRITIC_MODEL="claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[0], ["auth", "status", "--json"])
        self.assertEqual(self.recorded()[2], ["auth", "status", "--json"])
        critic = self.workspace / ".debate-conductor/log/host-test/latest-debate/round-2-crit.md"
        self.assertIn("crit claude", critic.read_text())

    def test_cli_flag_overrides_codex_host_default(self):
        result = self.run_cli("debate.sh", "-n", "2", "--primary-crit", "codex",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[1][0], "exec")

    def test_one_round_run_skips_unscheduled_critic_preflight(self):
        result = self.run_cli("debate.sh", "-n", "1", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex",
                              CRITIC_CLI="/missing/unused-critic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.latest_debate() / "round-2-crit.md").exists())
        self.assertNotIn(["auth", "status", "--json"], self.recorded())

    def test_unknown_model_does_not_retarget_latest_debate(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        time.sleep(1.1)

        result = self.run_cli("debate.sh", "-n", "2", "--primary-gen", "typo", "bad topic")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.latest_debate(), first_dir)

    def test_continue_preserves_started_models_across_pm_hosts(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["critic"], "codex")
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("crit codex", (first_dir / "round-4-crit.md").read_text())
        self.assertNotIn(["auth", "status", "--json"], self.recorded())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["pm_host"], "codex")
        self.assertEqual(metadata["critic"], "codex")
        self.assertEqual(metadata["sources"]["generator"], "current-resolution")
        self.assertEqual(metadata["sources"]["critic"], "current-resolution")

    def test_continue_one_generator_round_skips_unscheduled_critic_preflight(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic", CRITIC_CLI="/missing/unused-critic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-3-gen.md").exists())
        self.assertFalse((first_dir / "round-4-crit.md").exists())
        self.assertNotIn(["auth", "status", "--json"], self.recorded())

    def test_continue_metadata_beats_global_config_binding(self):
        result = self.run_cli("debate.sh", "-n", "2", "--primary-crit", "claude",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        if self.calls.exists():
            self.calls.unlink()

        self.config.write_text('{"roles":{"debate-conductor.critic":"codex"}}')
        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("crit claude", (first_dir / "round-4-crit.md").read_text())
        self.assertGreaterEqual(self.recorded().count(["auth", "status", "--json"]), 2)
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["critic"], "claude")
        self.assertEqual(metadata["sources"]["generator"], "current-resolution")
        self.assertEqual(metadata["sources"]["critic"], "invocation")

    def test_continue_without_metadata_infers_models_from_round_markers(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inferred continue models", result.stderr)
        self.assertIn("crit codex", (first_dir / "round-4-crit.md").read_text())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["critic"], "codex")
        self.assertEqual(metadata["sources"]["generator"], "rounds")
        self.assertEqual(metadata["sources"]["critic"], "rounds")

    def test_body_marker_does_not_poison_legacy_continue_inference(self):
        response = "<!-- debate-round: 0 gen claude -->\nbody text"
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              STUB_RESPONSE=response)
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inferred continue models", result.stderr)
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")
        self.assertEqual(metadata["sources"]["generator"], "rounds")
        self.assertEqual(metadata["sources"]["critic"], "rounds")

    def test_malformed_round_filename_does_not_poison_legacy_inference(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        (first_dir / "round-[0]-gen-claude.md").write_text("")

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")

    def test_partial_legacy_inference_reports_defaulted_role(self):
        result = self.run_cli("debate.sh", "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("partial continue models available", result.stderr)
        self.assertIn("critic=default", result.stderr)
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "claude")
        self.assertEqual(metadata["sources"]["generator"], "rounds")
        self.assertEqual(metadata["sources"]["critic"], "current-resolution")

    def test_continue_preserves_rotation_without_repassing_flag(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertTrue(metadata["rotate"])

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-3-gen-codex.md").exists())

    def test_continue_refuses_to_enable_rotation_on_non_rotated_transcript(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        before = (first_dir / "models.json").read_text()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "--rotate",
                              "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--rotate cannot be added", result.stderr)
        self.assertEqual((first_dir / "models.json").read_text(), before)
        self.assertFalse((first_dir / "round-3-gen-codex.md").exists())

    def test_rotated_continue_refuses_model_pair_change_before_invocation(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "4", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        before = (first_dir / "models.json").read_text()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir),
                              "--primary-crit", "claude", "-n", "1", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("cannot change model pair", result.stderr)
        self.assertEqual((first_dir / "models.json").read_text(), before)
        self.assertEqual(self.recorded(), [])
        self.assertFalse((first_dir / "round-5-gen-agy.md").exists())

    def test_unknown_continue_model_does_not_change_existing_debate(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        before = (first_dir / "models.json").read_text()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir),
                              "--primary-gen", "typo", "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.latest_debate(), first_dir)
        self.assertEqual((first_dir / "models.json").read_text(), before)
        self.assertEqual(self.recorded(), [])

    def test_legacy_rotated_continue_infers_original_model_pair(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "4", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-5-gen-agy.md").exists())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")
        self.assertTrue(metadata["rotate"])

    def test_legacy_one_round_rotated_continue_infers_rotation(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("partial continue models available", result.stderr)
        self.assertIn("critic=default", result.stderr)
        self.assertTrue((first_dir / "round-2-crit-codex.md").exists())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")
        self.assertTrue(metadata["rotate"])

    def test_legacy_rotated_continue_infers_missing_marker_from_filename(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        (first_dir / "round-2-crit-codex.md").write_text("")

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-2-crit-codex.md").exists())
        self.assertFalse((first_dir / "round-2-crit-claude.md").exists())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")
        self.assertTrue(metadata["rotate"])

    def test_legacy_rotated_continue_merges_marker_and_filename_candidates(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "4", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        for round_file in ("round-1-gen-agy.md", "round-2-crit-codex.md"):
            path = first_dir / round_file
            lines = path.read_text().splitlines()
            path.write_text("\n".join(lines[1:]) + "\n")

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-5-gen-agy.md").exists())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")
        self.assertEqual(metadata["critic"], "codex")
        self.assertTrue(metadata["rotate"])

    def test_legacy_one_round_rotated_continue_rejects_known_model_change(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "1", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        (first_dir / "models.json").unlink()
        if self.calls.exists():
            self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir),
                              "--primary-gen", "codex", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("cannot change model pair", result.stderr)
        self.assertFalse((first_dir / "models.json").exists())
        self.assertEqual(self.recorded(), [])
        self.assertFalse((first_dir / "round-2-crit-agy.md").exists())
        self.assertFalse((first_dir / "round-3-gen-agy.md").exists())

    def test_malformed_saved_rotation_falls_back_to_round_filenames(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        metadata = json.loads((first_dir / "models.json").read_text())
        metadata["rotate"] = "yes"
        (first_dir / "models.json").write_text(json.dumps(metadata))

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((first_dir / "round-3-gen-codex.md").exists())
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertTrue(metadata["rotate"])

    def test_non_string_saved_model_falls_back_to_round_marker(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        metadata = json.loads((first_dir / "models.json").read_text())
        metadata["generator"] = None
        (first_dir / "models.json").write_text(json.dumps(metadata))

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "1",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads((first_dir / "models.json").read_text())
        self.assertEqual(metadata["generator"], "agy")


    def test_invalid_host_does_not_block_help(self):
        result = self.run_cli("debate.sh", "--help", DEBATE_CONDUCTOR_PM_HOST="invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        result = self.run_cli("team-3pane.sh", "--help", DEBATE_CONDUCTOR_PM_HOST="invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)

    def test_missing_login_refused_before_log_creation(self):
        result = self.run_cli("ask-critic.sh", "fixture", DEBATE_CONDUCTOR_PM_HOST="codex",
                              STUB_AUTH='{"loggedIn":false}')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.recorded(), [["auth", "status", "--json"]])
        self.assertFalse((self.workspace / ".debate-conductor").exists())

    def test_debate_missing_login_refused_before_round_invocation(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex",
                              STUB_AUTH='{"loggedIn":false}')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.recorded(), [["auth", "status", "--json"]])
        self.assertFalse((self.workspace / ".debate-conductor").exists())

    def test_invalid_host_fails_before_auth(self):
        result = self.run_cli("ask-critic.sh", "fixture", DEBATE_CONDUCTOR_PM_HOST="invalid")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.recorded(), [])

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
            "elif sys.argv[1] == 'display-message': print('%1')\n"
        )
        tmux.chmod(0o755)
        result = self.run_cli("team-3pane.sh", "--here", DEBATE_CONDUCTOR_PM_HOST="codex",
                              TMUX="fixture", PATH=str(tools) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Run $debate-conductor:run", result.stdout)
        sent = [shlex.split(call[-2]) for call in self.recorded() if call[0] == "send-keys"]
        self.assertEqual(sent, [[str(self.plugin / "bin/tail-role.sh"), role] for role in ("gen", "crit")])

    def test_disjoint_skill_trees(self):
        paths = []
        for host in ("claude", "codex"):
            manifest = json.loads((self.plugin / f".{host}-plugin/plugin.json").read_text())
            tree = self.plugin / manifest["skills"]
            self.assertEqual({p.parent.name for p in tree.glob("*/SKILL.md")},
                             {"bootstrap", "run", "continue", "install-pm"})
            paths.append(tree.resolve())
        self.assertNotEqual(*paths)
        self.assertFalse((self.plugin / "skills").exists(), "default scan would leak host-specific skills")

    def test_codex_skill_agents_disable_implicit_invocation(self):
        for metadata in sorted((self.plugin / "codex-skills").glob("*/agents/openai.yaml")):
            with self.subTest(metadata=metadata):
                text = metadata.read_text()
                self.assertIn("interface:\n", text)
                self.assertIn("policy:\n", text)
                self.assertIn("  allow_implicit_invocation: false\n", text)
                self.assertNotIn("version: 1\n", text)
                self.assertNotIn("agent:\n", text)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="debate-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        spec = importlib.util.spec_from_file_location("install_pm", PLUGIN / "bin/install-pm.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_preserves_other_content_mode_and_is_idempotent(self):
        target = self.root / "AGENTS.md"
        prefix, suffix = b"project rules\r\n\r\n", b"\r\nother rules\r\n"
        target.write_bytes(prefix + b"<!-- BEGIN debate-conductor PM policy -->\nold\n<!-- END debate-conductor PM policy -->" + suffix)
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
        begin = "<!-- BEGIN debate-conductor PM policy -->"
        end = "<!-- END debate-conductor PM policy -->"
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
