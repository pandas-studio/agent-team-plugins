"""Research setup/recovery contracts; all CLIs and settings are fixtures."""

import importlib.util
import io
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1] / "dev-trio"
SPEC = importlib.util.spec_from_file_location("research_doctor", PLUGIN / "lib/research_doctor.py")
DOCTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCTOR)


class ResearchDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="research diagnostics ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.plugin = self.root / "installed plugin"
        shutil.copytree(PLUGIN, self.plugin)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.config = self.root / "models.json"
        self.config.write_text('{"models":{},"roles":{}}')
        self.settings = self.root / "settings.json"
        self.calls = self.root / "calls"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.stub = self.bin / "agy"
        self.stub.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$DIAG_CALLS"\n'
            'if [ "$1" = --version ]; then echo "fixture CLI 1.2.7"; exit 0; fi\n'
            'printf "%s" "${DIAG_ANSWER:-}"\n'
            'printf "%s" "${DIAG_STDERR:-}" >&2\n'
            'exit "${DIAG_RC:-0}"\n'
        )
        self.stub.chmod(0o755)
        shutil.copyfile(self.stub, self.bin / "claude")
        (self.bin / "claude").chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("DEV_TRIO_", "AGENT_TEAM", "AGY_", "CLAUDE_", "CODEX_",
             "RESEARCHER_", "REVIEWER_", "MANIFEST_", "DIAG_"))}
        self.env.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            AGENT_TEAM="diagnostic-test", TMUX="", DEV_TRIO_PM_HOST="codex",
            AGENT_TEAM_MODELS_CONFIG=str(self.config), DIAG_CALLS=str(self.calls),
        )

    def run_script(self, script="dev-trio-doctor.sh", *args, **overrides):
        before = self.config.read_bytes()
        result = subprocess.run(
            [str(self.plugin / "bin" / script), *args], cwd=self.workspace,
            env=self.env | overrides, input="", text=True, capture_output=True, timeout=15, check=False,
        )
        self.assertEqual(self.config.read_bytes(), before)
        return result

    def check_settings(self, content):
        if content is not None:
            self.settings.write_text(content)
        output = io.StringIO()
        with redirect_stdout(output):
            valid = DOCTOR.check_settings(self.settings)
        if content is not None:
            self.assertEqual(self.settings.read_text(), content)
        return valid, output.getvalue()

    def test_missing_settings_are_unverified_not_failure(self):
        valid, output = self.check_settings(None)
        self.assertTrue(valid)
        self.assertIn("unverified", output)
        self.assertFalse(self.settings.exists())

    def test_invalid_settings_fail_without_repair(self):
        for content in ('{', '[]', '{"permissions":null}', '{"permissions":{"allow":"*"}}',
                        '{"permissions":{"deny":[null]}}'):
            with self.subTest(content=content):
                valid, output = self.check_settings(content)
                self.assertFalse(valid)
                self.assertIn("[FAIL]", output)

    def test_legacy_rules_are_advisory_and_private_targets_are_not_dumped(self):
        content = json.dumps({"permissions": {
            "allow": ["command(secret-target)", "unsandboxed(private-command)"],
            "ask": ["command(*)"], "deny": []},
            "toolPermission": "request-review", "enableTerminalSandbox": True,
            "unrelated": "keep-this"})
        valid, output = self.check_settings(content)
        self.assertTrue(valid)
        self.assertIn("Legacy unsandboxed", output)
        self.assertIn("do not migrate", output)
        self.assertIn("Ask/deny rules can override", output)
        self.assertNotIn("private-command", output)
        self.assertNotIn("secret-target", output)

    def test_vendor_probe_only_requests_version_and_leaves_settings_intact(self):
        content = '{"permissions":{"allow":[]}}'
        self.settings.write_text(content)
        result = subprocess.run(
            ["python3", str(self.plugin / "lib/research_doctor.py"), "agy",
             str(self.stub), "true", str(self.settings)],
            env=self.env, text=True, capture_output=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), "--version\n")
        self.assertIn("fixture CLI 1.2.7", result.stdout)
        self.assertIn("[NOT_CHECKED] Research permissions:", result.stdout)
        self.assertIn(f"Guide: {self.plugin.resolve() / 'README.md'}#research-troubleshooting", result.stdout)
        self.assertEqual(self.settings.read_text(), content)
        self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_other_vendor_does_not_read_agy_settings(self):
        self.settings.write_text("corrupt")
        result = subprocess.run(
            ["python3", str(self.plugin / "lib/research_doctor.py"), "claude",
             str(self.bin / "claude"), "true", str(self.settings)],
            env=self.env, text=True, capture_output=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(str(self.settings), result.stdout)
        self.assertEqual(self.calls.read_text(), "--version\n")

    def test_summary_separates_setup_from_unchecked_execution_and_permissions(self):
        cases = (
            (None, 0),  # No settings file is allowed; defaults remain unverified.
            ('{}', 0),
            ('{"permissions":{"allow":[]}}', 0),
            ('{"permissions":{"allow":["read_url(private.example)"]}}', 0),
            ('{"permissions":{"deny":["read_url(*)"]}}', 0),
            ('{"toolPermission":"request-review"}', 0),
            ('{', 1),
            ('{"permissions":{"allow":"read_url(*)"}}', 1),
        )
        for content, expected_rc in cases:
            with self.subTest(content=content):
                if content is not None:
                    self.settings.write_text(content)
                result = subprocess.run(
                    ["python3", str(self.plugin / "lib/research_doctor.py"), "agy",
                     str(self.stub), "true", str(self.settings)],
                    env=self.env, text=True, capture_output=True, timeout=15, check=False,
                )
                status = "PASS" if expected_rc == 0 else "FAIL"
                outcome = "passed" if expected_rc == 0 else "failed"
                self.assertEqual(result.returncode, expected_rc, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-3:], [
                    f"[{status}] Installation/config checks {outcome} (see warnings/skipped checks above).",
                    "[NOT_CHECKED] Host execution: selected CLI startup under the current host policy.",
                    "[NOT_CHECKED] Research permissions: effective tool grants and actual research access.",
                ])
                self.assertNotIn("private.example", result.stdout)
                if content is None:
                    self.assertFalse(self.settings.exists())
                else:
                    self.assertEqual(self.settings.read_text(), content)
        self.assertEqual(self.calls.read_text().splitlines(), ["--version"] * len(cases))

    def test_custom_binary_is_never_probed_or_assumed_to_use_agy_settings(self):
        result = self.run_script("dev-trio-doctor.sh", "--research", AGY_CLI=str(self.stub))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Custom adapter/CLI override", result.stdout)
        self.assertNotIn("agy settings:", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_custom_adapter_with_builtin_binary_name_is_not_probed(self):
        self.config.write_text(json.dumps({"models": {"custom": {
            "command": "agy", "args": ["--my-prompt", "{prompt}"]}},
            "roles": {"dev-trio.researcher": "custom"}}))
        result = self.run_script("dev-trio-doctor.sh", "--research")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_modified_builtin_is_not_probed(self):
        self.config.write_text(json.dumps({"models": {"agy": {
            "command": "agy", "args": ["--custom", "{prompt}"]}}}))
        result = self.run_script("dev-trio-doctor.sh", "--research")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_focused_check_does_not_authenticate_or_require_reviewer(self):
        result = self.run_script("dev-trio-doctor.sh", "--research",
                                 DEV_TRIO_RESEARCHER_MODEL="claude",
                                 DEV_TRIO_REVIEWER_MODEL="unregistered")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), "--version\n")
        self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_missing_binary_or_model_fails_without_dispatch(self):
        for overrides in ({"RESEARCHER_CLI": str(self.root / "missing")},
                          {"DEV_TRIO_RESEARCHER_MODEL": "unregistered"}):
            with self.subTest(overrides=overrides):
                result = self.run_script("dev-trio-doctor.sh", "--research", **overrides)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("[FAIL]" if "RESEARCHER_CLI" in overrides else "unregistered", result.stdout)
                self.assertFalse(self.calls.exists())

    def test_invalid_registry_is_not_silently_ignored(self):
        for content in ('{', '[]', '{"models":[]}'):
            with self.subTest(content=content):
                self.config.write_text(content)
                result = self.run_script("dev-trio-doctor.sh", "--research")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(self.calls.exists())

    def test_invalid_model_definition_reports_resolution_failure(self):
        for definition in ("invalid", {}):
            with self.subTest(definition=definition):
                self.config.write_text(json.dumps({"models": {"agy": definition}}))
                result = self.run_script("dev-trio-doctor.sh", "--research")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("researcher binary resolution failed for model: agy", result.stdout)
                self.assertIn("No invocation started", result.stdout)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_doctor_rejects_unknown_arguments(self):
        for args in (("--research", "--apply"), ("--unknown",)):
            result = self.run_script("dev-trio-doctor.sh", *args)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(self.calls.exists())

    def test_failed_research_codes_do_not_become_permission_diagnoses(self):
        for cli_rc, answer, diagnostic, expected in (
            (1, "", "CLI failed to start - listen tcp 127.0.0.1:0: bind: operation not permitted", 1),
            (0, "", "", 5),
            (0, "", ('jetski: no output produced — a tool required the "read_url" permission '
                     'that headless mode cannot prompt for, so it was auto-denied.'), 5),
            (0, "", 'jetski: headless command permission auto-denied', 5),
            (5, "partial answer", "unrelated failure", 5),
            (6, "partial answer", "vendor failure", 6),
            (9, "", "boom", 9),
        ):
            with self.subTest(cli_rc=cli_rc, diagnostic=diagnostic):
                before = set(self.workspace.glob(".dev-trio/log/*/*.run.json"))
                result = self.run_script("ask-researcher.sh", "question quoting a permission error",
                                         DIAG_RC=str(cli_rc), DIAG_ANSWER=answer,
                                         DIAG_STDERR=diagnostic)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout.strip(), "")
                new = set(self.workspace.glob(".dev-trio/log/*/*.run.json")) - before
                self.assertEqual(len(new), 1)
                run = json.loads(new.pop().read_text())
                self.assertEqual(run["completion"]["exit_code"], expected)
                self.assertEqual(run["completion"]["reason"], "failed")
                self.assertIn(run["log_path"], result.stderr)
                self.assertIn("--research", result.stderr)
                if diagnostic:
                    self.assertNotIn(diagnostic, result.stdout)
                if expected == 5:
                    self.assertIn("rc=5 alone does not establish permission denial", result.stderr)
                # The emitted command is copyable even with spaces in plugin/config paths.
                command = next(line.strip() for line in result.stderr.splitlines()
                               if line.startswith("  DEV_TRIO_PM_HOST="))
                argv = shlex.split(command)
                self.assertEqual(argv[-2:], [str(self.plugin / "bin/dev-trio-doctor.sh"), "--research"])
                self.assertIn("AGENT_TEAM_MODELS_CONFIG=" + str(self.config), argv)

    def test_success_keeps_diagnostics_out_of_answer_and_reason_ok(self):
        result = self.run_script("ask-researcher.sh",
                                 'Explain "bind: operation not permitted" and "read_url auto-denied"',
                                 DIAG_ANSWER="An answer.",
                                 DIAG_STDERR="a CLI diagnostic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "An answer.")
        self.assertNotIn("--research", result.stderr)
        run = json.loads(next(self.workspace.glob(".dev-trio/log/*/*.run.json")).read_text())
        self.assertEqual(run["completion"]["reason"], "ok")
        self.assertEqual(Path(run["final_path"]).read_text(), "An answer.")
        self.assertIn("a CLI diagnostic", Path(run["log_path"]).read_text())

    def test_startup_failure_has_setup_help_without_claiming_a_run_log(self):
        for override in ("RESEARCHER_CLI", "AGY_CLI"):
            with self.subTest(override=override):
                result = self.run_script("ask-researcher.sh", "question", **{override: "/missing/cli"})
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("no run log created", result.stderr)
                self.assertIn("--research", result.stderr)
                self.assertIn(f"{override}=/missing/cli", result.stderr)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.workspace / ".dev-trio").exists())


if __name__ == "__main__":
    unittest.main()
