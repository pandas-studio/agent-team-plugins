"""An unreadable workspace_args or final_args is an error, not "the model has none" (#296).

`registry_has_workspace` and `registry_has_final` return 0, 1, or 3 when the
template cannot be read. Every caller tests them with `if`, where 1 and 3 look
alike, so each one tells them apart in its else branch. Each test here fails the
predicate's own jq read for one field, at the call that site makes, and checks
that the site does not take the "no template" branch.
"""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

import test_debate_conductor_hosts as debate_hosts
import test_dev_trio_hosts as dev_hosts

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_COPIES = ("dev-trio", "debate-conductor", "ralph-trio", "spec-trio")
CLI_COPIES = ("dev-trio", "debate-conductor")
SHELLS = tuple(dict.fromkeys(s for s in ("/bin/bash", shutil.which("bash")) if s and os.path.exists(s)))
QUERY = "((.[$f] // []) | length) > 0"
REAL_JQ = shutil.which("jq")
INJECTED = "jq: error: injected\n"


def write_jq_shim(bin_dir, counter, field, n=1, mode="empty", noisy=False, after=None):
    """Fail the n-th predicate read of `field`. With `after`, a read is failed
    (and counted) only once that file holds a line naming "exec": the decision is
    taken when jq runs, so a hit proves the read came after the model started."""
    counter.write_text("0")
    real, c = shlex.quote(REAL_JQ), shlex.quote(str(counter))
    fail = {"empty": "exit 1", "output": f'{real} "$@"; exit 1'}[mode]
    if noisy:
        fail = f"printf %s {shlex.quote(INJECTED)} >&2; " + fail
    gate = f'[ -n "$q" ] && [ -n "$f" ]'
    if after is not None:
        gate += f' && grep -q \'"exec"\' {shlex.quote(str(after))} 2>/dev/null'
    shim = bin_dir / "jq"
    shim.write_text(
        "#!/bin/sh\n"
        "q=; f=\n"
        f'for a in "$@"; do [ "$a" = {shlex.quote(QUERY)} ] && q=1; [ "$a" = {shlex.quote(field)} ] && f=1; done\n'
        f"if {gate}; then\n"
        f"  k=$(($(cat {c}) + 1)); echo \"$k\" > {c}\n"
        f'  if [ "$k" = {int(n)} ]; then {fail}; fi\n'
        "fi\n"
        f'exec {real} "$@"\n')
    shim.chmod(0o755)


class LibraryFixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="registry-template-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.counter = self.root / "jq-count"
        self.marker = self.root / "started"
        self.config = self.root / "models.json"
        # A stub CLI that leaves a marker on entry, prints a fixed answer, and
        # writes `final-bytes` to the path after --output-last-message.
        self.stub = self.bin / "stub-cli"
        self.stub.write_text(
            "#!/bin/sh\n"
            f": > {shlex.quote(str(self.marker))}\n"
            'while [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = --output-last-message ]; then printf final-bytes > "$2"; fi\n'
            "  shift\n"
            "done\n"
            "cat >/dev/null\n"
            "echo streamed-answer\n")
        self.stub.chmod(0o755)
        self.env = {
            "HOME": str(self.root), "PATH": f"{self.bin}:{os.environ['PATH']}",
            "AGENT_TEAM_MODELS_CONFIG": str(self.config), "LC_ALL": "C",
            "CODEX_CLI": str(self.stub), "AGY_CLI": str(self.stub),
        }

    def inject(self, field, **kw):
        write_jq_shim(self.bin, self.counter, field, **kw)

    def hits(self):
        return int(self.counter.read_text())

    def run_bash(self, shell, script, **env):
        return subprocess.run([shell, "-c", script], env={**self.env, **env}, stdin=subprocess.DEVNULL,
                              text=True, capture_output=True, timeout=30)

    def lib(self, shell, plugin, call, extra=(), **env):
        libs = [ROOT / plugin / "lib" / "registry.sh", *(ROOT / plugin / "lib" / e for e in extra)]
        src = "".join(f". {shlex.quote(str(p))} || exit 99; " for p in libs)
        return self.run_bash(shell, src + call, **env)


