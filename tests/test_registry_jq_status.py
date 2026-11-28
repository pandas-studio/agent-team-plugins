"""A failing jq in the model registry and the models CLI is an error, not a value (#294).

Each test fails one jq call, chosen by its exact query and its position among the
calls carrying that query, and checks that the caller reports the failure instead
of reading the empty or partial output as an answer. The shim's counter shows the
target call was reached. Two failure modes: "empty" exits 1 with no output, and
"output" prints the real result and then exits 1. Each site is tested in the mode
that changes its behaviour; where the old code already failed closed, the exact
diagnostic is what is asserted.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from jq_shim import SHELLS, write_jq_shim

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_COPIES = ("dev-trio", "debate-conductor", "ralph-trio", "spec-trio")
CLI_COPIES = ("dev-trio", "debate-conductor")


class JqFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="registry-jq-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.config = self.root / "models.json"
        self.counter = self.root / "jq-count"
        self.real_jq = shutil.which("jq")
        self.assertIsNotNone(self.real_jq)
        self.env = {
            "HOME": str(self.root),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "AGENT_TEAM_MODELS_CONFIG": str(self.config),
            "LC_ALL": "C",
        }

    def fail_jq(self, query, n=1, mode="empty", stderr=False):
        """Fail the n-th jq call whose arguments include `query` exactly."""
        write_jq_shim(self.bin, self.counter, self.real_jq, query, n, mode, stderr)

    def hits(self):
        return int(self.counter.read_text())

    def run_bash(self, shell, script, *args, **env):
        return subprocess.run([shell, "-c", script, "bash", *args], env={**self.env, **env},
                              stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=30)

    def registry(self, shell, plugin, call, **env):
        lib = ROOT / plugin / "lib" / "registry.sh"
        return self.run_bash(shell, f'. {shlex.quote(str(lib))} || exit 99; {call}', **env)

    def cli(self, shell, plugin, *args, **env):
        script = ROOT / plugin / "bin" / "agent-team-models.sh"
        return self.run_bash(shell, f'exec {shlex.quote(shell)} {shlex.quote(str(script))} "$@"', *args, **env)

    @staticmethod
    def copies(plugins):
        return [(shell, plugin) for shell in SHELLS for plugin in plugins]

    def noisy_copies(self, plugins):
        """Each copy twice: a silent failing jq, and one that writes its own error.
        The registry's diagnostic must be the only line either way."""
        return [(shell, plugin, noisy) for noisy in (False, True) for shell, plugin in self.copies(plugins)]


