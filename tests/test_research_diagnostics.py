"""Research setup/recovery contracts; all CLIs and settings are fixtures."""

import importlib.util
import io
import json
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
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
            # Like agy, record the conversation in the pinned --log-file.
            'if [ "$1" = --log-file ] && [ -n "${DIAG_CONVERSATION:-}" ]; then\n'
            '  printf "I0923 1 server.go:1239] Created conversation %s\\n" "$DIAG_CONVERSATION" > "$2"\n'
            'fi\n'
            'if [ -n "${DIAG_READY:-}" ]; then : > "$DIAG_READY"; fi\n'
            # Hold until the test releases it (#195): a handshake, not a timed
            # sleep. A hold that times out fails the run with 97.
            'if [ -n "${DIAG_RELEASE:-}" ]; then w=0; until [ -e "$DIAG_RELEASE" ]; do\n'
            '  sleep 0.05; w=$((w+1)); [ "$w" -lt 600 ] || { : > "$DIAG_RELEASE.timeout"; exit 97; }; done; fi\n'
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
        self.agy_home = self.root / "agy home"
        (self.agy_home / "log").mkdir(parents=True)
        self.env.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            DEV_TRIO_AGY_HOME=str(self.agy_home),
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
                if "RESEARCHER_CLI" in overrides:
                    self.assertEqual(result.stdout.splitlines()[-3:], [
                        "[FAIL] Installation/config checks failed (see warnings/skipped checks above).",
                        "[NOT_CHECKED] Host execution: selected CLI startup under the current host policy.",
                        "[NOT_CHECKED] Research permissions: effective tool grants and actual research access.",
                    ])
                self.assertFalse(self.calls.exists())

    def test_invalid_registry_is_not_silently_ignored(self):
        for content in ('{', '[]', '{"models":[]}'):
            with self.subTest(content=content):
                self.config.write_text(content)
                result = self.run_script("dev-trio-doctor.sh", "--research")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(self.calls.exists())

    def test_invalid_model_definition_reports_resolution_failure(self):
        # A definition that is not an object makes the whole config malformed
        # (#133); an object without args fails at binary resolution.
        for definition, message in (
                ("invalid", "(config has a model definition that is not a JSON object)"),
                ({}, "researcher binary resolution failed for model: agy")):
            with self.subTest(definition=definition):
                self.config.write_text(json.dumps({"models": {"agy": definition}}))
                result = self.run_script("dev-trio-doctor.sh", "--research")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(message, result.stdout)
                self.assertIn("No invocation started", result.stdout)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.workspace / ".dev-trio").exists())

    def test_smoke_only_skips_live_login_probe(self):
        # The fixture claude answers `auth status` with nothing, like a
        # logged-out install; a Codex PM makes the doctor ask it.
        result = self.run_script("dev-trio-doctor.sh")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("reviewer CLI/login check failed", result.stdout)
        self.assertIn("auth status --json", self.calls.read_text())
        self.calls.unlink()
        result = self.run_script("dev-trio-doctor.sh", "--smoke-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("role CLI/login checks skipped (--smoke-only)", result.stdout)
        self.assertNotIn("✗", result.stdout)
        # The smokes themselves ran: section 3's manifest and section 4's last check.
        self.assertIn("ask-researcher.sh stub run completed (rc=0)", result.stdout)
        self.assertIn("variant=dev-trio-research", result.stdout)
        self.assertIn("remove --force --fallback codex reassigns role then deletes", result.stdout)
        self.assertFalse(self.calls.exists())

    def test_smoke_only_ignores_the_callers_pm_host(self):
        result = self.run_script("dev-trio-doctor.sh", DEV_TRIO_PM_HOST="bogus")
        self.assertEqual(result.returncode, 2)
        result = self.run_script("dev-trio-doctor.sh", "--smoke-only", DEV_TRIO_PM_HOST="bogus")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_doctor_rejects_unknown_arguments(self):
        for args in (("--research", "--apply"), ("--unknown",), ("--smoke-only", "--research"),
                     ("--research", "--smoke-only"), ("--smoke",)):
            result = self.run_script("dev-trio-doctor.sh", *args)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(self.calls.exists())

    NOTICE = ('jetski: no output produced — a tool required the "command" permission '
              'that headless mode cannot prompt for, so it was auto-denied.')
    CONVERSATION = "0179d9db-25b9-4d06-97c2-4b7f60b8eb8d"

    def record_denial(self, target='lsof -p $$ || pwd'):
        logs = self.agy_home / "brain" / self.CONVERSATION / ".system_generated/logs"
        logs.mkdir(parents=True)
        error = f"permission check failed for command {json.dumps(target)}: user denied permission"
        (logs / "transcript_full.jsonl").write_text(json.dumps({"status": "ERROR", "error": error}) + "\n")

    def test_recorded_denial_names_its_target(self):
        self.record_denial()
        result = self.run_script("ask-researcher.sh", "question", DIAG_RC="0", DIAG_ANSWER="",
                                 DIAG_STDERR=self.NOTICE, DIAG_CONVERSATION=self.CONVERSATION)
        self.assertEqual(result.returncode, 5, result.stderr)
        lines = result.stderr.splitlines()
        self.assertIn("[ask-researcher] agy denied: command(lsof -p $$ || pwd)", lines)
        self.assertIn(f"[ask-researcher] agy conversation: {self.CONVERSATION}", lines)
        self.assertNotIn("rc=5 alone does not establish permission denial", result.stderr)
        manifest = json.loads(next(self.workspace.glob(".dev-trio/log/*/*.manifest.json")).read_text())
        self.assertIn({"kind": "agy-conversation", "value": self.CONVERSATION}, manifest["inputs"])

    def test_denial_is_named_through_the_temporary_log(self):
        # #193: agy's log directory cannot take the pinned log (a host sandbox);
        # the private temporary one still carries the conversation id.
        shutil.rmtree(self.agy_home / "log")
        tmp = self.root / "tmp"
        tmp.mkdir()
        self.record_denial()
        result = self.run_script("ask-researcher.sh", "question", DIAG_RC="0", DIAG_ANSWER="",
                                 DIAG_STDERR=self.NOTICE, DIAG_CONVERSATION=self.CONVERSATION,
                                 TMPDIR=str(tmp))
        self.assertEqual(result.returncode, 5, result.stderr)
        lines = result.stderr.splitlines()
        self.assertIn("[ask-researcher] agy denied: command(lsof -p $$ || pwd)", lines)
        self.assertIn(f"[ask-researcher] agy conversation: {self.CONVERSATION}", lines)
        self.assertIn("[ask-researcher] could not create agy's per-run log under", result.stderr)
        self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    # A hold for shell shims (#195): readiness, then an external waiter that a
    # process-group signal ends at once. A waiter that times out leaves a
    # marker the test checks, so a late test fails instead of drifting.
    # hold returns 97 only when it timed out; a waiter ended by a signal counts
    # as released.
    HOLD = ('hold() { : > "$READY"; sh -c \'w=0; until [ -e "$RELEASE" ]; do sleep 0.05; '
            'w=$((w+1)); [ "$w" -lt 600 ] || { : > "$READY.timeout"; exit 97; }; done\'; '
            '[ "$?" -ne 97 ] || return 97; return 0; }\n')

    def wait_for(self, path, what, proc):
        deadline = time.monotonic() + 15
        while not path.exists():
            if proc.poll() is not None or time.monotonic() > deadline:
                self.fail(f"{what} (rc {proc.poll()}): {proc.communicate()[1] if proc.poll() is not None else ''}")
            time.sleep(0.02)

    def test_temporary_log_is_removed_when_the_run_is_interrupted(self):
        shutil.rmtree(self.agy_home / "log")
        for sig, code in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(signal=sig.name):
                tmp = self.root / f"tmp-{sig.name}"
                tmp.mkdir()
                ready, release = self.root / f"ready-{sig.name}", self.root / f"release-{sig.name}"
                proc = subprocess.Popen(
                    [str(self.plugin / "bin" / "ask-researcher.sh"), "question"], cwd=self.workspace,
                    env=self.env | dict(TMPDIR=str(tmp), DIAG_ANSWER="answer",
                                        DIAG_READY=str(ready), DIAG_RELEASE=str(release)),
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                try:
                    # The CLI is running: the wrapper's traps and the fallback are set.
                    self.wait_for(ready, "the CLI never started", proc)
                    self.assertEqual(len(list(tmp.glob("dev-trio-agy.*/cli-dev-trio-research-*.log"))), 1)
                    proc.send_signal(sig)
                    release.touch()
                    _, err = proc.communicate(timeout=15)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.communicate()
                # The wrapper's own signal handling would hide a hold that timed out.
                self.assertFalse(Path(f"{release}.timeout").exists(), "the CLI's hold timed out")
                self.assertEqual(proc.returncode, code, err)
                self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    def run_helper(self, shims, sig, tag, path_dir=None):
        """Run the helper alone in its own process group with SHIMS defined
        (and PATH_DIR first on PATH), wait for a hold, signal the group, then
        release any hold that survived the signal. Returns (out, tmp)."""
        tmp = self.root / f"tmp-{tag}-{sig.name}"
        tmp.mkdir()
        ready, release = self.root / f"ready-{tag}-{sig.name}", self.root / f"release-{tag}-{sig.name}"
        script = (f'. {shlex.quote(str(self.plugin / "lib" / "host.sh"))}\n' + self.HOLD + shims
                  + 'dev_trio_agy_cli_log_private research-x\n')
        env = self.env | dict(TMPDIR=str(tmp), READY=str(ready), RELEASE=str(release))
        if path_dir:
            env["PATH"] = f"{path_dir}{os.pathsep}{env['PATH']}"
        proc = subprocess.Popen(["/bin/bash", "-c", script], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.wait_for(ready, "the helper never reached the hold", proc)
            self.assertEqual(len(list(tmp.glob("dev-trio-agy.*"))), 1)
            os.killpg(proc.pid, sig)
            release.touch()
            out, err = proc.communicate(timeout=15)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
        self.assertFalse(Path(f"{ready}.timeout").exists(), "the hold timed out")
        return out, tmp

    def test_fallback_helper_removes_its_allocation_when_interrupted(self):
        # A signal while the helper validates its directory: its abort traps
        # remove what it made.
        shims = 'dev_trio_prepare_log_dir() { hold || return 97; printf "%s\\n" "$1"; }\n'
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                out, tmp = self.run_helper(shims, sig, "validate")
                self.assertEqual(out, "")
                self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    def test_fallback_helper_leaves_nothing_when_interrupted_at_creation(self):
        # #195: a signal to the process group right after the directory is
        # created, before the helper holds its name. mktemp is held with its
        # real output captured and unprinted, and an external mkdir is held
        # after creating the directory, before reporting its status. With mktemp
        # -d allocating inside a command substitution, or with mkdir killable
        # there, this left one empty directory.
        fake = self.root / "fake-bin"
        fake.mkdir(exist_ok=True)
        (fake / "mkdir").write_text(
            "#!/bin/bash\n" + self.HOLD +
            '/bin/mkdir "$@" || exit\n'
            'case "${@: -1}" in *dev-trio-agy.*) hold || exit 97 ;; esac\n')
        (fake / "mkdir").chmod(0o755)
        shims = ('mktemp() { local out; out=$(command mktemp "$@") || return; '
                 'case "$out" in *dev-trio-agy.*) [ ! -d "$out" ] || hold || return 97 ;; esac; '
                 'printf "%s\\n" "$out"; }\n')
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                out, tmp = self.run_helper(shims, sig, "create", path_dir=fake)
                self.assertEqual(out, "")
                self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    def test_fallback_helper_honours_a_signal_sent_to_it_alone(self):
        # A signal to the helper alone, at creation and at validation: it must
        # end with the signal's code and leave nothing. The process-group tests
        # above cannot tell this apart, since a pending signal plus a failed
        # validation also cleans up; here nothing else fails, so only the
        # abort traps can.
        fake = self.root / "fake-bin-self"
        fake.mkdir(exist_ok=True)
        # The helper execs mkdir, so this process's parent is the helper.
        (fake / "mkdir").write_text(
            "#!/bin/bash\n" + self.HOLD +
            '/bin/mkdir "$@" || exit\n'
            'case "${@: -1}" in *dev-trio-agy.*) echo "$PPID" > "$HELPER_PID"; hold || exit 97 ;; esac\n')
        (fake / "mkdir").chmod(0o755)
        phases = {
            "create": ("", fake),
            # prepare runs in a command substitution under the helper; the
            # waiter's grandparent is the helper.
            "validate": ('_dev_trio_real_prepare=$(declare -f dev_trio_prepare_log_dir)\n'
                         'eval "${_dev_trio_real_prepare/dev_trio_prepare_log_dir/_real_prepare}"\n'
                         'dev_trio_prepare_log_dir() { '
                         'sh -c \'ps -o ppid= -p "$PPID"\' | tr -d " " > "$HELPER_PID"; '
                         'hold || return 97; _real_prepare "$@"; }\n', None),
        }
        for phase, (shims, path_dir) in phases.items():
            for sig, code in ((signal.SIGHUP, 129), (signal.SIGINT, 130), (signal.SIGTERM, 143)):
                with self.subTest(phase=phase, signal=sig.name):
                    tag = f"self-{phase}-{sig.name}"
                    tmp = self.root / f"tmp-{tag}"
                    tmp.mkdir()
                    ready, release = self.root / f"ready-{tag}", self.root / f"release-{tag}"
                    helper_pid = self.root / f"pid-{tag}"
                    script = (f'. {shlex.quote(str(self.plugin / "lib" / "host.sh"))}\n' + self.HOLD + shims
                              + 'dev_trio_agy_cli_log_private research-x\necho "rc=$?" >&2\n')
                    env = self.env | dict(TMPDIR=str(tmp), READY=str(ready), RELEASE=str(release),
                                          HELPER_PID=str(helper_pid))
                    if path_dir:
                        env["PATH"] = f"{path_dir}{os.pathsep}{env['PATH']}"
                    proc = subprocess.Popen(["/bin/bash", "-c", script], env=env, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, text=True, start_new_session=True)
                    try:
                        self.wait_for(ready, "the helper never reached the hold", proc)
                        self.wait_for(helper_pid, "the helper's pid was not recorded", proc)
                        os.kill(int(helper_pid.read_text().strip()), sig)
                        release.touch()
                        out, err = proc.communicate(timeout=15)
                    finally:
                        if proc.poll() is None:
                            os.killpg(proc.pid, signal.SIGKILL)
                            proc.communicate()
                    self.assertFalse(Path(f"{ready}.timeout").exists(), "the hold timed out")
                    self.assertEqual(out, "", err)
                    self.assertIn(f"rc={code}", err.splitlines())
                    self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    def test_wrapper_hangup_during_fallback_allocation_leaves_nothing(self):
        # SIGHUP to the wrapper alone while the helper validates: the wrapper
        # waits for the handover and its EXIT trap removes the directory.
        shutil.rmtree(self.agy_home / "log")
        tmp = self.root / "tmp-hup"
        tmp.mkdir()
        ready, release = self.root / "hup-ready", self.root / "hup-release"
        host = self.plugin / "lib" / "host.sh"
        host.write_text(host.read_text() + (
            '\n' + self.HOLD +
            '_dev_trio_real_prepare=$(declare -f dev_trio_prepare_log_dir)\n'
            'eval "${_dev_trio_real_prepare/dev_trio_prepare_log_dir/_dev_trio_real_prepare_log_dir}"\n'
            'dev_trio_prepare_log_dir() {\n'
            '  case "$1" in *dev-trio-agy.*) hold || return 97 ;; esac\n'
            '  _dev_trio_real_prepare_log_dir "$@"\n'
            '}\n'))
        proc = subprocess.Popen(
            [str(self.plugin / "bin" / "ask-researcher.sh"), "question"], cwd=self.workspace,
            env=self.env | dict(TMPDIR=str(tmp), READY=str(ready), RELEASE=str(release), DIAG_ANSWER="answer"),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(ready, "the helper never reached validation", proc)
            proc.send_signal(signal.SIGHUP)
            release.touch()
            _, err = proc.communicate(timeout=15)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        self.assertFalse(Path(f"{ready}.timeout").exists(), "the hold timed out")
        self.assertEqual(proc.returncode, 129, err)
        self.assertFalse(self.calls.exists(), "the CLI must not start after a hangup")
        self.assertEqual(list(tmp.glob("dev-trio-agy.*")), [])

    def test_notice_quoted_in_the_question_is_not_evidence(self):
        # The transcript does record a denial, but this run printed no notice:
        # only the question quotes it, and that sits before the run's output.
        self.record_denial()
        result = self.run_script("ask-researcher.sh", f"Why did I see this?\n{self.NOTICE}", DIAG_RC="0",
                                 DIAG_ANSWER="", DIAG_STDERR="", DIAG_CONVERSATION=self.CONVERSATION)
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertNotIn("agy denied:", result.stderr)
        self.assertIn("rc=5 alone does not establish permission denial", result.stderr)

    def test_notice_without_a_recorded_target_keeps_the_old_hint(self):
        result = self.run_script("ask-researcher.sh", "question", DIAG_RC="0", DIAG_ANSWER="",
                                 DIAG_STDERR=self.NOTICE, DIAG_CONVERSATION=self.CONVERSATION)
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertNotIn("agy denied:", result.stderr)
        self.assertIn("rc=5 alone does not establish permission denial", result.stderr)

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
