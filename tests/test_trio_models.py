"""Codex stage adapters and exact-version sibling lookup, without model calls."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TrioModelsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trio-models-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "models.json"
        self.env = dict(os.environ, PLUGIN_ROOT=str(ROOT / "ralph-trio"),
                        AGENT_TEAM_MODELS_CONFIG=str(self.config))

    def bash(self, command, **env):
        return subprocess.run(["bash", "-c", command], env={**self.env, **env},
                              text=True, capture_output=True, timeout=15)

    def test_host_defaults_and_binding_precedence(self):
        source = '. "$PLUGIN_ROOT/lib/model-stage.sh"; '
        result = self.bash(source + 'trio_resolve_model ralph-trio planner ""; trio_resolve_model ralph-trio coder ""',
                           RALPH_TRIO_PM_HOST="codex")
        self.assertEqual(result.stdout.splitlines(), ["codex-plan", "codex-write"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.config.write_text(json.dumps({"roles": {"ralph-trio.planner": "kimi-code"}}))
        result = self.bash(source + 'trio_resolve_model ralph-trio planner ""; trio_resolve_model ralph-trio planner agy',
                           RALPH_TRIO_PM_HOST="codex")
        self.assertEqual(result.stdout.splitlines(), ["kimi-code", "agy"])
        result = self.bash(source + 'trio_resolve_model spec-trio coder ""', SPEC_TRIO_PM_HOST="codex")
        self.assertEqual(result.stdout.strip(), "codex-write")

    def test_native_final_answer_is_separate_from_diagnostics(self):
        cli = self.root / "codex"
        cli.write_text('#!/bin/bash\nwhile [ "$#" -gt 0 ]; do\n'
                       '  if [ "$1" = --output-last-message ]; then final="$2"; shift 2; else shift; fi\n'
                       'done\nread -r prompt\necho transcript\necho diagnostic >&2\n'
                       'printf "answer: %s\\n" "$prompt" > "$final"\n')
        cli.chmod(0o755)
        answer = self.root / "final.md"
        answer.write_text("stale")
        result = self.bash('. "$PLUGIN_ROOT/lib/model-stage.sh"; trio_stage_model codex-plan "$ANSWER" <<< hello',
                           CODEX_CLI=str(cli), ANSWER=str(answer))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "answer: hello\n")
        self.assertIn("transcript", result.stderr)
        self.assertEqual(answer.read_text(), "answer: hello\n")

    def test_codex_dependency_uses_enabled_installed_cache_version(self):
        home = self.root / "codex-home"
        binary = home / "plugins/cache/pandas-studio/dev-trio/9.2/bin/ask-reviewer.sh"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        cli = self.root / "codex"
        cli.write_text('#!/bin/sh\ncat "$PLUGIN_LIST"\n')
        cli.chmod(0o755)
        listing = self.root / "plugins.json"
        listing.write_text(json.dumps({"installed": [{"pluginId": "dev-trio@pandas-studio",
                                                "installed": True, "enabled": True,
                                                "version": "9.2"}]}))
        result = self.bash('. "$PLUGIN_ROOT/lib/plugin-deps.sh"; '
                           'resolve_plugin_script DEV_TRIO_BIN dev-trio@pandas-studio ask-reviewer.sh; '
                           'printf "%s\\n" "$RESOLVED_SCRIPT"',
                           RALPH_TRIO_PM_HOST="codex", CODEX_HOME=str(home),
                           PLUGIN_LIST=str(listing), PATH=str(self.root) + os.pathsep + os.environ["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(binary.resolve()))

    def test_spec_driver_uses_codex_plan_and_write_models(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        for command in (["git", "init", "-q"],
                        ["git", "config", "user.email", "fixture@example.test"],
                        ["git", "config", "user.name", "Fixture"]):
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
        (workspace / "spec.md").write_text(
            "# Spec\n## §1 Goals\n- file\n## §2 Interfaces\n- file.txt\n"
            "## §3 Behavior\n### §3.1 write\n- write file.txt\n"
            "## §4 Constraints\n- none\n## §5 Test criteria\n"
            "### §5.1 exists\n- test -f file.txt\n## §6 Non-goals\n- none\n")
        (workspace / "BACKLOG.md").write_text("- [ ] (§3.1) write file.txt\n")
        subprocess.run(["git", "add", "spec.md", "BACKLOG.md"], cwd=workspace, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=workspace, check=True)
        cli = self.root / "codex-fixture"
        cli.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\nfrom pathlib import Path\n"
            "args=sys.argv[1:]\nprompt=sys.stdin.read()\n"
            "role='planner' if '# Role: Spec-driven Planner' in prompt else 'coder'\n"
            "with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([role,args])+'\\n')\n"
            "if role=='coder': Path('file.txt').write_text('implemented\\n')\n"
            "answer='<allowed-paths>file.txt</allowed-paths>\\n## Plan\\n- (§3.1) write file\\n' if role=='planner' else 'implemented file.txt\\n'\n"
            "Path(args[args.index('--output-last-message')+1]).write_text(answer)\n"
            "print('CLI transcript, not the final answer')\n")
        cli.chmod(0o755)
        calls = self.root / "calls.jsonl"
        result = subprocess.run(
            ["bash", str(ROOT / "spec-trio/bin/spec-trio.sh"), "--spec", "spec.md",
             "--backlog", "BACKLOG.md", "--max-iter", "1", "--test-cmd", "test -f file.txt",
             "--autoship", "--no-research"], cwd=workspace,
            env={**self.env, "SPEC_TRIO_PM_HOST": "codex", "CODEX_CLI": str(cli),
                 "SPEC_TRIO_WORKSPACE": str(self.root / "logs"), "CALLS": str(calls)},
            text=True, capture_output=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((workspace / "file.txt").read_text(), "implemented\n")
        self.assertIn("[x]", (workspace / "BACKLOG.md").read_text())
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual([entry[0] for entry in recorded], ["planner", "coder"])
        self.assertIn("read-only", recorded[0][1])
        self.assertIn("workspace-write", recorded[1][1])
        manifests = [json.loads(path.read_text()) for path in (self.root / "logs").rglob("*.manifest.json")]
        models = {role["model"] for manifest in manifests for role in manifest.get("roles", [])}
        self.assertTrue({"codex-plan", "codex-write"} <= models, models)

    def test_ralph_trio_uses_codex_plan_and_write_models(self):
        workspace = self.root / "ralph-workspace"
        workspace.mkdir()
        for command in (["git", "init", "-q"],
                        ["git", "config", "user.email", "fixture@example.test"],
                        ["git", "config", "user.name", "Fixture"]):
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
        (workspace / "BACKLOG.md").write_text("- [ ] create file.txt\n")
        subprocess.run(["git", "add", "BACKLOG.md"], cwd=workspace, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=workspace, check=True)
        cli = self.root / "ralph-codex-fixture"
        cli.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\nfrom pathlib import Path\n"
            "args=sys.argv[1:]\nprompt=sys.stdin.read()\n"
            "role='planner' if '# Role: Ralph Planner' in prompt else 'coder'\n"
            "with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([role,args])+'\\n')\n"
            "if role=='coder': Path('file.txt').write_text('implemented\\n')\n"
            "answer='## Plan\\n- create file.txt\\n' if role=='planner' else 'implemented file.txt\\n'\n"
            "Path(args[args.index('--output-last-message')+1]).write_text(answer)\n"
            "print('CLI transcript, not the final answer')\n")
        cli.chmod(0o755)
        calls = self.root / "ralph-calls.jsonl"
        result = subprocess.run(
            ["bash", str(ROOT / "ralph-trio/bin/ralph-trio.sh"), "--backlog", "BACKLOG.md",
             "--max-iter", "1", "--autoship", "--no-research"], cwd=workspace,
            env={**self.env, "RALPH_TRIO_PM_HOST": "codex", "CODEX_CLI": str(cli),
                 "RALPH_TRIO_WORKSPACE": str(self.root / "ralph-logs"), "CALLS": str(calls)},
            text=True, capture_output=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((workspace / "file.txt").read_text(), "implemented\n")
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual([entry[0] for entry in recorded], ["planner", "coder"])
        self.assertIn("read-only", recorded[0][1])
        self.assertIn("workspace-write", recorded[1][1])
        manifests = [json.loads(path.read_text()) for path in (self.root / "ralph-logs").rglob("*.manifest.json")]
        models = {role["model"] for manifest in manifests for role in manifest.get("roles", [])}
        self.assertTrue({"codex-plan", "codex-write"} <= models, models)

    def test_ralph_solo_uses_codex_write_model(self):
        workspace = self.root / "solo-workspace"
        workspace.mkdir()
        (workspace / "PROMPT.md").write_text("Create file.txt and mark completion in fix_plan.md.\n")
        cli = self.root / "solo-codex-fixture"
        cli.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\nfrom pathlib import Path\n"
            "prompt=sys.stdin.read()\n"
            "Path(os.environ['CALLS']).write_text(json.dumps([sys.argv[1:],prompt]))\n"
            "Path('file.txt').write_text('implemented\\n')\n"
            "Path('fix_plan.md').write_text('<promise>COMPLETE</promise>\\n')\n"
            "print('completed')\n")
        cli.chmod(0o755)
        calls = self.root / "solo-call.json"
        result = subprocess.run(
            ["bash", str(ROOT / "ralph-trio/bin/ralph-solo.sh"), "--max-iter", "1"],
            cwd=workspace,
            env={**self.env, "RALPH_TRIO_PM_HOST": "codex", "CODEX_CLI": str(cli),
                 "RALPH_TRIO_WORKSPACE": str(self.root / "solo-logs"), "CALLS": str(calls)},
            text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((workspace / "file.txt").read_text(), "implemented\n")
        args, prompt = json.loads(calls.read_text())
        self.assertIn("workspace-write", args)
        self.assertIn("Create file.txt", prompt)
        manifests = [json.loads(path.read_text()) for path in (self.root / "solo-logs").rglob("*.manifest.json")]
        self.assertIn("codex-write", {role["model"] for manifest in manifests for role in manifest.get("roles", [])})

    def test_codex_pm_installers_keep_other_workspace_instructions(self):
        workspace = self.root / "policy-workspace"
        workspace.mkdir()
        policy = workspace / "AGENTS.md"
        policy.write_text("# Project rules\n\nKeep this text.\n")
        for plugin in ("ralph-trio", "spec-trio"):
            command = [sys.executable, str(ROOT / plugin / "bin/install-pm.py"), "--host", "codex"]
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
            before = policy.read_bytes()
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
            self.assertEqual(policy.read_bytes(), before)
            self.assertEqual(policy.read_text().count(f"<!-- BEGIN {plugin} PM policy -->"), 1)
        self.assertTrue(policy.read_text().startswith("# Project rules\n\nKeep this text.\n"))


if __name__ == "__main__":
    unittest.main()