class RegistryLookupTests(JqFixture):
    def test_config_role_binding_lookup(self):
        for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.config.write_text(json.dumps({"roles": {"debate-conductor.generator": "codex"}}))
                self.fail_jq('.roles[$k] // ""', stderr=noisy)
                r = self.registry(shell, plugin, 'registry_resolve_role debate-conductor generator ""')
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual((r.returncode, r.stdout), (3, ""))
                self.assertEqual(r.stderr, "registry: cannot read the role binding for "
                                           "'debate-conductor.generator' from the config\n")

    def test_builtin_role_binding_lookup(self):
        for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.fail_jq('.[$k] // ""', stderr=noisy)
                r = self.registry(shell, plugin, 'registry_resolve_role debate-conductor generator ""')
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual((r.returncode, r.stdout), (3, ""))
                self.assertEqual(r.stderr, "registry: cannot read the built-in role binding for "
                                           "'debate-conductor.generator'\n")

    def test_env_command_lookup(self):
        for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.fail_jq('.env_command // ""', stderr=noisy)
                r = self.registry(shell, plugin, "registry_resolve_command codex", CODEX_CLI="/opt/my-codex")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual((r.returncode, r.stdout), (3, ""))
                self.assertEqual(r.stderr, "registry: cannot read the env_command of model 'codex'\n")

    def test_command_lookup(self):
        for mode in ("empty", "output"):
            for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
                with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                    with self.subTest(mode=mode):
                        self.fail_jq('.command // ""', mode=mode, stderr=noisy)
                        r = self.registry(shell, plugin, "registry_resolve_command codex")
                        self.assertGreaterEqual(self.hits(), 1)
                        self.assertEqual((r.returncode, r.stdout), (3, ""))
                        self.assertEqual(r.stderr, "registry: cannot read the command of model 'codex'\n")

    def test_prompt_via_lookup(self):
        for mode in ("empty", "output"):
            for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
                with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                    with self.subTest(mode=mode):
                        self.fail_jq('.prompt_via // "argv"', mode=mode, stderr=noisy)
                        r = self.registry(shell, plugin, "registry_prompt_via codex")
                        self.assertGreaterEqual(self.hits(), 1)
                        self.assertEqual((r.returncode, r.stdout), (3, ""))
                        self.assertEqual(r.stderr, "registry: cannot read prompt_via of model 'codex'\n")

    def test_definition_problem_reason(self):
        # An argv model whose args template has no {prompt}: the rule refuses it.
        for mode in ("empty", "output"):
            for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
                with self.subTest(shell=shell, plugin=plugin, noisy=noisy, mode=mode):
                    self.fail_jq(".reason", mode=mode, stderr=noisy)
                    r = self.registry(shell, plugin, """registry_check_def x '{"command":"x","args":[]}'""")
                    self.assertGreaterEqual(self.hits(), 1)
                    self.assertEqual((r.returncode, r.stdout), (3, ""))
                    self.assertEqual(r.stderr, "registry: model 'x' breaks the definition rule "
                                               "(its reason could not be read)\n")

    def test_builtin_predicate(self):
        for shell, plugin, noisy in self.noisy_copies(REGISTRY_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.fail_jq("has($id)", stderr=noisy)
                r = self.registry(shell, plugin, "registry_model_is_builtin codex")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual((r.returncode, r.stdout), (3, ""))
                self.assertEqual(r.stderr, "registry: cannot check whether model 'codex' is built-in\n")


class ModelsCliTests(JqFixture):
    # A refused write must leave an existing config exactly as it was.
    EXISTING = '{"version":1,"models":{},"roles":{"dev-trio.reviewer":"codex"}}\n'

    def test_add_refuses_when_the_builtin_check_fails(self):
        for shell, plugin, noisy in self.noisy_copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.config.write_text(self.EXISTING)
                self.fail_jq("has($id)", stderr=noisy)
                r = self.cli(shell, plugin, "add", "codex", "--command", "evil", "--arg", "{prompt}")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stderr, "registry: cannot check whether model 'codex' is built-in\n")
                self.assertEqual(self.config.read_text(), self.EXISTING)

    def test_preset_add_refuses_when_its_ids_cannot_be_read(self):
        for shell, plugin, noisy in self.noisy_copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.config.write_text(self.EXISTING)
                self.fail_jq("keys[]", stderr=noisy)
                r = self.cli(shell, plugin, "preset", "add", "kimi-code")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stderr, "agent-team-models: cannot read the models of preset 'kimi-code'\n")
                self.assertEqual(self.config.read_text(), self.EXISTING)

    def test_preset_add_refuses_when_a_definition_cannot_be_read(self):
        for shell, plugin, noisy in self.noisy_copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.config.write_text('{"version":1,"models":{},"roles":{}}\n')
                before = self.config.read_bytes()
                self.fail_jq(".[$id]", mode="output", stderr=noisy)
                r = self.cli(shell, plugin, "preset", "add", "kimi-code")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stderr, "agent-team-models: cannot read model 'kimi-code' "
                                           "of preset 'kimi-code'\n")
                self.assertEqual(self.config.read_bytes(), before)

    def model_row(self, out, model):
        rows = [l for l in out.splitlines() if l.split()[:1] == [model]]
        self.assertEqual(len(rows), 1, out)
        return rows[0].split()

    def role_row(self, out, key):
        rows = [l for l in out.splitlines() if l.split()[:1] == [key]]
        self.assertEqual(len(rows), 1, out)
        return rows[0].split()

    def test_list_marks_an_unknown_origin(self):
        for shell, plugin, noisy in self.noisy_copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.fail_jq("has($id)", stderr=noisy)
                r = self.cli(shell, plugin, "list")
                self.assertGreaterEqual(self.hits(), 1)
                self.assertEqual(r.returncode, 0, r.stderr)
                first = r.stdout.split("Models:\n", 1)[1].splitlines()[0].split()[0]
                self.assertEqual(self.model_row(r.stdout, first)[1], "[?]")
                self.assertEqual(r.stderr, f"registry: cannot check whether model '{first}' is built-in\n")

    def test_list_marks_an_unknown_role_source(self):
        # list resolves each role, then labels its source; both read `.roles[$k] // ""`.
        # The 2nd call is the first role's label.
        for shell, plugin, noisy in self.noisy_copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin, noisy=noisy):
                self.config.write_text(json.dumps({"roles": {"dev-trio.researcher": "codex"}}))
                self.fail_jq('.roles[$k] // ""', n=2, stderr=noisy)
                r = self.cli(shell, plugin, "list")
                self.assertGreaterEqual(self.hits(), 2)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.role_row(r.stdout, "dev-trio.researcher"),
                                 ["dev-trio.researcher", "->", "codex", "(?)"])


class EnvCommandShadowTests(JqFixture):
    def test_list_reads_a_model_env_command_named_like_a_list_variable(self):
        # registry_resolve_command reads env_command by name; a local of the
        # caller with that name would shadow the user's export. No jq failure here.
        for shell, plugin in self.copies(CLI_COPIES):
            with self.subTest(shell=shell, plugin=plugin):
                self.config.write_text(json.dumps({"models": {"mine": {
                    "command": "mine", "env_command": "rc", "args": ["{prompt}"]}}}))
                r = self.cli(shell, plugin, "list", rc="/opt/my-model")
                self.assertEqual(r.returncode, 0, r.stderr)
                rows = [l.split() for l in r.stdout.splitlines() if l.split()[:1] == ["mine"]]
                self.assertEqual(rows, [["mine", "[user]", "binary=/opt/my-model"]])


class ReceiptReaderTests(JqFixture):
    def test_last_round_read_failure_rejects_the_receipt(self):
        lib = ROOT / "debate-conductor" / "lib" / "debate-result.sh"
        debate = self.root / "debate"
        debate.mkdir()
        (debate / "round-2-crit.md").write_text("Verdict: STRENGTHEN\n")
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"schema_version": 1, "debate_dir": str(debate.resolve()),
                                       "last_round": 2, "critic_round": 2,
                                       "critic_file": "round-2-crit.md"}))
        for shell in SHELLS:
            for noisy in (False, True):
                with self.subTest(shell=shell, stderr=noisy):
                    self.fail_jq(".last_round", mode="output", stderr=noisy)
                    r = self.run_bash(shell, f'. {shlex.quote(str(lib))} || exit 99; '
                                             'debate_receipt_read "$1"', str(receipt))
                    self.assertGreaterEqual(self.hits(), 1)
                    self.assertEqual((r.returncode, r.stdout, r.stderr), (1, "", ""))


if __name__ == "__main__":
    unittest.main()
