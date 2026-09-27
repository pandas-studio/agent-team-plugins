"""Exercise debate-conductor host defaults with recording CLIs, never providers."""

import importlib.util
import json
import os
import signal
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
            # agy, claude and codex read the prompt from stdin (#102, #147); it is
            # recorded after a '<stdin>' marker. run_cli gives the wrappers an
            # empty, closed stdin, so an argv model reads nothing here.
            "data = '' if sys.stdin.isatty() else sys.stdin.read()\n"
            "if data:\n"
            "    args = args + ['<stdin>', data]\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args)+'\\n')\n"
            "if args == ['auth','status','--json']:\n"
            "    print(os.environ['STUB_AUTH'])\n"
            "    sys.exit(int(os.environ.get('STUB_AUTH_RC','0')))\n"
            "if '--output-last-message' in args:\n"
            "    with open(args[args.index('--output-last-message') + 1], 'w') as f:\n"
            "        f.write(os.environ['STUB_RESPONSE'])\n"
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
        self.assertEqual(calls[0][:4], ["--input-format", "text", "--output-format", "text"])
        self.assertEqual(calls[0][-2], "<stdin>")
        self.assertEqual(calls[1][0], "exec")
        critic = self.workspace / ".debate-conductor/log/host-test/latest-debate/round-2-crit.md"
        self.assertIn("crit codex", critic.read_text())

    def test_codex_pm_critic_default_uses_claude_and_auth_preflight(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_CONDUCTOR_PM_HOST="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded()
        self.assertEqual(calls[0], ["auth", "status", "--json"])
        self.assertEqual(calls[1][:4], ["--input-format", "text", "--output-format", "text"])
        self.assertEqual(calls[1][-2], "<stdin>")
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

    def test_doctor_generator_stub_checks_text_flags(self):
        doctor = (self.plugin / "bin" / "debate-conductor-doctor.sh").read_text()
        stub = doctor.split('cat > "$STUB_GEN" <<\'STUB\'\n', 1)[1].split("\nSTUB\n", 1)[0]
        script = self.root / "doctor-generator-stub.sh"
        script.write_text(stub + "\n")
        flags = ["--input-format", "text", "--output-format", "text"]
        valid = subprocess.run(["bash", str(script), *flags], input="draft", text=True,
                               capture_output=True, timeout=5)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        invalid = subprocess.run(["bash", str(script), *flags[:-1], "json"], input="draft",
                                 text=True, capture_output=True, timeout=5)
        self.assertEqual(invalid.returncode, 2, invalid.stdout + invalid.stderr)
        self.assertIn("expected stdin text flags", invalid.stderr)

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
        return [call[-1] for call in self.recorded()
                if call[:4] == ["--input-format", "text", "--output-format", "text"]
                and call[-2] == "<stdin>"]

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
        self.assertEqual(list(first_dir.glob(".round-*.done")), [])
        self.assertEqual([r["round"] for r in self.index_records(first_dir)
                          if r["t"] == "end" and r["rc"] == 0], [1, 2])
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
            # claude and codex read the prompt from stdin (#102); it is
            # recorded after a '<stdin>' marker. run_cli gives the wrappers an
            # empty, closed stdin, so an argv model reads nothing here.
            "data = '' if sys.stdin.isatty() else sys.stdin.read()\n"
            "if data:\n"
            "    args = args + ['<stdin>', data]\n"
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
            "if '--output-last-message' in args:\n"
            "    with open(args[args.index('--output-last-message') + 1], 'w') as f:\n"
            "        f.write(os.environ['STUB_RESPONSE'])\n"
            "print(os.environ['STUB_RESPONSE'])\n"
        )
        stub.chmod(0o755)
        return stub

    def start_blocked_debate(self, *args, new_session=False, **env):
        """Launch debate.sh whose first round blocks; return (proc, ready, release).

        new_session puts the run in its own process group, so a test that kills
        it can kill the group: the model stub, the filter and the tees are
        children of debate.sh and survive a signal aimed at the parent alone.
        """
        ready = self.root / f"ready {len(list(self.root.glob('ready *')))}"
        release = self.root / f"release {ready.name[6:]}"
        stub = self.blocking_stub(ready, release)
        proc = subprocess.Popen(
            [str(self.plugin / "bin" / "debate.sh"), *args],
            cwd=self.workspace, text=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=new_session,
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

    def test_selection_publication_follows_runs_and_continues(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "A").returncode, 0)
        a = self.latest_debate()
        state = a.parent / "latest-debate.json"
        self.assertEqual(json.loads(state.read_text())["sequence"], 1)
        self.assertEqual(self.run_cli("debate.sh", "--continue-from", str(a), "-n", "1", "A").returncode, 0)
        self.assertEqual(json.loads(state.read_text())["sequence"], 1)
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "B").returncode, 0)
        self.assertEqual(json.loads(state.read_text())["sequence"], 2)
        self.assertEqual(self.run_cli("debate.sh", "--continue-from", str(a), "-n", "1", "A").returncode, 0)
        self.assertEqual(json.loads(state.read_text()),
                         {"v": 1, "sequence": 3, "debate_dir": str(a)})

    def test_pruned_selection_allows_new_run_and_continue(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "A",
                                      PATH=self.date_shim("20260920-120000")).returncode, 0)
        a = self.latest_debate()
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "B").returncode, 0)
        b = self.latest_debate()
        state = b.parent / "latest-debate.json"
        shutil.rmtree(b)
        continued = self.run_cli("debate.sh", "--continue-from", str(a), "-n", "1", "A")
        self.assertEqual(continued.returncode, 0, continued.stderr)
        self.assertEqual(json.loads(state.read_text())["sequence"], 3)
        shutil.rmtree(a)
        # Distinct paths, even when all runs finish within one clock second.
        new = self.run_cli("debate.sh", "-n", "1", "C",
                           PATH=self.date_shim("20260920-120001"))
        self.assertEqual(new.returncode, 0, new.stderr)
        self.assertEqual(json.loads(state.read_text())["sequence"], 4)

    def test_failed_new_publication_removes_only_new_allocation(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "A").returncode, 0)
        a = self.latest_debate()
        team = a.parent
        before = sorted(team.glob("debate-*"))
        calls = self.recorded()
        lock = team / ".latest-debate.lock"
        lock.symlink_to("host=gone pid=999999 run=fixture")
        refused = self.run_cli("debate.sh", "-n", "1", "B")
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertEqual(sorted(team.glob("debate-*")), before)
        lock.unlink()
        (team / "latest-debate.json").write_text("{broken")
        refused = self.run_cli("debate.sh", "-n", "1", "C")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertEqual(sorted(team.glob("debate-*")), before)
        self.assertEqual(self.recorded(), calls)
        self.assertTrue((a / "topic.txt").exists())

    def test_failed_preflight_does_not_publish_selection(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "A").returncode, 0)
        state = self.latest_debate().parent / "latest-debate.json"
        before = state.read_bytes()
        result = self.run_cli("debate.sh", "-n", "1", "B", GENERATOR_CLI="/missing/generator")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state.read_bytes(), before)

    def test_invalid_selection_prevents_model_dispatch_and_releases_writer(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "A").returncode, 0)
        a = self.latest_debate()
        state = a.parent / "latest-debate.json"
        state.write_text("{broken")
        before = self.recorded()
        result = self.run_cli("debate.sh", "--continue-from", str(a), "-n", "1", "A")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid selection state", result.stderr)
        self.assertEqual(self.recorded(), before)
        self.assertFalse((a / ".lock").is_symlink())
        self.assertFalse((a.parent / ".latest-debate.lock").is_symlink())

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

    # ── Attempt ledger (#44) ───────────────────────────────────────────────

    def index_records(self, debate_dir):
        """Every ledger line, parsed strictly — a test must see the raw file."""
        path = Path(debate_dir) / "index.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def sidecars(self, debate_dir):
        return sorted(p.name for p in Path(debate_dir).glob(".round-*.done"))

    def stream_frames(self, debate_dir, role):
        text = (Path(debate_dir) / f"stream-{role}.log").read_text()
        return [chunk.splitlines()[0] for chunk in text.split("\x1e")[1:]]

    def test_ledger_records_every_attempt_and_ids_match_the_stream(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        debate = self.latest_debate()

        records = self.index_records(debate)
        self.assertEqual([r["t"] for r in records], ["start", "end", "start", "end"])
        for record in records:
            self.assertEqual(record["v"], 1)
        starts = [r for r in records if r["t"] == "start"]
        ends = [r for r in records if r["t"] == "end"]
        self.assertEqual([(r["round"], r["role"], r["model"], r["file"]) for r in starts],
                         [(1, "gen", "agy", "round-1-gen.md"),
                          (2, "crit", "codex", "round-2-crit.md")])
        self.assertEqual([(r["round"], r["role"], r["file"], r["rc"]) for r in ends],
                         [(1, "gen", "round-1-gen.md", 0),
                          (2, "crit", "round-2-crit.md", 0)])
        self.assertEqual([r["id"] for r in starts], [r["id"] for r in ends])
        self.assertEqual(len(set(r["id"] for r in starts)), 2)
        for record in records:
            self.assertRegex(record["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

        # A ledger row exists to locate its own bytes: every id must appear in
        # both frames of its role's stream.
        for record in starts:
            frames = self.stream_frames(debate, record["role"])
            self.assertTrue(any(f.startswith("<!-- debate-round:") and record["id"] in f
                                for f in frames), frames)
            self.assertTrue(any(f.startswith("<!-- debate-round-end:") and record["id"] in f
                                for f in frames), frames)

    def test_failed_attempt_and_its_retry_are_both_in_the_ledger(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic", STUB_RC="9")
        self.assertNotEqual(result.returncode, 0)
        debate = self.latest_debate()
        records = self.index_records(debate)
        self.assertEqual([r["t"] for r in records], ["start", "end"])
        self.assertEqual(records[1]["rc"], 9)
        self.assertEqual(self.sidecars(debate), [])

        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "2",
                              "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.index_records(debate)
        round_one = [r for r in records if r["round"] == 1]
        self.assertEqual([r["rc"] for r in round_one if r["t"] == "end"], [9, 0])
        self.assertEqual(len(set(r["id"] for r in round_one if r["t"] == "start")), 2,
                         "the retry must be a new attempt id")
        # Decision 1: the round file keeps the winner, the stream keeps both.
        self.assertEqual((debate / "round-1-gen.md").read_text().count("debate-round: 1 gen"), 1)
        self.assertEqual(
            len([f for f in self.stream_frames(debate, "gen")
                 if f.startswith("<!-- debate-round: 1 gen")]), 2)

    def test_continue_resumes_from_the_ledger_without_any_sidecar(self):
        # Successful runs must create only ledger completion records.
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        self.assertEqual(self.sidecars(debate), [])

        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "2", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("resuming from round 1", result.stderr)
        self.assertTrue((debate / "round-3-gen.md").exists())
        self.assertTrue((debate / "round-4-crit.md").exists())

    def test_legacy_continuation_refuses_without_changing_the_debate(self):
        self.assertEqual(self.run_cli("debate.sh", "--rotate", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        records = self.index_records(debate)
        (debate / ".round-1-gen-agy.done").touch()
        (debate / ".round-2-crit-codex.done").touch()
        # Make overwriting detectable even when a retry emits the same stub answer.
        (debate / "round-1-gen-agy.md").write_text("ORIGINAL FINISHED DRAFT\n")
        ledger = debate / "index.jsonl"
        for history in (None, [], [dict(records[0], round=3)],
                        [dict(records[1], role="crit")],
                        [dict(r, round=4, role="crit") for r in records]):
            with self.subTest(history=history):
                if ledger.exists():
                    ledger.unlink()
                if history is not None:
                    ledger.write_text("".join(json.dumps(r) + "\n" for r in history))
                before = self.snapshot(debate)
                calls = self.recorded()
                # Continuing an older debate must not retarget the team's viewer.
                latest = debate.parent / "latest-debate"
                latest.unlink()
                latest.symlink_to("debate-some-other-run")
                result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("start a fresh debate", result.stderr)
                self.assertEqual(self.snapshot(debate), before)
                self.assertEqual(self.recorded(), calls)
                self.assertEqual(os.readlink(latest), "debate-some-other-run")

    def test_ledger_missing_without_sidecars_is_also_refused(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "t").returncode, 0)
        debate = self.latest_debate()
        ledger = debate / "index.jsonl"
        ledger.unlink()
        for directory in (False, True):
            with self.subTest(directory=directory):
                if directory:
                    ledger.mkdir()
                before = self.snapshot(debate)
                result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("readable", result.stderr)
                self.assertEqual(self.snapshot(debate), before)

    def test_unreadable_ledger_is_refused_before_mutation(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "1", "t").returncode, 0)
        debate = self.latest_debate()
        before = self.snapshot(debate)
        calls = self.recorded()
        tools = self.root / "unreadable-ledger"
        tools.mkdir()
        shim = tools / "jq"
        # Deterministic read error, including in root-owned Linux containers.
        shim.write_text(f"#!{sys.executable}\n"
                        "import os, sys\n"
                        "if any(a.endswith('/index.jsonl') for a in sys.argv[1:]):\n"
                        "    sys.exit(1)\n"
                        f"os.execv({shutil.which('jq')!r}, ['jq'] + sys.argv[1:])\n")
        shim.chmod(0o755)
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t",
                              PATH=str(tools) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("readable attempt ledger", result.stderr)
        self.assertEqual(self.snapshot(debate), before)
        self.assertEqual(self.recorded(), calls)

    def test_fully_indexed_debate_keeps_existing_sidecars_but_writes_none(self):
        self.assertEqual(self.run_cli("debate.sh", "--rotate", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        for name in (".round-1-gen-agy.done", ".round-2-crit-codex.done"):
            (debate / name).write_text("legacy sidecar\n")
        original = self.snapshot(debate)
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "2", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, body in original:
            if name.startswith(("round-", ".round-")):
                self.assertEqual((debate / name).read_bytes(), body)
        self.assertEqual(self.sidecars(debate), [".round-1-gen-agy.done", ".round-2-crit-codex.done"])
        self.assertEqual([r["round"] for r in self.index_records(debate)
                          if r["t"] == "end" and r["rc"] == 0], [1, 2, 3, 4])

    def test_no_completed_ledger_refuses_existing_later_output(self):
        self.assertEqual(self.run_cli("debate.sh", "--rotate", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        ledger = debate / "index.jsonl"
        starts = "".join(json.dumps(r) + "\n" for r in self.index_records(debate)
                         if r["t"] == "start")
        calls = self.recorded()
        latest = debate.parent / "latest-debate"
        latest.unlink()
        latest.symlink_to("debate-other")
        for contents in ("", starts, "torn ledger\n"):
            for rounds in ("1", "2"):
                with self.subTest(contents=contents, rounds=rounds):
                    ledger.write_text(contents)
                    before = self.snapshot(debate)
                    result = self.run_cli("debate.sh", "--continue-from", str(debate),
                                          "-n", rounds, "t")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("contains output", result.stderr)
                    self.assertEqual(self.snapshot(debate), before)
                    self.assertEqual(self.recorded(), calls)
                    self.assertEqual(os.readlink(latest), "debate-other")

    def test_partial_ledger_refuses_output_beyond_next_retry(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "4", "t").returncode, 0)
        debate = self.latest_debate()
        records = self.index_records(debate)
        ledger = debate / "index.jsonl"
        ledger.write_text("".join(json.dumps(r) + "\n" for r in records if r["round"] == 1))
        before = self.snapshot(debate)
        calls = self.recorded()
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("beyond retry round 2", result.stderr)
        self.assertEqual(self.snapshot(debate), before)
        self.assertEqual(self.recorded(), calls)
        # An interrupted next round remains retryable once later output is absent.
        for path in (debate / "round-3-gen.md", debate / "round-4-crit.md"):
            path.write_text("")
        first = (debate / "round-1-gen.md").read_bytes()
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((debate / "round-1-gen.md").read_bytes(), first)
        self.assertEqual(self.index_records(debate)[-1]["round"], 2)

    def test_empty_ledger_can_retry_first_round(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "4", "t", STUB_RC="9").returncode, 9)
        debate = self.latest_debate()
        self.assertEqual((debate / "round-2-crit.md").stat().st_size, 0)
        (debate / "index.jsonl").write_text("")
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resuming from round 1", result.stderr)
        self.assertEqual(self.index_records(debate)[-1]["rc"], 0)

    def inject_debate_hooks(self, hooks):
        """Inject faults into the installed fixture, without production test hooks."""
        script = (PLUGIN / "bin/debate.sh").read_text()
        marker = "# Always forward the resolved per-round model"
        self.assertEqual(script.count(marker), 1)
        (self.plugin / "bin/debate.sh").write_text(script.replace(marker, hooks + "\n" + marker))

    def test_ledger_write_failures_stop_before_next_round_and_receipt(self):
        self.inject_debate_hooks(r'''
eval "real_$(declare -f index_append)"
index_append() {
  case "$FAULT_STAGE:$1" in
    start:*'"t":"start"'*|end:*'"t":"end"'*) return 1 ;;
  esac
  real_index_append "$@"
}
''')
        for stage, model_rc, expected in (("start", "0", 1), ("end", "0", 1), ("end", "9", 9)):
            with self.subTest(stage=stage, model_rc=model_rc):
                calls = len(self.recorded())
                receipt = self.receipt_path()
                result = self.run_cli("debate.sh", "-n", "2", "t", FAULT_STAGE=stage,
                                      STUB_RC=model_rc, DEBATE_RECEIPT=str(receipt))
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(f"cannot record attempt {stage}", result.stderr)
                debate = self.latest_debate()
                self.assertFalse(self.lock_of(debate).is_symlink())
                self.assertFalse(receipt.exists())
                self.assertEqual(self.sidecars(debate), [])
                self.assertEqual(len(self.recorded()) - calls, 0 if stage == "start" else 1)
                rows = self.index_records(debate)
                self.assertEqual([r["t"] for r in rows], [] if stage == "start" else ["start"])
                ends = [f for f in self.stream_frames(debate, "gen") if "-end:" in f]
                self.assertEqual(len(ends), 1)
                self.assertIn(f" rc={1 if stage == 'start' else model_rc} ", ends[0])
                if stage == "end":
                    self.assertIn(VERDICT, (debate / "round-1-gen.md").read_text())
                # The same directory remains resumable after repairing recording.
                retry = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t",
                                     FAULT_STAGE="none")
                self.assertEqual(retry.returncode, 0, retry.stderr)
                self.assertEqual(self.index_records(debate)[-1]["round"], 1)

    def test_signal_exit_and_lock_cleanup_survive_a_failed_ledger_end(self):
        self.inject_debate_hooks(r'''
eval "real_$(declare -f index_append)"
index_append() {
  case "$1" in *'"t":"end"'*) return 1 ;; esac
  real_index_append "$@"
}
''')
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                proc, _ready, release = self.start_blocked_debate("-n", "2", "t")
                debate = self.latest_debate()
                proc.send_signal(sig)
                _out, err = proc.communicate(timeout=30)
                self.assertEqual(proc.returncode, -sig, err)
                self.assertIn("cannot record attempt end", err)
                self.assertFalse(self.lock_of(debate).is_symlink())
                self.assertEqual([r["t"] for r in self.index_records(debate)], ["start"])
                ends = [f for f in self.stream_frames(debate, "gen") if "-end:" in f]
                self.assertEqual(len(ends), 1)
                self.assertIn(f" rc={128 + sig} ", ends[0])
                release.touch()

    def test_signals_around_completion_keep_ledger_and_stream_status_consistent(self):
        self.inject_debate_hooks(r'''
fault_fired=""
fault_signal() {
  if [ "$FAULT_POINT" = "$1" ] && [ -z "$fault_fired" ]; then
    fault_fired=1
    kill -s "$FAULT_SIGNAL" "$$"
  fi
}
eval "real_$(declare -f complete_attempt)"
eval "real_$(declare -f index_append)"
eval "real_$(declare -f stream_attempt_end)"
complete_attempt() {
  fault_signal before-status
  real_complete_attempt "$@"
}
index_append() {
  case "$1" in *'"t":"end"'*) fault_signal before-ledger ;; esac
  real_index_append "$@" || return $?
  case "$1" in *'"t":"end"'*) fault_signal after-ledger ;; esac
}
stream_attempt_end() {
  fault_signal before-stream
  real_stream_attempt_end "$@"
  fault_signal after-stream
}
''')
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            for point in ("before-status", "before-ledger", "after-ledger", "before-stream", "after-stream"):
                with self.subTest(signal=sig.name, point=point):
                    receipt = self.receipt_path()
                    result = self.run_cli("debate.sh", "-n", "2", "t", FAULT_POINT=point,
                                          FAULT_SIGNAL=sig.name[3:], DEBATE_RECEIPT=str(receipt))
                    self.assertEqual(result.returncode, -sig, result.stderr)
                    debate = self.latest_debate()
                    rows = self.index_records(debate)
                    self.assertEqual([r["t"] for r in rows], ["start", "end"])
                    expected = 128 + sig if point == "before-status" else 0
                    self.assertEqual(rows[-1]["rc"], expected)
                    ends = [f for f in self.stream_frames(debate, "gen") if "-end:" in f]
                    self.assertEqual(len(ends), 1)
                    self.assertIn(f" rc={expected} id={rows[-1]['id']} ", ends[0])
                    self.assertEqual(self.stream_frames(debate, "crit"), [])
                    self.assertFalse(self.lock_of(debate).is_symlink())
                    self.assertFalse(receipt.exists())
                    self.assertEqual(self.sidecars(debate), [])

    def test_sigkill_completion_depends_on_the_ledger_end(self):
        self.inject_debate_hooks(r'''
eval "real_$(declare -f index_append)"
index_append() {
  case "$1" in
    *'"t":"end"'*)
      case "$FAULT_POINT" in
        before) kill -s KILL "$$" ;;
        torn) printf '{"v":1,"t":"end"' >> "$DEBATE_DIR/index.jsonl"; kill -s KILL "$$" ;;
      esac ;;
  esac
  real_index_append "$@" || return $?
  case "$FAULT_POINT:$1" in after:*'"t":"end"'*) kill -s KILL "$$" ;; esac
}
''')
        for point in ("before", "torn", "after"):
            with self.subTest(point=point):
                receipt = self.receipt_path()
                result = self.run_cli("debate.sh", "-n", "2", "t", FAULT_POINT=point,
                                      DEBATE_RECEIPT=str(receipt))
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                debate = self.latest_debate()
                self.assertTrue(self.lock_of(debate).is_symlink())
                self.assertFalse(receipt.exists())
                self.assertEqual(self.sidecars(debate), [])
                self.assertEqual(len(self.stream_frames(debate, "gen")), 1)
                original = (debate / "round-1-gen.md").read_bytes()
                # The pipeline finished before the injected kill: no writer remains.
                self.lock_of(debate).unlink()
                retry = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t",
                                     FAULT_POINT="none", STUB_RESPONSE="RETRY ANSWER\n")
                self.assertEqual(retry.returncode, 0, retry.stderr)
                rows = []
                for line in (debate / "index.jsonl").read_text().splitlines():
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        self.assertEqual(point, "torn")
                self.assertEqual(rows[-1]["round"], 2 if point == "after" else 1)
                self.assertEqual(rows[-1]["rc"], 0)
                if point == "after":
                    self.assertEqual((debate / "round-1-gen.md").read_bytes(), original)
                else:
                    self.assertIn("RETRY ANSWER", (debate / "round-1-gen.md").read_text())

    def test_signal_before_next_generator_header_preserves_completed_rounds(self):
        self.inject_debate_hooks(r'''
eval "real_$(declare -f stream_header)"
stream_header() {
  if [ "$CUR_ATTEMPT_ROUND" = 3 ]; then kill -s TERM "$$"; fi
  real_stream_header "$@"
}
''')
        result = self.run_cli("debate.sh", "-n", "3", "t")
        self.assertEqual(result.returncode, -signal.SIGTERM, result.stderr)
        debate = self.latest_debate()
        ends = [r for r in self.index_records(debate) if r["t"] == "end"]
        self.assertEqual([(r["round"], r["rc"]) for r in ends], [(1, 0), (2, 0)])
        self.assertEqual(len(self.stream_frames(debate, "gen")), 2)
        self.assertFalse(self.lock_of(debate).is_symlink())

    def test_a_torn_final_ledger_line_is_ignored_and_does_not_glue(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        # Only the ledger may answer, or a tolerant reader is not what is tested.
        self.assertEqual(self.sidecars(debate), [])
        with (debate / "index.jsonl").open("a") as handle:
            handle.write('{"v":1,"t":"end","id":"x","round":9,"role":"gen","rc":0,"fi')

        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("resuming from round 1", result.stderr)
        self.assertTrue((debate / "round-3-gen.md").exists(), "resumed past the torn round 9")
        lines = (debate / "index.jsonl").read_text().splitlines()
        torn = [i for i, line in enumerate(lines) if line.endswith('"fi')]
        self.assertEqual(len(torn), 1, lines)
        for line in lines[torn[0] + 1:]:
            json.loads(line)  # the newline-first rule: nothing got glued on

    def test_ledger_ignores_a_malformed_interior_line(self):
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        # Only the ledger may answer, and the garbage has to sit *before* the
        # record that decides the resume point — appended last, a reader that
        # simply stops at it would still look correct.
        self.assertEqual(self.sidecars(debate), [])
        path = debate / "index.jsonl"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:-1] + ["not json at all", "[1,2,3]", lines[-1]]) + "\n")

        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("resuming from round 1", result.stderr)
        self.assertTrue((debate / "round-3-gen.md").exists())

    def test_round_is_complete_survives_a_large_ledger(self):
        # `grep -q` would exit on the first match, the producers would take
        # SIGPIPE, and pipefail would report 141 for a round that is complete.
        # Measured: reproduces at 20000 records, not at 4000. The fixture is
        # larger than the reproduction so the result does not ride on the pipe
        # buffer of one machine.
        debate = self.root / "big ledger"
        debate.mkdir()
        (debate / "index.jsonl").write_text(
            '{"v":1,"t":"end","id":"x","round":2,"role":"gen","rc":0}\n' * 60000)
        for n in range(1, 200):
            (debate / f".round-{n}-gen.done").touch()
        probe = subprocess.run(
            ["bash", "-c",
             'set -euo pipefail; . "$1"; for n in 1 2 500; do '
             'rc=0; round_is_complete "$2" "$n" || rc=$?; printf "%s:%s " "$n" "$rc"; done',
             "bash", str(self.plugin / "lib" / "index.sh"), str(debate)],
            text=True, capture_output=True, timeout=120,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        # Sidecars cannot make round 1 complete; only round 2 is in the ledger.
        self.assertEqual(probe.stdout.strip(), "1:1 2:0 500:1", probe.stderr)

    def test_killed_run_leaves_a_start_with_no_end_and_the_round_reruns(self):
        # SIGKILL is the only signal that runs no trap, which is what makes the
        # half-written attempt deterministic.
        proc, _ready, release = self.start_blocked_debate(
            "-n", "2", "crash topic", new_session=True)
        debate = self.latest_debate()
        self.await_text(debate / "index.jsonl", '"t":"start"')
        os.killpg(proc.pid, signal.SIGKILL)  # the model and the tees outlive a bare kill
        proc.wait(timeout=30)
        release.touch()

        records = self.index_records(debate)
        self.assertEqual([r["t"] for r in records], ["start"])
        self.assertEqual(records[0]["round"], 1)
        self.assertEqual(self.sidecars(debate), [])

        # SIGKILL leaves the #45 lock behind and it is never reclaimed.
        refused = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(refused.returncode, 2, refused.stdout)
        self.assertTrue(self.lock_of(debate).is_symlink())
        self.lock_of(debate).unlink()

        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resuming from round 1", result.stderr)
        records = self.index_records(debate)
        self.assertEqual([r["t"] for r in records], ["start", "start", "end"])
        self.assertEqual(records[-1]["rc"], 0)
        self.assertNotEqual(records[0]["id"], records[1]["id"])

    def test_converged_run_records_only_the_rounds_it_ran(self):
        result = self.run_cli("debate.sh", "--until-converged", "-n", "6", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        debate = self.latest_debate()
        self.assertEqual(sorted(r["round"] for r in self.index_records(debate)),
                         [1, 1, 2, 2])

    def test_rotated_round_file_names_are_recorded(self):
        result = self.run_cli("debate.sh", "--rotate", "-n", "2", "t")
        self.assertEqual(result.returncode, 0, result.stderr)
        debate = self.latest_debate()
        self.assertEqual([r["file"] for r in self.index_records(debate)],
                         ["round-1-gen-agy.md", "round-1-gen-agy.md",
                          "round-2-crit-codex.md", "round-2-crit-codex.md"])

    # ── Run receipt (#61) ──────────────────────────────────────────────────

    def receipt_path(self):
        return self.root / f"debate-receipt-{len(list(self.root.glob('debate-receipt-*')))}"

    def test_receipt_reports_this_runs_directory_and_completed_critic(self):
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic",
                              DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(receipt.read_text())
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(Path(data["debate_dir"]), self.latest_debate())
        self.assertTrue(data["debate_dir"].startswith("/"))
        self.assertEqual(data["last_round"], 2)
        self.assertEqual(data["critic_round"], 2)
        self.assertEqual(data["critic_file"], "round-2-crit.md")
        self.assertTrue((Path(data["debate_dir"]) / data["critic_file"]).is_file())

    def test_receipt_records_the_rotated_transcript_name(self):
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "--rotate", "-n", "2", "t",
                              DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(receipt.read_text())["critic_file"],
                         "round-2-crit-codex.md")

    def test_receipt_pairs_null_critic_fields_when_none_completed(self):
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "-n", "1", "t", DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(receipt.read_text())
        self.assertEqual(data["last_round"], 1)
        self.assertIsNone(data["critic_round"])
        self.assertIsNone(data["critic_file"])

    def test_receipt_reports_the_round_a_converged_run_stopped_at(self):
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "--until-converged", "-n", "6", "t",
                              DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(receipt.read_text())
        self.assertEqual((data["last_round"], data["critic_round"]), (2, 2))

    def test_receipt_covers_the_whole_debate_not_one_dispatch(self):
        receipt = self.receipt_path()
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "t").returncode, 0)
        debate = self.latest_debate()
        # A continuation that runs only a generator round still reports the
        # critic round an earlier dispatch completed.
        result = self.run_cli("debate.sh", "--continue-from", str(debate), "-n", "1", "t",
                              DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(receipt.read_text())
        self.assertEqual((data["last_round"], data["critic_round"]), (3, 2))
        self.assertEqual(data["critic_file"], "round-2-crit.md")

    def test_receipt_accepts_a_custom_model_id_containing_dots(self):
        """A model id is caller-defined; `..` inside a basename escapes nothing."""
        self.config.write_text(json.dumps({
            "models": {"critic..v2": {"command": str(self.stub),
                                      "args": ["-p", "{prompt}"]}},
            "roles": {}}))
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "--rotate", "-n", "2",
                              "--primary-crit=critic..v2", "t",
                              DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(receipt.read_text())
        self.assertEqual(data["critic_file"], "round-2-crit-critic..v2.md")
        self.assertTrue((Path(data["debate_dir"]) / data["critic_file"]).is_file())

    def test_a_failed_run_publishes_no_receipt(self):
        receipt = self.receipt_path()
        result = self.run_cli("debate.sh", "-n", "2", "t", STUB_RC="9",
                              DEBATE_RECEIPT=str(receipt))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt.exists())

    def test_relative_receipt_path_is_refused_before_anything_is_created(self):
        result = self.run_cli("debate.sh", "-n", "2", "t", DEBATE_RECEIPT="receipt.json")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("DEBATE_RECEIPT must be absolute", result.stderr)
        self.assertFalse((self.workspace / ".debate-conductor").exists())

    def read_receipt(self, receipt):
        """Run the plugin's own strict reader over a receipt file."""
        return subprocess.run(
            ["bash", "-c", 'set -uo pipefail; . "$1"; debate_receipt_read "$2"',
             "bash", str(self.plugin / "lib" / "debate-result.sh"), str(receipt)],
            text=True, capture_output=True, timeout=60)

    def test_strict_reader_rejects_every_malformed_receipt(self):
        receipt = self.receipt_path()
        self.assertEqual(self.run_cli("debate.sh", "-n", "2", "t",
                                      DEBATE_RECEIPT=str(receipt)).returncode, 0)
        good = json.loads(receipt.read_text())
        debate = Path(good["debate_dir"])
        self.assertEqual(self.read_receipt(receipt).returncode, 0, "the real one must pass")

        (debate / "escape.md").write_text("elsewhere\n")
        # A real directory inside the debate dir, and a real transcript outside
        # it, so the traversal case below is only stopped by the slash rule.
        (debate / "round-2-crit-d").mkdir()
        escape_dir = debate.parent / "escape-target"
        escape_dir.mkdir()
        escape = escape_dir / "round-2-crit.md"
        escape.write_text("Verdict: OVERTURN\n")
        outside = self.root / "outside-round-2-crit.md"
        outside.write_text("outside\n")
        os.symlink(outside, debate / "round-2-crit-link.md")
        os.mkfifo(debate / "round-2-crit-fifo.md")

        # Missing keys are exercised from a *valid* null/null receipt: dropping
        # critic_file next to a numeric critic_round already fails the pairing
        # rule, so it never reaches has() (measured — removing the has() check
        # left this test green).
        nulled = dict(good, critic_round=None, critic_file=None)
        # Control characters have to be rejected inside jq, on the JSON string:
        # command substitution strips a trailing newline and drops NUL, so a
        # shell-side check sees the legitimate name (measured).
        newline_name = good["critic_file"] + chr(10)
        nul_name = "round-2-crit" + chr(0) + ".md"

        bad = {
            "two objects": json.dumps(good) + "\n" + json.dumps(good),
            "no critic_file key": json.dumps(
                {k: v for k, v in nulled.items() if k != "critic_file"}),
            "no critic_round key": json.dumps(
                {k: v for k, v in nulled.items() if k != "critic_round"}),
            "no last_round key": json.dumps(
                {k: v for k, v in nulled.items() if k != "last_round"}),
            "trailing newline in critic_file": json.dumps(
                dict(good, critic_file=newline_name)),
            "nul in critic_file": json.dumps(dict(good, critic_file=nul_name)),
            "trailing newline in debate_dir": json.dumps(
                dict(good, debate_dir=good["debate_dir"] + chr(10))),
            "wrong version": json.dumps(good | {"schema_version": 2}),
            "relative dir": json.dumps(good | {"debate_dir": "log/debate-1"}),
            "missing critic_file key": json.dumps(
                {k: v for k, v in good.items() if k != "critic_file"}),
            "unpaired null": json.dumps(good | {"critic_file": None}),
            "odd critic round": json.dumps(good | {"critic_round": 3}),
            "critic round past last": json.dumps(good | {"last_round": 1}),
            "zero last round": json.dumps(good | {"last_round": 0}),
            "traversal": json.dumps(good | {"critic_file": "../round-2-crit.md"}),
            # This one matches the round-N-crit-*.md shape (a `case` glob's *
            # spans slashes) *and* resolves to a real regular file outside the
            # debate directory, so every later check would pass: only the slash
            # rule rejects it — and that rule is what makes a `..` inside a
            # model id harmless.
            "traversal that resolves outside": json.dumps(
                good | {"critic_file":
                        f"round-2-crit-d/../../{escape_dir.name}/{escape.name}"}),
            "not a critic name": json.dumps(good | {"critic_file": "escape.md"}),
            "symlink": json.dumps(good | {"critic_file": "round-2-crit-link.md"}),
            "fifo": json.dumps(good | {"critic_file": "round-2-crit-fifo.md"}),
            "absent file": json.dumps(good | {"critic_file": "round-2-crit-gone.md"}),
            "empty": "",
        }
        for name, body in bad.items():
            with self.subTest(receipt=name):
                receipt.write_text(body)
                self.assertNotEqual(self.read_receipt(receipt).returncode, 0, name)

        # Malformed UTF-8 has to be caught before jq, which *replaces* a bad
        # byte with U+FFFD rather than refusing it: a receipt naming
        # round-2-crit-<0xFF>.md was accepted whenever the decoded name existed
        # on disk (measured). The fixture puts that file there, so the
        # filesystem check cannot mask a reader that let the bytes through.
        (debate / "round-2-crit-\ufffd.md").write_text("Verdict: STRENGTHEN\n")
        for field in ("critic_file", "debate_dir"):
            with self.subTest(receipt=f"invalid utf-8 in {field}"):
                marker = "round-2-crit-XX.md" if field == "critic_file" else good["debate_dir"] + "XX"
                raw = json.dumps(dict(good, **{field: marker})).encode()
                receipt.write_bytes(raw.replace(b"XX", b"\xff"))
                self.assertNotEqual(self.read_receipt(receipt).returncode, 0, field)

        receipt.write_text(json.dumps(nulled))
        self.assertEqual(self.read_receipt(receipt).returncode, 0,
                         "a paired-null receipt is valid")

    def test_completed_round_file_contract(self):
        """Driven straight at the helper — cheaper and sharper than debates."""
        def ask(lines, round_no=2, role="crit", sidecars=()):
            debate = self.root / f"crf {len(list(self.root.glob('crf *')))}"
            debate.mkdir()
            if lines is not None:
                (debate / "index.jsonl").write_text("".join(l + "\n" for l in lines))
            for name in sidecars:
                (debate / name).touch()
            return subprocess.run(
                ["bash", "-c",
                 'set -uo pipefail; . "$1"; completed_round_file "$2" "$3" "$4"',
                 "bash", str(self.plugin / "lib" / "index.sh"), str(debate),
                 str(round_no), role],
                text=True, capture_output=True, timeout=60)

        end = lambda name, rc=0, rnd=2, role="crit": json.dumps(
            {"v": 1, "t": "end", "round": rnd, "role": role, "rc": rc, "file": name})

        got = ask([end("round-2-crit.md")])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit.md"))
        # A failed attempt then a successful one: the successful file wins.
        got = ask([end("round-2-crit.md", rc=9), end("round-2-crit-codex.md")])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit-codex.md"))
        # The same name twice is one answer, not an ambiguity.
        got = ask([end("round-2-crit.md"), end("round-2-crit.md")])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit.md"))
        # Two *distinct* successful names are ambiguous and are not guessed at.
        got = ask([end("round-2-crit.md"), end("round-2-crit-codex.md")])
        self.assertNotEqual(got.returncode, 0)
        # A name that is only a control character is not a filename: it is
        # discarded before the count, so the real one still answers.
        got = ask([end(chr(10)), end("round-2-crit.md")])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit.md"))
        # Malformed lines are skipped, not fatal.
        got = ask(["not json", end("round-2-crit.md")])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit.md"))
        # No ledger: a sidecar supplies neither completion nor a filename.
        got = ask(None, sidecars=(".round-2-crit-codex.done",))
        self.assertEqual((got.returncode, got.stdout.strip()), (0, ""))
        # No successful record for this round: there is no sidecar fallback.
        got = ask([end("round-4-crit.md", rnd=4)], sidecars=(".round-2-crit.done",))
        self.assertEqual((got.returncode, got.stdout.strip()), (0, ""))
        # A disagreeing sidecar does not override an answer the ledger gave.
        got = ask([end("round-2-crit.md")], sidecars=(".round-2-crit-codex.done",))
        self.assertEqual((got.returncode, got.stdout.strip()), (0, "round-2-crit.md"))
        # Nothing completed: empty, and not an error.
        got = ask([end("round-2-crit.md", rc=9)])
        self.assertEqual((got.returncode, got.stdout.strip()), (0, ""))

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

    # What a logged-in claude answers inside codex-cli 0.157's seatbelt (#127).
    SANDBOX_AUTH = dict(STUB_AUTH='{"loggedIn":false,"authMethod":"none"}', STUB_AUTH_RC="1",
                        CODEX_SANDBOX="seatbelt")
    LOGIN_LINES = [
        "debate-conductor: Claude login unverified in this environment (auth status: "
        "loggedIn=false, rc=1, CODEX_SANDBOX=seatbelt); no invocation started",
        "debate-conductor: a sandbox can hide the login (for example macOS Keychain); rerun this same "
        "command once with host approval, or choose a non-Claude model for this role. If an "
        "approved run still fails, check claude auth status in your own terminal.",
    ]

    def login_lines(self, result):
        return [line for line in result.stderr.splitlines() if line.startswith("debate-conductor: ")]

    def test_sandboxed_login_stops_each_entry_point_before_any_artifact(self):
        for script, args, env in (
                ("debate.sh", ("-n", "2", "fixture topic"), {}),
                ("ask-critic.sh", ("fixture",), {}),
                ("ask-generator.sh", ("fixture",), dict(DEBATE_GENERATOR_MODEL="claude"))):
            with self.subTest(script=script):
                self.calls.unlink(missing_ok=True)
                result = self.run_cli(script, *args, DEBATE_CONDUCTOR_PM_HOST="codex",
                                      **self.SANDBOX_AUTH, **env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.login_lines(result), self.LOGIN_LINES)
                self.assertEqual(self.recorded(), [["auth", "status", "--json"]])
                self.assertFalse((self.workspace / ".debate-conductor").exists())

    def test_sandboxed_login_leaves_a_continued_debate_untouched(self):
        result = self.run_cli("debate.sh", "-n", "2", "fixture topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        first_dir = self.latest_debate()
        link = self.workspace / ".debate-conductor/log/host-test/latest-debate"
        link_target = os.readlink(link)
        ledger = (first_dir / "index.jsonl").read_bytes()
        files = sorted(p.name for p in first_dir.iterdir())
        self.calls.unlink(missing_ok=True)

        result = self.run_cli("debate.sh", "--continue-from", str(first_dir), "-n", "2",
                              "fixture topic", DEBATE_CONDUCTOR_PM_HOST="codex",
                              DEBATE_CRITIC_MODEL="claude", **self.SANDBOX_AUTH)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.login_lines(result), self.LOGIN_LINES)
        self.assertEqual(self.recorded(), [["auth", "status", "--json"]])
        self.assertEqual(os.readlink(link), link_target)
        self.assertEqual((first_dir / "index.jsonl").read_bytes(), ledger)
        self.assertEqual(sorted(p.name for p in first_dir.iterdir()), files)

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
