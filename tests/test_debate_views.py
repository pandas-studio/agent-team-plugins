"""Issue #205: view identity, dispatch receipts and optional GUI boundaries.

Fake tests never start a provider or terminal. Real tmux tests use a dedicated
TMUX_TMPDIR and a shim forcing /dev/null config, including inside viewer panes.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "debate-conductor"
REAL_TMUX = shutil.which("tmux")


class ViewFixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="debate view ' ")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.plugin = self.root / "installed plugin"
        shutil.copytree(PLUGIN, self.plugin)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.state = self.root / "fake.json"
        self.state.write_text(json.dumps(dict(current="%0", next=1, calls=[], windows={
            "@0": dict(options={}, panes=["%0"])})))
        fake = ROOT / "tests/fake_tmux.py"
        self.tool("tmux", f"exec {shlex.quote(sys.executable)} {shlex.quote(str(fake))} \"$@\"\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("AGENT_TEAM", "DEBATE_", "TMUX", "SSH_", "CLAUDE_", "CODEX_", "AGY_"))}
        self.env.update(PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        TMPDIR=str(self.root), TMUX_TMPDIR=str(self.root),
                        TMUX="", TMUX_PANE="", FAKE_TMUX_STATE=str(self.state))

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def cli(self, script, *args, **env):
        return subprocess.run([str(self.plugin / "bin" / script), *args],
                              cwd=self.workspace, env=self.env | env, input="",
                              text=True, capture_output=True, timeout=25)

    def prepare(self, *args, **env):
        result = self.cli("team-3pane.sh", *args or ("--view=none",), **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def read_state(self):
        return json.loads(self.state.read_text())


class ViewPreparationTests(ViewFixture):
    def test_manual_context_and_posix_quoting(self):
        ctx = self.prepare(DEBATE_LOG_DIR="logs ' ; $(no-command)", AGENT_TEAM="custom")
        self.assertEqual(ctx["status"], "manual")
        self.assertEqual(ctx["team"], "custom")
        self.assertTrue(ctx["log_base"].startswith(str(self.workspace)))
        self.assertEqual(shlex.split(ctx["tail_commands"][0])[-1], ctx["log_dir"] + "/latest-debate/stream-gen.log")
        self.assertEqual(Path(ctx["context_file"]).stat().st_mode & 0o777, 0o600)
        self.assertFalse(Path(ctx["receipt"]).exists())
        self.assertTrue(all(command in ctx["user_message"] for command in ctx["tail_commands"]))

    def test_strict_detached_create_reuse_and_context_separation(self):
        first = self.prepare("--view=tmux")
        second = self.prepare("--view=tmux")
        self.assertEqual(first["session"], second["session"])
        self.assertNotEqual(first["context_file"], second["context_file"])
        states = self.read_state()
        self.assertEqual(sum(c[0] == "split-window" for c in states["calls"]), 1)
        third = self.prepare("--view=tmux", AGENT_TEAM="other.team")
        self.assertNotEqual(first["session"], third["session"])
        self.assertNotIn(".", third["session"])
        self.assertEqual(shlex.split(first["attach_command"])[-1], "=" + first["session"])

    def test_owned_dead_viewer_is_respawned_without_splitting(self):
        first = self.prepare("--view=tmux")
        state = self.read_state()
        win = next(v for v in state["windows"].values() if v.get("session") == first["session"])
        record = json.loads(win["options"]["@debate-view"])
        state["dead"] = {record["gen"]: 1}
        self.state.write_text(json.dumps(state))
        second = self.prepare("--view=tmux")
        state = self.read_state()
        self.assertEqual(second["session"], first["session"])
        self.assertEqual(sum(c[0] == "split-window" for c in state["calls"]), 1)
        self.assertEqual(sum(c[0] == "respawn-pane" for c in state["calls"]), 3)

    def test_foreign_collision_is_not_modified(self):
        ctx = self.prepare("--view=tmux")
        state = self.read_state()
        win = next(v for v in state["windows"].values() if v.get("session") == ctx["session"])
        win["options"]["@debate-view-owner"] = "someone-else"
        before = list(win["panes"])
        self.state.write_text(json.dumps(state))
        result = self.cli("team-3pane.sh", "--view=tmux")
        self.assertEqual(result.returncode, 2)
        self.assertIn("foreign", result.stderr)
        win = next(v for v in self.read_state()["windows"].values() if v.get("session") == ctx["session"])
        self.assertEqual(win["panes"], before)

    def test_untagged_here_freezes_session_team(self):
        # The fake session_name format is implemented with its real session below.
        state = self.read_state()
        state["windows"]["@0"].update(session="work", sid="$0")
        self.state.write_text(json.dumps(state))
        ctx = self.prepare("--view=auto", TMUX=str(self.root / "socket") + ",1,0", TMUX_PANE="%0")
        self.assertEqual(ctx["status"], "present")
        self.assertEqual(ctx["team"], "work")
        self.assertEqual(self.read_state()["windows"]["@0"]["panes"], ["%0", "%1", "%2"])

    def test_hand_split_window_is_preserved_with_separate_view(self):
        state = self.read_state()
        state["windows"]["@0"]["panes"].append("%9")
        state["next"] = 10
        self.state.write_text(json.dumps(state))
        ctx = self.prepare("--view=auto", TMUX=str(self.root / "socket") + ",1,0", TMUX_PANE="%0", AGENT_TEAM="same")
        self.assertEqual(ctx["status"], "ready-detached")
        self.assertEqual(self.read_state()["windows"]["@0"]["panes"], ["%0", "%9"])

    def test_legacy_three_panes_are_not_claimed_as_verified(self):
        state = self.read_state()
        state["windows"]["@0"] = dict(panes=["%0", "%1", "%2"], options={
            "@team-name": "legacy", "@team-layout": "debate-3pane %0 %1 %2"})
        state["next"] = 3
        self.state.write_text(json.dumps(state))
        ctx = self.prepare("--view=auto", TMUX=str(self.root / "socket") + ",1,0", TMUX_PANE="%0", AGENT_TEAM="legacy")
        self.assertEqual(ctx["status"], "ready-detached")
        self.assertEqual(self.read_state()["windows"]["@0"]["panes"], ["%0", "%1", "%2"])

    def test_concurrent_preparations_create_only_one_view(self):
        state = self.read_state()
        state["delay"] = {"split-window": 0.3}
        self.state.write_text(json.dumps(state))
        args = [str(self.plugin / "bin/team-3pane.sh"), "--view=tmux"]
        runs = [subprocess.Popen(args, cwd=self.workspace, env=self.env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = []
        for run in runs:
            out, err = run.communicate(timeout=20)
            self.assertEqual(run.returncode, 0, err)
            results.append(json.loads(out))
        self.assertEqual(results[0]["session"], results[1]["session"])
        self.assertEqual(sum(c[0] == "split-window" for c in self.read_state()["calls"]), 1)

    def test_partial_creation_cleans_only_the_new_unattached_view(self):
        state = self.read_state()
        state["fail"] = {"split-window": 1}
        self.state.write_text(json.dumps(state))
        ctx = self.prepare("--view=auto")
        self.assertEqual(ctx["status"], "manual")
        self.assertEqual(list(self.read_state()["windows"]), ["@0"])

    def test_false_success_socket_denial_falls_back_and_strict_fails(self):
        self.tool("tmux", 'if [ "$1" = -V ]; then echo "tmux 3.6"; else echo "Operation not permitted" >&2; fi\n')
        ctx = self.prepare("--view=auto")
        self.assertEqual(ctx["status"], "manual")
        self.assertEqual(ctx["reason_code"], "sandbox-denied")
        self.assertEqual(self.cli("team-3pane.sh", "--view=tmux").returncode, 2)

    def test_old_tmux_falls_back_before_mutation(self):
        self.tool("tmux", 'echo "tmux 3.1"\n')
        ctx = self.prepare("--view=auto")
        self.assertEqual(ctx["status"], "manual")
        self.assertIn(">=3.2", ctx["reason"])
        self.assertEqual(self.read_state()["calls"], [])

    def test_raw_context_and_invalid_combinations(self):
        raw = self.root / "nonstandard team"
        raw.mkdir()
        ctx = self.prepare("--view=auto", "--log-dir=" + str(raw))
        self.assertEqual(ctx["kind"], "log-dir")
        self.assertIsNone(ctx["team"])
        for args in (("--view=tmux", "--log-dir=" + str(raw)),
                     ("--view=nope",), ("--view=auto", "--view=none"),
                     ("--view=auto", "--here"), ("--view=auto", "--team=x")):
            with self.subTest(args=args):
                self.assertEqual(self.cli("team-3pane.sh", *args).returncode, 2)


class DispatchTests(ViewFixture):
    def setUp(self):
        super().setUp()
        self.calls = self.root / "engine-argv.json"
        self.env["RECORD_ARGS"] = str(self.calls)
        engine = self.plugin / "bin/debate.sh"
        engine.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ["RECORD_ARGS"]).write_text(json.dumps(args))
if os.environ.get("ENGINE_WAIT"):
    import signal, time
    pathlib.Path(os.environ["RECORD_ARGS"] + ".pid").write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    while True: time.sleep(0.1)
if "--help" in args or "-h" in args: sys.exit(0)
if os.environ.get("ENGINE_RC"): sys.exit(int(os.environ["ENGINE_RC"]))
if args and args[0] == "--continue-from":
    target = pathlib.Path(args[1])
else:
    target = pathlib.Path(os.environ["DEBATE_LOG_DIR"]) / os.environ["AGENT_TEAM"] / "debate-fixture"
target.mkdir(parents=True, exist_ok=True)
pathlib.Path(os.environ["DEBATE_RECEIPT"]).write_text(json.dumps(dict(
    schema_version=1, debate_dir=str(target), last_round=1, critic_round=None, critic_file=None)))
''')
        engine.chmod(0o755)

    def run_context(self, ctx, *args, **env):
        return self.cli("run-debate.sh", "--context", ctx["context_file"], *args, **env)

    def test_receipt_binding_and_private_context_paths(self):
        ctx = self.prepare()
        result = self.run_context(ctx, "--", "topic ' ; $(not-executed)")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_context(ctx, "--read-receipt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["debate_dir"], ctx["log_dir"] + "/debate-fixture")
        self.assertEqual(json.loads(self.calls.read_text()), ["topic ' ; $(not-executed)"])
        self.assertEqual(self.run_context(ctx, "--", "again").returncode, 2)

    def test_continuation_override_is_rejected_even_in_value_position(self):
        for args in (("--continue-from", "/other", "topic"),
                     ("--continue-from=/other", "topic"),
                     ("-n", "--continue-from", "topic")):
            with self.subTest(args=args):
                ctx = self.prepare()
                result = self.run_context(ctx, "--", *args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(Path(ctx["context_file"]).with_name("dispatch.started").exists())
                self.assertFalse(self.calls.exists())

    def test_validated_continuation_cannot_be_overridden_and_uses_physical_path(self):
        ctx = self.prepare()
        target = Path(ctx["log_dir"]) / "debate-existing"
        target.mkdir(parents=True)
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        result = self.run_context(ctx, "--continue-from", str(link), "--", "--continue-from=/other", "topic")
        self.assertEqual(result.returncode, 2)
        result = self.run_context(ctx, "--continue-from", str(link), "--", "topic contains --continue-from text")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.calls.read_text())[:2], ["--continue-from", str(target)])

    def test_raw_directory_is_continuation_only(self):
        raw = self.root / "nonstandard parent"
        target = raw / "debate-existing"
        target.mkdir(parents=True)
        ctx = self.prepare("--view=none", "--log-dir=" + str(raw))
        self.assertEqual(self.run_context(ctx, "--", "topic").returncode, 2)
        result = self.run_context(ctx, "--continue-from", str(target), "--", "topic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_context(ctx, "--read-receipt").returncode, 0)

    def test_failed_help_and_interrupted_dispatch_never_produce_success(self):
        for args, env in ((("--help",), {}), (("topic",), {"ENGINE_RC": "7"})):
            ctx = self.prepare()
            self.run_context(ctx, "--", *args, **env)
            self.assertEqual(self.run_context(ctx, "--read-receipt").returncode, 2)
        ctx = self.prepare()
        Path(ctx["context_file"]).with_name("dispatch.started").mkdir()
        self.assertEqual(self.run_context(ctx, "--read-receipt").returncode, 2)

    def test_context_permissions_and_symlink_are_rejected(self):
        ctx = self.prepare()
        path = Path(ctx["context_file"])
        path.chmod(0o644)
        self.assertEqual(self.run_context(ctx, "--", "topic").returncode, 2)
        path.chmod(0o600)
        other = path.with_name("saved.json")
        path.rename(other)
        path.symlink_to(other)
        self.assertEqual(self.run_context(ctx, "--", "topic").returncode, 2)

    def test_interrupt_waits_for_engine_cleanup_and_leaves_no_success_status(self):
        ctx = self.prepare()
        run = subprocess.Popen([str(self.plugin / "bin/run-debate.sh"), "--context", ctx["context_file"],
                                "--", "topic"], cwd=self.workspace, env=self.env | {"ENGINE_WAIT": "1"},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pid_file = Path(str(self.calls) + ".pid")
        deadline = time.monotonic() + 4
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(pid_file.exists())
        child = int(pid_file.read_text())
        run.send_signal(signal.SIGINT)
        out, err = run.communicate(timeout=5)
        self.assertEqual(run.returncode, 130, out + err)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        self.assertFalse(Path(ctx["context_file"]).with_name("dispatch-status.json").exists())


class OpenViewTests(ViewFixture):
    def test_manual_context_never_launches_terminal(self):
        self.tool("osascript", 'echo unexpected >&2; exit 99\n')
        ctx = self.prepare()
        result = self.cli("open-view.sh", "--context", ctx["context_file"])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["reason_code"], "no-view")

    def test_existing_client_is_reused_without_window(self):
        ctx = self.prepare("--view=tmux")
        state = self.read_state()
        state["clients"] = "existing-client\n"
        self.state.write_text(json.dumps(state))
        self.tool("osascript", 'exit 99\n')
        result = self.cli("open-view.sh", "--context", ctx["context_file"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "attached")

    def test_remote_environment_only_returns_instructions(self):
        ctx = self.prepare("--view=tmux")
        result = self.cli("open-view.sh", "--context", ctx["context_file"], SSH_CONNECTION="remote")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["reason_code"], "unsupported-host")

    @unittest.skipUnless(sys.platform == "darwin", "macOS terminal availability")
    def test_automation_denial_is_distinct_and_args_are_quoted(self):
        calls = self.root / "osascript-args.json"
        stub = self.tools / "osascript"
        stub.write_text(f"#!{sys.executable}\nimport json,pathlib,sys\n"
                        f"pathlib.Path({str(calls)!r}).write_text(json.dumps(sys.argv[1:]))\n"
                        "print('Not authorized to send Apple events. (-1743)',file=sys.stderr)\n"
                        "sys.exit(1)\n")
        stub.chmod(0o755)
        ctx = self.prepare("--view=tmux")
        result = self.cli("open-view.sh", "--context", ctx["context_file"], "--terminal=terminal")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["reason_code"], "automation-denied")
        script, command, cwd = json.loads(calls.read_text())
        self.assertTrue(script.endswith("open-terminal.applescript"))
        self.assertEqual(cwd, str(self.workspace))
        self.assertEqual(shlex.split(command)[-1], "=" + ctx["session"])
        self.assertIn("-u TMUX -u TMUX_PANE", command)


class RealEngineDispatchTests(ViewFixture):
    def test_both_host_pipelines_and_custom_root_continuation_use_receipts(self):
        stub = self.root / "recording provider"
        response = "Opening or critique.\n\nVerdict: STRENGTHEN\n"
        stub.write_text(f"#!{sys.executable}\n" + f'''
import json, pathlib, sys
args=sys.argv[1:]
if args == ['auth','status','--json']:
 print('{{"loggedIn":true,"authMethod":"fixture"}}');sys.exit(0)
sys.stdin.read()
response={response!r}
if '--output-last-message' in args:
 pathlib.Path(args[args.index('--output-last-message')+1]).write_text(response)
print(response)
''')
        stub.chmod(0o755)
        config = self.root / "models.json"
        config.write_text('{"models":{},"roles":{}}')
        self.env.update(AGY_CLI=str(stub), CODEX_CLI=str(stub), CLAUDE_CLI=str(stub),
                        AGENT_TEAM_MODELS_CONFIG=str(config))
        for host in ("claude", "codex"):
            with self.subTest(host=host):
                base = self.root / (host + " custom logs")
                ctx = self.prepare("--view=none", "--team=" + host, "--log-base=" + str(base))
                result = self.cli("run-debate.sh", "--host=" + host, "--context", ctx["context_file"],
                                  "--", "-n", "2", "self-contained fixture topic")
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = self.cli("run-debate.sh", "--read-receipt", "--context", ctx["context_file"])
                self.assertEqual(receipt.returncode, 0, receipt.stderr)
                data = json.loads(receipt.stdout)
                self.assertEqual(data["critic_round"], 2)
                self.assertEqual(Path(data["debate_dir"]).parent, base / host)
                again = self.prepare("--view=none", "--team=" + host, "--log-base=" + str(base))
                result = self.cli("run-debate.sh", "--host=" + host, "--context", again["context_file"],
                                  "--continue-from", data["debate_dir"], "--", "-n", "2", "self-contained fixture topic")
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = self.cli("run-debate.sh", "--read-receipt", "--context", again["context_file"])
                self.assertEqual(receipt.returncode, 0, receipt.stderr)
                self.assertEqual(json.loads(receipt.stdout)["debate_dir"], data["debate_dir"])
                self.assertEqual(json.loads(receipt.stdout)["critic_round"], 4)


@unittest.skipUnless(REAL_TMUX, "tmux is not installed")
class RealViewTests(ViewFixture):
    def setUp(self):
        super().setUp()
        self.tool("tmux", f"exec {shlex.quote(REAL_TMUX)} -f /dev/null \"$@\"\n")
        self.socket = self.root / ("tmux-" + str(os.getuid())) / "default"
        self.addCleanup(lambda: subprocess.run([REAL_TMUX, "-S", str(self.socket), "kill-server"],
                                              capture_output=True, timeout=5))

    def tmux(self, *args):
        return subprocess.run([REAL_TMUX, "-S", str(self.socket), *args],
                              capture_output=True, text=True, timeout=5)

    def test_real_two_role_output_reuse_and_dead_viewer_recovery(self):
        ctx = self.prepare("--view=tmux", AGENT_TEAM="real-test")
        run = Path(ctx["log_dir"]) / "debate-fixture"
        run.mkdir(parents=True)
        (run.parent / "latest-debate").symlink_to(run.name)
        # Use the actual selection publisher (schema and atomicity are its job).
        script = '. "$1/lib/selection.sh"; debate_selection_publish "$2" "$3"'
        subprocess.run(["bash", "-c", script, "bash", str(self.plugin), ctx["log_dir"], str(run)],
                       env=self.env, check=True, capture_output=True)
        (run / "stream-gen.log").write_text("GEN-205-SAME-DIRECTORY\n")
        (run / "stream-crit.log").write_text("CRIT-205-SAME-DIRECTORY\n")
        panes = self.tmux("list-panes", "-t", "=" + ctx["session"], "-F", "#{pane_id}").stdout.splitlines()
        self.assertEqual(len(panes), 2)
        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            captures = [self.tmux("capture-pane", "-p", "-t", pane).stdout for pane in panes]
            if "GEN-205-SAME-DIRECTORY" in captures[0] and "CRIT-205-SAME-DIRECTORY" in captures[1]:
                break
            time.sleep(0.2)
        self.assertIn("GEN-205-SAME-DIRECTORY", captures[0])
        self.assertIn("CRIT-205-SAME-DIRECTORY", captures[1])
        again = self.prepare("--view=tmux", AGENT_TEAM="real-test")
        self.assertEqual(ctx["session"], again["session"])
        self.assertEqual(self.tmux("list-panes", "-t", "=" + ctx["session"], "-F", "#{pane_id}").stdout.splitlines(), panes)
        self.tmux("send-keys", "-t", panes[0], "q")
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if self.tmux("display-message", "-p", "-t", panes[0], "#{pane_dead}").stdout.strip() == "1": break
            time.sleep(0.1)
        self.prepare("--view=tmux", AGENT_TEAM="real-test")
        self.assertEqual(self.tmux("display-message", "-p", "-t", panes[0], "#{pane_dead}").stdout.strip(), "0")


if __name__ == "__main__":
    unittest.main()