class PredicateTests(LibraryFixture):
    def test_unreadable_template_is_rc_3_with_one_diagnostic(self):
        cases = (("registry_has_final", "codex", "final_args"),
                 ("registry_has_workspace", "agy", "workspace_args"))
        for fn, model, field in cases:
            for mode in ("empty", "output"):
                for noisy in (False, True):
                    for shell in SHELLS:
                        for plugin in REGISTRY_COPIES:
                            with self.subTest(fn=fn, mode=mode, noisy=noisy, shell=shell, plugin=plugin):
                                self.inject(field, mode=mode, noisy=noisy)
                                r = self.lib(shell, plugin, f'{fn} {model}; echo "rc=$?"')
                                self.assertEqual(self.hits(), 1)
                                self.assertEqual(r.stdout, "rc=3\n")
                                self.assertEqual(r.stderr, f"registry: cannot read the {field} of model '{model}'\n")

    def test_readable_templates_keep_rc_0_and_1(self):
        self.inject("no-such-field")
        for shell in SHELLS:
            for plugin in REGISTRY_COPIES:
                with self.subTest(shell=shell, plugin=plugin):
                    r = self.lib(shell, plugin, 'for c in "registry_has_final codex" "registry_has_final agy" '
                                 '"registry_has_workspace agy" "registry_has_workspace codex" '
                                 '"registry_has_final no-such-model"; do $c; printf "%s " "$?"; done')
                    self.assertEqual((r.stdout, r.stderr), ("0 1 0 1 1 ", ""))


class RegistryRunTests(LibraryFixture):
    def test_registry_run_starts_nothing(self):
        for shell in SHELLS:
            for plugin in REGISTRY_COPIES:
                with self.subTest(shell=shell, plugin=plugin):
                    self.marker.unlink(missing_ok=True)
                    self.inject("final_args")
                    r = self.lib(shell, plugin, f'registry_run codex P {shlex.quote(str(self.root / "final"))}; echo "rc=$?"')
                    self.assertEqual(self.hits(), 1)
                    self.assertEqual(r.stdout, "rc=3\n")
                    self.assertFalse(self.marker.exists(), "the CLI was started")

    def test_registry_run_answer_keeps_a_native_answer_it_cannot_classify(self):
        # 1st read: registry_run picks final_args, the CLI writes final-bytes.
        # 2nd read: after the CLI exited 0, the answer's location is unreadable.
        for shell in SHELLS:
            for plugin in REGISTRY_COPIES:
                with self.subTest(shell=shell, plugin=plugin):
                    answer = self.root / "answer"
                    answer.unlink(missing_ok=True)
                    self.inject("final_args", n=2)
                    r = self.lib(shell, plugin, f'registry_run_answer codex P {shlex.quote(str(answer))}; echo "rc=$?"')
                    self.assertEqual(self.hits(), 2)
                    self.assertEqual(r.stdout.splitlines()[-1], "rc=6")
                    self.assertEqual(answer.read_text(), "final-bytes")
                    self.assertIn("registry_run_answer: cannot tell where model 'codex' left its answer\n", r.stderr)


