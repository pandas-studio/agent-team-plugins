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

    def generator_prompts(self):
        return [call[-1] for call in self.recorded() if call and call[0] == "-p"]

    def test_continue_retries_failed_first_round_with_saved_context(self):
        context = self.root / "context.md"
        context.write_text("SAVED-CONTEXT-MARKER\n")
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic", str(context), STUB_RC="9")
        self.assertEqual(result.returncode, 9, result.stderr)
        first_dir = self.latest_debate()
        self.assertEqual(list(first_dir.glob(".round-*.done")), [])
        saved = first_dir / "context.md"
        self.assertEqual(saved.read_text(), "SAVED-CONTEXT-MARKER\n")
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.calls.unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resuming from round 1", result.stderr)
        self.assertEqual(self.latest_debate(), first_dir)
        self.assertEqual(len(list(first_dir.glob(".round-*.done"))), 2)
        prompts = self.generator_prompts()
        self.assertEqual(len(prompts), 1)
        self.assertIn("SAVED-CONTEXT-MARKER", prompts[0])

    def test_continue_context_argument_replaces_saved_context(self):
        context = self.root / "context.md"
        context.write_text("SAVED-CONTEXT-MARKER\n")
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic", str(context), STUB_RC="9")
        self.assertEqual(result.returncode, 9, result.stderr)
        first_dir = self.latest_debate()
        self.calls.unlink()

        replacement = self.root / "replacement.md"
        replacement.write_text("REPLACEMENT-CONTEXT-MARKER\n")
        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2",
                              "fixture topic", str(replacement))
        self.assertEqual(result.returncode, 0, result.stderr)
        prompts = self.generator_prompts()
        self.assertEqual(len(prompts), 1)
        self.assertIn("REPLACEMENT-CONTEXT-MARKER", prompts[0])
        self.assertNotIn("SAVED-CONTEXT-MARKER", prompts[0])
        self.assertEqual((first_dir / "context.md").read_text(), "REPLACEMENT-CONTEXT-MARKER\n")

    def test_continue_refuses_invalid_saved_context_before_changing_state(self):
        context = self.root / "context.md"
        context.write_text("SAVED-CONTEXT-MARKER\n")
        link = self.workspace / ".debate-conductor/log/host-test/latest-debate"
        for kind in ("directory", "dangling-symlink"):
            for passed in ((), (str(context),)):
                with self.subTest(kind=kind, context_argument=bool(passed)):
                    result = self.run_cli("debate.sh", "-n", "2", "fixture topic", str(context), STUB_RC="9")
                    self.assertEqual(result.returncode, 9, result.stderr)
                    debate_dir = self.latest_debate()
                    saved = debate_dir / "context.md"
                    saved.unlink()
                    if kind == "directory":
                        saved.mkdir()
                    else:
                        saved.symlink_to(debate_dir / "missing.md")
                    link_target = os.readlink(link)
                    models = (debate_dir / "models.json").read_bytes()
                    if self.calls.exists():
                        self.calls.unlink()

                    result = self.run_cli("debate.sh", "--continue-from", str(debate_dir), "-n", "2",
                                          "fixture topic", *passed, DEBATE_CRITIC_MODEL="claude")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("context.md is not a regular file", result.stderr)
                    self.assertEqual(self.generator_prompts(), [])
                    self.assertEqual((debate_dir / "models.json").read_bytes(), models)
                    self.assertEqual(os.readlink(link), link_target)
                    self.assertTrue(saved.is_symlink() or saved.is_dir())
                    time.sleep(1.1)  # next fresh debate gets its own debate-<TS> dir

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


    # ── One writer per debate (#45) ─────────────────────────────────────────

    def date_shim(self, stamp):
        """PATH entry whose `date` freezes +%Y%m%d-%H%M%S and delegates the rest."""
        real = shutil.which("date", path=self.env.get("PATH", os.defpath))
        self.assertIsNotNone(real, "no real date on PATH")
        shim_dir = self.root / f"date shim {stamp}"
        shim_dir.mkdir()
        shim = shim_dir / "date"
        shim.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            f"if sys.argv[1:] == ['+%Y%m%d-%H%M%S']:\n"
            f"    print({stamp!r})\n"
            "    sys.exit(0)\n"
            f"os.execv({real!r}, [{real!r}] + sys.argv[1:])\n"
        )
        shim.chmod(0o755)
        return f"{shim_dir}{os.pathsep}{self.env['PATH']}"

    def blocking_stub(self, ready, release):
        """A recording CLI that reports readiness, then waits to be released."""
        stub = self.root / f"blocking cli {ready.name}"
        stub.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys, time\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args)+'\\n')\n"
            "if args == ['auth','status','--json']:\n"
            "    print(os.environ['STUB_AUTH'])\n"
            "    sys.exit(0)\n"
            f"open({str(ready)!r}, 'w').close()\n"
            "deadline = time.time() + 30\n"
            f"while not os.path.exists({str(release)!r}):\n"
            "    if time.time() > deadline:\n"
            "        sys.exit(7)\n"
            "    time.sleep(0.02)\n"
            "print(os.environ['STUB_RESPONSE'])\n"
        )
        stub.chmod(0o755)
        return stub

    def start_blocked_debate(self, *args, **env):
        """Launch debate.sh whose first round blocks; return (proc, ready, release)."""
        ready = self.root / f"ready {len(list(self.root.glob('ready *')))}"
        release = self.root / f"release {ready.name[6:]}"
        stub = self.blocking_stub(ready, release)
        proc = subprocess.Popen(
            [str(self.plugin / "bin" / "debate.sh"), *args],
            cwd=self.workspace, text=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=self.env | dict(CLAUDE_CLI=str(stub), CODEX_CLI=str(stub),
                                AGY_CLI=str(stub)) | env,
        )
        self.addCleanup(self.reap, proc, release)
        deadline = time.monotonic() + 30
        while not ready.exists():
            self.assertIsNone(proc.poll(), "debate.sh exited before its first round")
            self.assertLess(time.monotonic(), deadline, "first round never started")
            time.sleep(0.02)
        return proc, ready, release

    def reap(self, proc, release):
        release.touch()
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=30)

    def lock_of(self, debate_dir):
        return Path(debate_dir) / ".lock"

    def snapshot(self, debate_dir):
        """Every byte under a debate dir, plus the lock's target."""
        return sorted(
            (str(f.relative_to(debate_dir)),
             os.readlink(f) if f.is_symlink() else (f.read_bytes() if f.is_file() else None))
            for f in debate_dir.rglob("*"))

    def await_text(self, path, needle, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            if path.exists() and needle in path.read_text():
                return
            self.assertLess(time.monotonic(), deadline, f"{needle!r} never reached {path}")
            time.sleep(0.02)

    def test_same_second_starts_get_distinct_debate_directories(self):
        path = self.date_shim("20260918-120000")
        first = self.run_cli("debate.sh", "-n", "1", "first topic", PATH=path)
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_cli("debate.sh", "-n", "1", "second topic", PATH=path)
        self.assertEqual(second.returncode, 0, second.stderr)

        team = self.workspace / ".debate-conductor/log/host-test"
        self.assertTrue((team / "debate-20260918-120000").is_dir())
        self.assertTrue((team / "debate-20260918-120000-1").is_dir())
        self.assertEqual(self.latest_debate(), (team / "debate-20260918-120000-1").resolve())
        self.assertEqual((team / "debate-20260918-120000/topic.txt").read_text().strip(),
                         "first topic")
        self.assertEqual((team / "debate-20260918-120000-1/topic.txt").read_text().strip(),
                         "second topic")

    def test_suffixed_debate_directory_can_be_continued(self):
        path = self.date_shim("20260918-130000")
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "a", PATH=path).returncode, 0)
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "b", PATH=path).returncode, 0)
        suffixed = self.latest_debate()
        self.assertTrue(suffixed.name.endswith("-1"), suffixed)

        result = self.run_cli("debate.sh", "--continue-from", str(suffixed), "-n", "1", "b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((suffixed / "round-3-gen.md").exists())
        self.assertFalse(self.lock_of(suffixed).is_symlink())

    def test_second_writer_is_refused_while_a_debate_is_running(self):
        proc, _ready, release = self.start_blocked_debate("-n", "1", "held topic")
        held = self.latest_debate()
        self.assertTrue(self.lock_of(held).is_symlink())
        # The round marker travels through `tee` before the CLI is reached, so
        # wait for it to land in both destinations: only then is a byte-for-byte
        # snapshot of the directory stable enough to prove the refusal wrote
        # nothing.
        self.await_text(held / "round-1-gen.md", "debate-round: 1 gen")
        self.await_text(held / "stream-gen.log", "debate-round: 1 gen")
        before = self.snapshot(held)

        second = self.run_cli("debate.sh", "--continue-from", str(held), "-n", "2", "held topic")
        self.assertEqual(second.returncode, 2, second.stdout)
        self.assertIn("is locked by another debate.sh run", second.stderr)
        self.assertIn("rm -rf -- ", second.stderr)
        self.assertEqual(self.snapshot(held), before)
        self.assertFalse(list(held.glob(".round-*.done")))

        release.touch()
        out, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("gen agy", (held / "round-1-gen.md").read_text())
        self.assertFalse(self.lock_of(held).is_symlink())

    def test_lock_left_by_a_lost_run_is_refused_not_reclaimed(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "t").returncode, 0)
        debate = self.latest_debate()
        body = (debate / "round-1-gen.md").read_bytes()
        lock = self.lock_of(debate)

        for owner, expected in (
            ("host=elsewhere pid=4242 started=2026-09-18T12:00:00",
             "is locked by another debate.sh run"),
            ("", "no readable owner"),
            ("handmade", "no readable owner"),
        ):
            with self.subTest(owner=owner):
                if owner:
                    lock.symlink_to(owner)
                else:
                    lock.mkdir()  # a lock left in a shape this script never writes
                result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn(expected, result.stderr)
                self.assertTrue(lock.is_symlink() or lock.is_dir(),
                                "a stranded lock must never be reclaimed")
                self.assertEqual((debate / "round-1-gen.md").read_bytes(), body)
                self.assertFalse((debate / "round-2-gen.md").exists())
                if lock.is_symlink():
                    lock.unlink()
                else:
                    shutil.rmtree(lock)

    def test_lock_is_released_on_a_signal_and_the_status_is_preserved(self):
        import signal
        for sig, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)):
            with self.subTest(signal=sig.name):
                proc, _ready, release = self.start_blocked_debate("-n", "1", f"{sig.name} topic")
                debate = self.latest_debate()
                self.assertTrue(self.lock_of(debate).is_symlink())
                proc.send_signal(sig)
                proc.communicate(timeout=30)
                self.assertEqual(proc.returncode, -sig)
                self.assertEqual(128 - proc.returncode, status)
                self.assertFalse(self.lock_of(debate).is_symlink())
                release.touch()

    def test_failed_continue_preflight_leaves_no_lock(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "t").returncode, 0)
        debate = self.latest_debate()

        # The lock is taken before the CLI preflight on a continue, so a refused
        # preflight must still leave the debate unlocked and untouched.
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "2", "t",
                              CRITIC_CLI="/missing/unused-critic")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.lock_of(debate).is_symlink())
        self.assertFalse((debate / "round-2-crit.md").exists())

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
