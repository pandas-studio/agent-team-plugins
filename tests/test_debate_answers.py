"""Answer/diagnostic boundaries, using recording CLIs without provider calls."""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "debate-conductor"
ANSWER = "A substantive answer.\nVerdict: RECONSIDER\n"
NOISE = (ROOT / "tests/fixtures/debate-cli-console.txt").read_text()


class DebateAnswerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="debate answers ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.capture = self.root / "capture"
        self.capture.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.stub = self.root / "model cli"
        self.stub.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys, time\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['STUB_CALLS'], 'a') as f:\n"
            "    f.write(json.dumps(args) + '\\n')\n"
            "native = '--output-last-message' in args\n"
            "print(os.environ['STUB_NOISE'], file=sys.stderr, flush=True)\n"
            "if native:\n"
            "    print(os.environ['STUB_NOISE'], flush=True)\n"
            "    final = pathlib.Path(args[args.index('--output-last-message') + 1])\n"
            "    mode = os.environ.get('STUB_FINAL_MODE', 'answer')\n"
            "    if mode == 'missing': final.unlink(missing_ok=True)\n"
            "    elif mode == 'directory':\n"
            "        final.mkdir()\n"
            "    elif mode == 'fifo': os.mkfifo(final)\n"
            "    elif mode == 'dangling': final.symlink_to(final.parent / 'absent')\n"
            "    elif mode == 'unreadable':\n"
            "        final.write_text(os.environ['STUB_ANSWER']); final.chmod(0)\n"
            "    elif mode == 'blank': final.write_text(' \\n\\t')\n"
            "    else: final.write_text(os.environ['STUB_ANSWER'])\n"
            "else:\n"
            "    print(os.environ['STUB_ANSWER'], end='', flush=True)\n"
            "if os.environ.get('STUB_READY'):\n"
            "    pathlib.Path(os.environ['STUB_READY']).touch()\n"
            "    while not pathlib.Path(os.environ['STUB_RELEASE']).exists(): time.sleep(.02)\n"
            "sys.exit(int(os.environ.get('STUB_RC', '0')))\n"
        )
        self.stub.chmod(0o755)
        self.config = self.root / "models.json"
        self.config.write_text(json.dumps({"models": {
            "custom-final": {"command": str(self.stub), "args": ["{prompt}"],
                             "final_args": ["--output-last-message", "{final}", "{prompt}"]},
            "custom-stdout": {"command": str(self.stub), "args": ["{prompt}"]},
        }}))
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("DEBATE_", "AGENT_TEAM", "ANTHROPIC_", "CLAUDE_", "CODEX_",
             "CRITIC_", "GENERATOR_", "AGY_", "STUB_", "REGISTRY_"))}
        self.env.update(
            AGENT_TEAM="answers", TMUX="", TMPDIR=str(self.capture),
            AGENT_TEAM_MODELS_CONFIG=str(self.config), AGY_CLI=str(self.stub),
            CODEX_CLI=str(self.stub), STUB_CALLS=str(self.calls),
            STUB_ANSWER=ANSWER, STUB_NOISE=NOISE,
        )

    def run_cli(self, relative, *args, timeout=60, **env):
        with subprocess.Popen(
            ["/bin/bash", str(PLUGIN / relative), *args], cwd=self.root,
            env=self.env | env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
        ) as proc:
            try:
                out, err = proc.communicate("", timeout=timeout)
            except subprocess.TimeoutExpired:
                # A regressed FIFO guard can strand grep and its parent shells.
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise
            return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)

    def logs(self):
        return self.root / ".debate-conductor/log/answers"

    def assert_clean(self, text):
        for token in ("TOOL_OUTPUT_SENTINEL", "CONSOLE_ANSWER_SENTINEL"):
            self.assertNotIn(token, text)

    def test_native_both_roles_and_custom_adapter_ignore_console(self):
        for role in ("generator", "critic"):
            for model in ("codex", "codex-no-memories", "custom-final"):
                with self.subTest(role=role, model=model):
                    result = self.run_cli(f"lib/ask-{role}.sh", "--model", model, "topic")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, ANSWER)
                    self.assert_clean(result.stderr)
        for path in self.logs().glob("*.log"):
            self.assert_clean(path.read_text())
        self.assertFalse(list(self.logs().glob("*.raw.log")))
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_native_role_overrides_require_capture_argument_forwarding(self):
        wrapper = self.root / "role wrapper"
        for role in ("generator", "critic"):
            for forwarding in (True, False):
                with self.subTest(role=role, forwarding=forwarding):
                    wrapper.write_text(
                        f"#!{sys.executable}\n"
                        "import os, sys\n"
                        + ("os.execv(os.environ['CODEX_CLI'], [os.environ['CODEX_CLI'], *sys.argv[1:]])\n"
                           if forwarding else "print(sys.argv[3])\n")
                    )
                    wrapper.chmod(0o755)
                    result = self.run_cli(f"lib/ask-{role}.sh", "--model", "codex", "topic",
                                          **{f"{role.upper()}_CLI": str(wrapper)})
                    self.assertEqual(result.returncode, 0 if forwarding else 5, result.stderr)
                    self.assertEqual(result.stdout, ANSWER if forwarding else "")
                    if not forwarding:
                        self.assertIn("wrote no final-answer file", result.stderr)
                        self.assertIn("wrappers forward all arguments", result.stderr)
                    self.assert_clean(result.stdout + result.stderr)
                    self.assertEqual(list(self.capture.iterdir()), [])

    def test_unrecognized_raw_log_value_warns_without_retaining(self):
        result = self.run_cli("lib/ask-critic.sh", "topic", DEBATE_RAW_LOG="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, ANSWER)
        self.assertIn("unrecognized DEBATE_RAW_LOG value", result.stderr)
        self.assertFalse(list(self.logs().glob("*.raw.log")))

    def test_native_missing_blank_and_nonzero_never_publish_console_or_final(self):
        cases = [("missing", "0", 5), ("blank", "0", 5),
                 ("answer", "9", 9), ("missing", "9", 9), ("directory", "0", 6)]
        for mode, rc, expected in cases:
            with self.subTest(mode=mode, rc=rc):
                result = self.run_cli("lib/ask-critic.sh", "topic", STUB_FINAL_MODE=mode, STUB_RC=rc)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assert_clean(result.stderr)
                self.assertEqual(list(self.capture.iterdir()), [])

    def test_raw_logs_are_opt_in_private_and_do_not_change_answers(self):
        for role, model in (("critic", "custom-final"), ("generator", "custom-stdout")):
            result = self.run_cli(f"lib/ask-{role}.sh", "--model", model, "topic", DEBATE_RAW_LOG="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, ANSWER)
            self.assert_clean(result.stderr)
        raw = list(self.logs().glob("*.raw.log"))
        self.assertEqual(len(raw), 2)
        for path in raw:
            self.assertIn("TOOL_OUTPUT_SENTINEL", path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        for path in self.logs().glob("*.log"):
            if not path.name.endswith(".raw.log"):
                self.assert_clean(path.read_text())

    def test_malformed_native_capture_fails_promptly_without_internal_errors(self):
        modes = ["directory", "fifo", "dangling"]
        if os.geteuid() != 0:  # Root can read mode-000 files, including in Docker.
            modes.append("unreadable")
        for mode in modes:
            for cli_rc, expected in (("0", 6), ("9", 9)):
                with self.subTest(mode=mode, rc=cli_rc):
                    result = self.run_cli("lib/ask-critic.sh", "topic", timeout=10,
                                          STUB_FINAL_MODE=mode, STUB_RC=cli_rc)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertNotIn("grep:", result.stderr)
                    self.assertNotIn("cat:", result.stderr)
                    self.assertNotIn(str(self.capture), result.stderr)
                    self.assertIn(f"rc={expected}", result.stderr)
                    self.assertEqual(list(self.capture.iterdir()), [])

    def test_failed_calls_retain_raw_diagnostics_only_with_opt_in(self):
        for model in ("custom-final", "custom-stdout"):
            for retain in ("0", "1"):
                with self.subTest(model=model, retain=retain):
                    before = set(self.logs().glob("*.raw.log"))
                    result = self.run_cli("lib/ask-critic.sh", "--model", model, "topic",
                                          STUB_RC="9", DEBATE_RAW_LOG=retain)
                    self.assertEqual(result.returncode, 9, result.stderr)
                    self.assert_clean(result.stdout + result.stderr)
                    added = set(self.logs().glob("*.raw.log")) - before
                    self.assertEqual(len(added), int(retain))
                    for path in added:
                        self.assertIn("TOOL_OUTPUT_SENTINEL", path.read_text())
                        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    for path in self.logs().glob("*.log"):
                        if not path.name.endswith(".raw.log"):
                            self.assert_clean(path.read_text())
                    self.assertEqual(list(self.capture.iterdir()), [])

    def test_stdout_adapter_stderr_cannot_satisfy_empty_answer(self):
        for answer, rc, expected in [(ANSWER, "0", 0), (" \n\t", "0", 5), ("", "9", 9)]:
            with self.subTest(answer=answer, rc=rc):
                result = self.run_cli("lib/ask-generator.sh", "--model", "custom-stdout", "topic",
                                      STUB_ANSWER=answer, STUB_RC=rc)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout, answer)
                self.assert_clean(result.stderr)

    def test_rotation_and_continue_receive_answers_not_console(self):
        result = self.run_cli("bin/debate.sh", "--rotate", "-n", "4", "topic", DEBATE_RAW_LOG="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        debate = (self.logs() / "latest-debate").resolve()
        result = self.run_cli("bin/debate.sh", "--continue-from", str(debate), "-n", "2", "topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean(result.stdout + result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 6)
        for call in calls:
            self.assert_clean(call[-1])
        self.assertIn(ANSWER.strip(), calls[-1][-1])
        for path in debate.glob("round-*.md"):
            self.assert_clean(path.read_text())
            self.assertIn(ANSWER, path.read_text())
        for role in ("gen", "crit"):
            self.assert_clean((debate / f"stream-{role}.log").read_text())

    def test_failed_native_round_has_no_completion_or_receipt(self):
        receipt = self.root / "receipt.json"
        result = self.run_cli("bin/debate.sh", "--until-converged", "-n", "4", "topic",
                              STUB_FINAL_MODE="missing", DEBATE_RECEIPT=str(receipt))
        self.assertEqual(result.returncode, 5, result.stderr)
        debate = (self.logs() / "latest-debate").resolve()
        rows = [json.loads(line) for line in (debate / "index.jsonl").read_text().splitlines()]
        self.assertEqual([(row["round"], row["rc"]) for row in rows if row["t"] == "end"], [(1, 0), (2, 5)])
        self.assertFalse((debate / ".round-2-crit.done").exists())
        self.assertFalse(receipt.exists())
        self.assert_clean((debate / "round-2-crit.md").read_text())

    def test_console_verdict_cannot_trigger_convergence(self):
        result = self.run_cli("bin/debate.sh", "--until-converged", "-n", "4", "topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 4)
        self.assertNotIn("Converged at round", result.stdout)

    def test_answer_text_that_resembles_cli_metadata_is_preserved(self):
        answer = ("exec\nhook: PreToolUse\nworkdir: example\nmodel: example\n"
                  "Reading additional input from stdin\nuser\ncodex\n"
                  "tokens used\n42\nrs\x1ebyte\nVerdict: RECONSIDER\n")
        result = self.run_cli("bin/debate.sh", "-n", "2", "topic", STUB_ANSWER=answer)
        self.assertEqual(result.returncode, 0, result.stderr)
        debate = (self.logs() / "latest-debate").resolve()
        for path in debate.glob("round-*.md"):
            self.assertEqual(path.read_text().split("\n", 1)[1], answer.replace("\x1e", ""))

    def test_debate_does_not_hand_its_stdin_to_a_role(self):
        # The wrappers take any non-terminal stdin as context. debate.sh's own
        # stdin, here a pipe that stays open, must reach no attempt.
        # Output goes to files: an unread pipe could fill and stall debate.sh,
        # which would look like the hang this test is about.
        err_path = self.root / "debate.err"
        with open(self.root / "debate.out", "w") as out, open(err_path, "w") as err, subprocess.Popen(
            ["/bin/bash", str(PLUGIN / "bin/debate.sh"), "-n", "2", "topic"], cwd=self.root,
            env=self.env, stdin=subprocess.PIPE, stdout=out, stderr=err,
            text=True, start_new_session=True,
        ) as proc:
            proc.stdin.write("INHERITED-STDIN-SENTINEL\n")
            proc.stdin.flush()
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                self.fail("debate.sh hung reading its inherited stdin")
            finally:
                proc.stdin.close()
        self.assertEqual(proc.returncode, 0, err_path.read_text())
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertNotIn("INHERITED-STDIN-SENTINEL", call)

    def test_capture_creation_failure_does_not_start_model(self):
        result = self.run_cli("lib/ask-critic.sh", "topic", TMPDIR=str(self.root / "absent"))
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertFalse(self.calls.exists())
        # mktemp names the internal capture template in its own diagnostic.
        self.assertNotIn("mkdtemp", result.stderr)
        self.assertNotIn("debate-answer.", result.stderr)

    def test_model_failure_status_survives_whatever_it_left_behind(self):
        # registry_run_answer reports a failed model and an answerless run with
        # the same 5, so an inspection delegated to it cannot tell them apart.
        # A model that exits 5 keeps its own status in every artifact state.
        modes = ["missing", "directory", "fifo", "dangling", "blank", "answer"]
        if os.geteuid() != 0:  # Root can read mode-000 files, including in Docker.
            modes.append("unreadable")
        for mode in modes:
            with self.subTest(mode=mode):
                result = self.run_cli("lib/ask-critic.sh", "topic", timeout=10,
                                      STUB_FINAL_MODE=mode, STUB_RC="5")
                self.assertEqual(result.returncode, 5, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(list(self.capture.iterdir()), [])

    def test_existing_raw_log_is_not_overwritten_or_reused(self):
        raw = self.root / "existing.raw.log"
        raw.write_text("previous invocation")
        result = subprocess.run(
            ["/bin/bash", "-c",
             ('. "$1/lib/registry.sh"; . "$1/lib/answer.sh"; '
              'debate_run_answer custom-final topic "$2"'), "_", str(PLUGIN), str(raw)],
            cwd=self.root, env=self.env, input="", capture_output=True, text=True,
            timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertEqual(raw.read_text(), "previous invocation")
        self.assertFalse(self.calls.exists())

    def test_publication_failure_preserves_model_failure(self):
        shims = self.root / "shims"
        shims.mkdir()
        tee = shims / "tee"
        # Drain the input so a downstream failure cannot manufacture a CLI SIGPIPE.
        tee.write_text("#!/bin/sh\n/bin/cat >/dev/null\nexit 42\n")
        tee.chmod(0o755)
        for model in ("custom-final", "custom-stdout"):
            for rc, expected in (("0", 6), ("9", 9)):
                with self.subTest(model=model, rc=rc):
                    result = self.run_cli(
                        "lib/ask-critic.sh", "--model", model, "topic", STUB_RC=rc,
                        PATH=f"{shims}{os.pathsep}{self.env['PATH']}",
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(list(self.capture.iterdir()), [])

    def start_held(self, role, model, *, driver=False):
        ready, release = self.root / "ready", self.root / "release"
        output = self.root / "output"
        if driver:
            command = ["/bin/bash", str(PLUGIN / "bin/debate.sh"), "--primary-gen", model, "-n", "1", "topic"]
        else:
            command = ["/bin/bash", str(PLUGIN / f"lib/ask-{role}.sh"), "--model", model, "topic"]
        with output.open("w") as stream:
            proc = subprocess.Popen(
                command,
                cwd=self.root, env=self.env | {"STUB_READY": str(ready), "STUB_RELEASE": str(release)},
                stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.DEVNULL, start_new_session=True,
            )
        def cleanup():
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=10)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline and proc.poll() is None:
            time.sleep(.02)
        self.assertTrue(ready.exists(), "model never reached readiness")
        return proc, output, release

    def test_native_answer_waits_for_successful_exit(self):
        proc, output, release = self.start_held("critic", "codex")
        self.assertEqual(output.read_text(), "")
        release.touch()
        self.assertEqual(proc.wait(timeout=10), 0)
        self.assertEqual(output.read_text(), ANSWER)
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_stdout_answer_still_streams(self):
        for retain in ("0", "1"):
            with self.subTest(raw_log=retain):
                self.env["DEBATE_RAW_LOG"] = retain
                for name in ("ready", "release"):
                    (self.root / name).unlink(missing_ok=True)
                proc, output, release = self.start_held("generator", "custom-stdout")
                deadline = time.monotonic() + 5
                while output.read_text() != ANSWER and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(output.read_text(), ANSWER)
                self.assertIsNone(proc.poll())
                release.touch()
                self.assertEqual(proc.wait(timeout=10), 0)

    def test_cancellation_removes_native_capture_without_publishing_it(self):
        proc, output, _ = self.start_held("critic", "codex")
        self.assertTrue(list(self.capture.iterdir()))
        os.killpg(proc.pid, signal.SIGTERM)
        self.assertNotEqual(proc.wait(timeout=10), 0)
        deadline = time.monotonic() + 5
        while list(self.capture.iterdir()) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(list(self.capture.iterdir()), [])
        self.assertEqual(output.read_text(), "")

    def test_driver_pid_cancellation_cleans_native_capture_and_records_failure(self):
        proc, output, _ = self.start_held("generator", "custom-final", driver=True)
        self.assertTrue(list(self.capture.iterdir()))
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=10), -signal.SIGTERM)
        deadline = time.monotonic() + 5
        while list(self.capture.iterdir()) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(list(self.capture.iterdir()), [])
        self.assertNotIn(ANSWER, output.read_text())
        debate = (self.logs() / "latest-debate").resolve()
        self.assertFalse((debate / ".round-1-gen.done").exists())
        self.assertFalse((debate / ".lock").is_symlink())
        rows = [json.loads(line) for line in (debate / "index.jsonl").read_text().splitlines()]
        self.assertEqual([(r["round"], r["rc"]) for r in rows if r["t"] == "end"], [(1, 143)])


if __name__ == "__main__":
    unittest.main()