class StageTests(LibraryFixture):
    def test_trio_stage_starts_nothing(self):
        for shell in SHELLS:
            for plugin in ("ralph-trio", "spec-trio"):
                with self.subTest(shell=shell, plugin=plugin):
                    self.marker.unlink(missing_ok=True)
                    self.inject("final_args")
                    r = self.lib(shell, plugin, f'echo P | trio_stage_model codex {shlex.quote(str(self.root / "final"))}; echo "rc=$?"',
                                 extra=("model-stage.sh",), PLUGIN_ROOT=str(ROOT / plugin))
                    self.assertEqual(self.hits(), 1)
                    self.assertEqual(r.stdout, "rc=3\n")
                    self.assertFalse(self.marker.exists(), "the CLI was started")
                    self.assertEqual(r.stderr, "registry: cannot read the final_args of model 'codex'\n")

    def test_debate_answer_starts_nothing(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.marker.unlink(missing_ok=True)
                raw = self.root / "raw.log"
                raw.unlink(missing_ok=True)
                self.inject("final_args")
                r = self.lib(shell, "debate-conductor", f'debate_run_answer codex P {shlex.quote(str(raw))}; echo "rc=$?"',
                             extra=("answer.sh",))
                self.assertEqual(self.hits(), 1)
                self.assertEqual(r.stdout, "rc=3\n")
                self.assertFalse(self.marker.exists(), "the CLI was started")
                self.assertIn("registry: cannot read the final_args of model 'codex'", raw.read_text())
                self.assertIn("debate-answer: model 'codex' failed (rc=3;", r.stderr)


class ModelsListTests(LibraryFixture):
    def test_list_marks_an_unknown_capture_mode(self):
        for noisy in (False, True):
            for shell in SHELLS:
                for plugin in CLI_COPIES:
                    with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                        self.inject("final_args", noisy=noisy)
                        script = ROOT / plugin / "bin" / "agent-team-models.sh"
                        r = self.run_bash(shell, f"exec {shlex.quote(shell)} {shlex.quote(str(script))} list")
                        # One read per model; only the first fails.
                        self.assertGreaterEqual(self.hits(), 1)
                        self.assertEqual(r.returncode, 0, r.stderr)
                        rows = [l.split() for l in r.stdout.split("Models:\n", 1)[1].split("\n\n", 1)[0].splitlines()]
                        marked = [row for row in rows if row[-1] == "(final-capture=?)"]
                        self.assertEqual(len(marked), 1, r.stdout)
                        self.assertEqual(r.stderr, f"registry: cannot read the final_args of model '{marked[0][0]}'\n")


class ReviewerWrapperTests(unittest.TestCase):
    setUp = dev_hosts.HostTests.setUp
    run_cli = dev_hosts.HostTests.run_cli
    recorded = dev_hosts.HostTests.recorded

    def shim(self, field, **kw):
        self.bin = self.root / "jq shim"
        self.bin.mkdir(exist_ok=True)
        self.counter = self.root / "jq-count"
        write_jq_shim(self.bin, self.counter, field, **kw)
        self.env["PATH"] = f"{self.bin}:{self.env['PATH']}"

    def hits(self):
        return int(self.counter.read_text())

    def logdir(self):
        return self.workspace / ".dev-trio/log/host-test"

    def test_unreadable_workspace_template_is_a_setup_error(self):
        for wrapper, env_key in (("ask-reviewer.sh", "DEV_TRIO_REVIEWER_MODEL"),
                                 ("ask-researcher.sh", "DEV_TRIO_RESEARCHER_MODEL")):
            with self.subTest(wrapper=wrapper):
                self.calls.unlink(missing_ok=True)
                self.shim("workspace_args", noisy=True)
                r = self.run_cli(wrapper, "q", **{env_key: "agy"})
                self.assertEqual(self.hits(), 1)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(self.recorded(), [])
                self.assertEqual(r.stderr.count("registry: cannot read the workspace_args of model 'agy'\n"), 1)
                self.assertNotIn(INJECTED, r.stderr)

    def test_unreadable_capture_mode_after_the_run_synthesizes_no_review(self):
        # codex has final_args. The stub writes no final and prints a review that
        # parses; the transcript fallback is what would turn it into $FINAL.
        self.shim("final_args", n=1, after=self.calls)
        r = self.run_cli("ask-reviewer.sh", "--summary", "q", STUB_NO_FINAL="1")
        self.assertEqual(self.hits(), 1)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("[ask-reviewer] the capture mode of codex could not be read; no review was synthesized\n", r.stderr)
        summary = json.loads(r.stdout)
        self.assertEqual(summary["result"]["status"], "parse-failed")
        self.assertEqual(summary["result"]["invocation_rc"], 0)
        self.assertFalse(Path(summary["paths"]["final"]).exists())

    def test_fallback_control_cases(self):
        # The same stub output does become a review when the fallback runs: a
        # model without final_args (the branch an unreadable read used to take).
        plain = json.dumps({"models": {"plain": {"command": str(self.stub), "prompt_via": "stdin",
                                                 "args": ["exec", "-"]}}, "roles": {}})
        self.config.write_text(plain)
        r = self.run_cli("ask-reviewer.sh", "--summary", "--model", "plain", "q", STUB_NO_FINAL="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["result"]["status"], "ok")
        # A native final the CLI did write still parses when the read fails.
        self.config.write_text('{"models":{},"roles":{}}')
        for p in self.logdir().iterdir():
            if p.is_file() or p.is_symlink():
                p.unlink()
        self.shim("final_args", n=1, after=self.calls)
        r = self.run_cli("ask-reviewer.sh", "--summary", "q")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["result"]["status"], "ok")

    def test_run_metadata_records_an_unknown_final_source(self):
        # The first final_args read is run_begin_metadata's.
        self.shim("final_args", n=1)
        self.run_cli("ask-reviewer.sh", "q")
        self.assertGreaterEqual(self.hits(), 1)
        run = json.loads(next(self.logdir().glob("reviewer-*.run.json")).read_text())
        self.assertEqual(run["final_source"], "none")


class DebateWrapperTests(unittest.TestCase):
    setUp = debate_hosts.DebateHostTests.setUp
    run_cli = debate_hosts.DebateHostTests.run_cli
    recorded = debate_hosts.DebateHostTests.recorded

    def test_unreadable_workspace_template_is_a_setup_error(self):
        bin_dir = self.root / "jq shim"
        bin_dir.mkdir()
        counter = self.root / "jq-count"
        self.env["PATH"] = f"{bin_dir}:{self.env['PATH']}"
        for wrapper in ("ask-generator.sh", "ask-critic.sh"):
            with self.subTest(wrapper=wrapper):
                self.calls.unlink(missing_ok=True)
                write_jq_shim(bin_dir, counter, "workspace_args", noisy=True)
                r = self.run_cli(wrapper, "fixture", DEBATE_GENERATOR_MODEL="agy", DEBATE_CRITIC_MODEL="agy")
                self.assertEqual(int(counter.read_text()), 1)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(self.recorded(), [])
                self.assertEqual(r.stderr.count("registry: cannot read the workspace_args of model 'agy'\n"), 1)
                self.assertNotIn(INJECTED, r.stderr)


if __name__ == "__main__":
    unittest.main()
