#!/usr/bin/env python3
"""Real spec driver and dev-trio wrappers; replace only external model CLIs."""

import hashlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "spec-trio/bin/spec-trio.sh"

STUB = r"""#!/usr/bin/env python3
import os, sys, json, signal, time
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ['FIXTURE_STATE'])
role = 'reviewer' if '--output-last-message' in args else 'planner' if '# Role: Spec-driven Planner' in args[-1] else 'researcher' if Path(sys.argv[0]).name == 'researcher' else 'coder'
counter = state / (role + '.count')
n = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(n))
(state / (role + str(n) + '.prompt')).write_text(args[-1])
mutate = os.environ.get('MUTATE')
if mutate == role:
    Path(os.environ['FIXTURE_SPEC']).write_text('changed contract')
if mutate == role + '-snapshot':
    target = next(state.glob('logs/log/verify/contract-*/spec.md'))
    target.chmod(0o644)
    target.write_text('changed snapshot')
if mutate == role + '-delete':
    Path(os.environ['FIXTURE_SPEC']).unlink()
if mutate == role + '-worktree':
    Path('spec.md').write_text('changed worktree contract')
if mutate == role + '-backlog':
    Path('BACKLOG.md').write_text('- [x] falsely completed\n')
if role == 'planner':
    if os.environ.get('SLOW_PLANNER'):
        time.sleep(2)
    if os.environ.get('PLANNER_FAIL'):
        sys.exit(7)
    print('<allowed-paths>file.txt</allowed-paths>')
    if os.environ.get('PLAN_RESEARCH'):
        print('## NEED RESEARCH\n- lookup')
elif role == 'coder':
    if os.environ.get('INTERRUPT'):
        (state / 'ready').touch()
        time.sleep(30)
    Path('file.txt').write_text('good\n' if not os.environ.get('RETRY_TEST') or n > 1 else 'bad\n')
    if os.environ.get('STRAY'):
        Path('other.txt').write_text('outside scope')
    if os.environ.get('PROMISE'):
        Path(os.environ['FIXTURE_FIX']).write_text('<promise>COMPLETE</promise>\n')
    if os.environ.get('CODER_FAIL') == str(n):
        sys.exit(13)
elif role == 'researcher':
    print('fixture evidence')
else:
    final = Path(args[args.index('--output-last-message') + 1])
    verdict = os.environ.get('VERDICT', 'SHIP')
    if os.environ.get('RESEARCH_RETRY') and n == 1:
        verdict = 'NEEDS-FIX'
    body = 'invalid review' if verdict == 'UNKNOWN' else '## Verdict\n' + verdict + ' — fixture verdict\n'
    if os.environ.get('RESEARCH_RETRY') and n == 1:
        body += '## NEED RESEARCH\n- lookup\n'
    final.write_text(body)
    print(body)
"""


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="spec-verification-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo with spaces"
        self.repo.mkdir()
        self.state = self.base / "state"
        self.state.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(
                ("DEV_TRIO_", "MANIFEST_", "SPEC_TRIO_", "RALPH_", "AGENT_TEAM", "GIT_")
            ) or key in (
                "PLANNER_CLI",
                "CODER_CLI",
                "REVIEWER_CLI",
                "REVIEWER_ROLE_FILE",
                "RESEARCHER_CLI",
            ):
                self.env.pop(key, None)
        self.env.update(
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            PATH=f"{self.bin}:{ROOT / 'dev-trio/bin'}:" + os.environ["PATH"],
            AGENT_TEAM="verify",
            TMUX="",
            AGENT_TEAM_MODELS_CONFIG=str(self.base / "absent.json"),
            SPEC_TRIO_WORKSPACE=str(self.state / "logs"),
            FIXTURE_STATE=str(self.state),
            FIXTURE_SPEC=str(self.repo / "spec.md"),
            FIXTURE_FIX=str(self.repo / "fix_plan.md"),
            DEV_TRIO_REVIEWER_MODEL="codex",
            DEV_TRIO_RESEARCHER_MODEL="agy",
        )
        for name in ("worker", "reviewer", "researcher"):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env.update(
            CLAUDE_CLI=str(self.bin / "worker"),
            CODEX_CLI=str(self.bin / "reviewer"),
            AGY_CLI=str(self.bin / "researcher"),
        )
        real_git = shutil.which("git")
        (self.bin / "git").write_text(
            '#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\nf=os.environ.get("GIT_FAIL")\nif (f=="merge" and "merge" in a and "--ff-only" in a) or (f=="cleanup" and "worktree" in a and "remove" in a): sys.exit(1)\nos.execv('
            + repr(real_git)
            + ',["git"]+a)\n'
        )
        (self.bin / "git").chmod(0o755)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / "file.txt").write_text("baseline\n")
        (self.repo / "spec.md").write_text(
            "# Contract\n## §5 Test criteria\n### §5.1 valid value\nThe file must say good.\n"
        )
        (self.repo / "BACKLOG.md").write_text("- [ ] §5.1 update value\n")
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")
        self.command = 'test "$(cat file.txt)" = good'

    def tearDown(self):
        self.env.pop("GIT_FAIL", None)
        for line in self.git("worktree", "list", "--porcelain").splitlines():
            if (
                line.startswith("worktree ")
                and Path(line[9:]).resolve() != self.repo.resolve()
            ):
                self.git("worktree", "remove", "--force", line[9:])

    def git(self, *args):
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def args(self, *extra, test=True):
        result = [
            "bash",
            str(DRIVER),
            "--spec",
            str(self.repo / "spec.md"),
            "--backlog",
            str(self.repo / "BACKLOG.md"),
            "--max-iter",
            "1",
            "--no-research",
        ]
        if test:
            result += ["--test-cmd", self.command]
        if "--research" in extra:
            result.remove("--no-research")
            extra = tuple(x for x in extra if x != "--research")
        return result + list(extra)

    def run_driver(self, *extra, test=True):
        self.result = subprocess.run(
            self.args(*extra, test=test),
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=40,
            check=False,
        )
        return self.result

    def rc(self, expected):
        self.assertEqual(
            self.result.returncode, expected, self.result.stderr + self.result.stdout
        )

    def pending(self, expected=True):
        self.assertEqual("[ ]" in (self.repo / "BACKLOG.md").read_text(), expected)

    def manifests(self, variant="code"):
        return [
            json.loads(p.read_text())
            for p in sorted(
                (self.state / "logs/log/verify").glob(f"*-{variant}.manifest.json")
            )
        ]

    def test_duplicate_task_rows_complete_independently(self):
        task = "- [ ] §5.1 update value\n"
        (self.repo / "BACKLOG.md").write_text(task * 2)
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), task.replace("[ ]", "[x]") * 2
        )
        self.assertEqual((self.state / "coder.count").read_text(), "2")

    def test_runtime_cap_retains_pending_work(self):
        self.env.update(PLANNER_FAIL="1", SLOW_PLANNER="1")
        self.run_driver("--max-iter", "5", "--max-runtime", "1s")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "planner.count").read_text(), "1")
        self.assertIn("reason=max-runtime", self.result.stderr)

    def test_backlog_symlink_is_preserved_across_iterations(self):
        target = self.repo / "tasks.md"
        (self.repo / "BACKLOG.md").rename(target)
        (self.repo / "BACKLOG.md").symlink_to("tasks.md")
        target.write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.git("add", ".")
        self.git("commit", "-qm", "backlog link")
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.assertTrue((self.repo / "BACKLOG.md").is_symlink())
        self.assertEqual(target.read_text(), "- [x] §5.1 one\n- [x] §5.1 two\n")

    def test_worktree_retry_merges_only_passing_attempt(self):
        self.env["RETRY_TEST"] = "1"
        self.run_driver("--worktree", "--max-iter", "2")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_retry_test_failure_does_not_reuse_ship(self):
        self.env["RESEARCH_RETRY"] = "1"
        self.command = 'test "$(cat "$FIXTURE_STATE/coder.count")" = 1'
        self.run_driver("--research")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "1"
                for i in self.manifests("code2")[0]["inputs"]
            )
        )

    def test_atomic_backlog_write_failure_leaves_task_pending(self):
        (self.bin / "mv").write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            'if any(".spec-trio." in a for a in sys.argv[1:]): sys.exit(1)\n'
            + f'os.execv({shutil.which("mv")!r}, ["mv"] + sys.argv[1:])\n'
        )
        (self.bin / "mv").chmod(0o755)
        self.run_driver("--autoship")
        self.rc(1)
        self.pending()
        self.assertIn("completed=0", self.result.stderr)
        self.assertTrue(self.manifests("review"))

    def test_requires_test_before_mutation(self):
        for command in (None, "", "  "):
            with self.subTest(command=command):
                self.command = command or ""
                self.run_driver(test=command is not None)
                self.rc(2)
                self.assertFalse((self.repo / "fix_plan.md").exists())
                self.assertFalse((self.state / "logs").exists())
                self.assertFalse((self.state / "planner.count").exists())

    def test_success_snapshot_and_test_evidence(self):
        self.run_driver()
        self.rc(0)
        self.pending(False)
        inputs = self.manifests()[0]["inputs"]
        self.assertTrue(
            any(i["kind"] == "test-rc" and i["value"] == "0" for i in inputs)
        )
        specs = [
            next(i for i in m["inputs"] if i["kind"] == "spec")
            for v in ("plan", "code", "review")
            for m in self.manifests(v)
        ]
        self.assertEqual(len({i["path"] for i in specs}), 1)
        data = Path(specs[0]["path"]).read_bytes()
        self.assertEqual(data, (self.repo / "spec.md").read_bytes())
        self.assertTrue(
            all(i["sha256"] == hashlib.sha256(data).hexdigest() for i in specs)
        )
        self.assertIn("completed=1 pending=0", self.result.stderr)

    def test_test_failure_blocks_review_and_autoship(self):
        self.command = "exit 9"
        self.run_driver("--autoship", "--no-validate")
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "9"
                for i in self.manifests()[0]["inputs"]
            )
        )

    def test_missing_test_executable(self):
        self.command = "spec_trio_missing_test_executable"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_test_rechecks_scope(self):
        self.command += "; echo stray > other.txt"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_failed_test_retries_same_row_with_context(self):
        self.env["RETRY_TEST"] = "1"
        self.run_driver("--max-iter", "2")
        self.rc(0)
        self.pending(False)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] §5.1 update value\n"
        )
        self.assertIn(
            "Previous attempt failed", (self.state / "planner2.prompt").read_text()
        )
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_coder_failure_cannot_ship(self):
        self.env["CODER_FAIL"] = "1"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertTrue(
            any(
                i.get("value") == "skipped-coder-failed"
                for i in self.manifests()[0]["inputs"]
            )
        )

    def test_planner_failure_preserves_task(self):
        self.env["PLANNER_FAIL"] = "1"
        self.run_driver()
        self.rc(3)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())

    def test_research_retry_runs_tests_again(self):
        self.env["RESEARCH_RETRY"] = "1"
        self.run_driver("--research")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.state / "coder.count").read_text(), "2")
        self.assertEqual((self.state / "reviewer.count").read_text(), "2")
        self.assertTrue(
            any(
                i.get("kind") == "test-rc" and i["value"] == "0"
                for i in self.manifests("code2")[0]["inputs"]
            )
        )

    def test_research_retry_coder_failure(self):
        self.env.update(RESEARCH_RETRY="1", CODER_FAIL="2")
        self.run_driver("--research")
        self.rc(3)
        self.pending()
        self.assertEqual((self.state / "reviewer.count").read_text(), "1")

    def test_human_verdict_stops_before_next_task(self):
        for verdict in ("DISCUSS", "UNKNOWN", "OUT-OF-SCOPE"):
            with self.subTest(verdict=verdict):
                self.env["VERDICT"] = verdict
                self.run_driver("--max-iter", "4")
                self.rc(4)
                self.pending()
        self.assertEqual((self.state / "coder.count").read_text(), "3")

    def test_original_mutation_stops_stages(self):
        self.env["MUTATE"] = "planner"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())
        self.assertEqual((self.repo / "spec.md").read_text(), "changed contract")

    def test_snapshot_mutation(self):
        self.env["MUTATE"] = "coder-snapshot"
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_deleted_spec(self):
        self.env["MUTATE"] = "coder-delete"
        self.run_driver()
        self.rc(4)
        self.pending()

    def test_reviewer_spec_mutation(self):
        self.env["MUTATE"] = "reviewer"
        self.run_driver()
        self.rc(4)
        self.pending()

    def test_test_spec_mutation(self):
        self.command = 'echo changed > "$FIXTURE_SPEC"'
        self.run_driver()
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_research_spec_mutation(self):
        self.env.update(PLAN_RESEARCH="1", MUTATE="researcher")
        self.run_driver("--research")
        self.rc(4)
        self.pending()
        self.assertFalse((self.state / "coder.count").exists())

    def test_backlog_conflict_not_overwritten(self):
        self.env["MUTATE"] = "coder-backlog"
        self.run_driver()
        self.rc(4)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] falsely completed\n"
        )
        self.assertIn("completed=0", self.result.stderr)

    def test_stale_promise_does_not_complete_remaining_task(self):
        (self.repo / "BACKLOG.md").write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.env["PROMISE"] = "1"
        self.run_driver()
        self.rc(3)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "- [x] §5.1 one\n- [ ] §5.1 two\n"
        )

    def test_dry_run_does_not_requeue_or_execute(self):
        before = (self.repo / "BACKLOG.md").read_bytes()
        self.run_driver("--dry-run", "--coverage-requeue", test=False)
        self.rc(0)
        self.assertEqual(before, (self.repo / "BACKLOG.md").read_bytes())
        self.assertFalse((self.state / "planner.count").exists())
        self.assertIn("status=dry-run completed=0", self.result.stderr)

    def coverage_hook(self, body):
        # Run a deterministic concurrent-edit fixture during classification,
        # without replacing the actual coverage helper or production driver.
        git = shutil.which("git")
        marker = self.state / "coverage-hook-fired"
        (self.bin / "git").write_text(
            "#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
            + f"marker=Path({str(marker)!r})\n"
            + 'if "log" in sys.argv[1:] and not marker.exists():\n'
            + "    marker.touch()\n"
            + "\n".join("    " + line for line in body.splitlines())
            + f'\nos.execv({git!r}, ["git"] + sys.argv[1:])\n'
        )
        (self.bin / "git").chmod(0o755)

    def check_coverage_backlog_conflict(self, flag):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [ ] §5.1 one\n- [ ] §5.1 two\n")
        self.coverage_hook(
            f"p=Path({str(backlog)!r})\np.write_text(p.read_text().replace('[ ]', '[x]'))"
        )
        self.run_driver(flag)
        self.rc(4)
        self.assertEqual((self.state / "coder.count").read_text(), "1")
        self.assertIn("status=blocked completed=1", self.result.stderr)
        self.assertEqual(backlog.read_text(), "- [x] §5.1 one\n- [x] §5.1 two\n")
        self.assertNotIn("spec coverage gap", backlog.read_text())

    def test_read_only_coverage_rejects_backlog_changes(self):
        self.check_coverage_backlog_conflict("--coverage-check")

    def test_requeue_rejects_backlog_changes_before_applying_additions(self):
        self.check_coverage_backlog_conflict("--coverage-requeue")

    def test_coverage_requeue_persistence_failure(self):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [x] already complete\n")
        backlog.chmod(0o444)
        self.addCleanup(backlog.chmod, 0o644)
        if os.access(backlog, os.W_OK):
            self.skipTest("requires a user without write access to a read-only file")
        self.run_driver("--coverage-requeue")
        self.rc(1)
        self.assertIn("reason=coverage-persistence-failed", self.result.stderr)
        self.assertEqual(backlog.read_text(), "- [x] already complete\n")
        self.assertNotIn("status=completed", self.result.stderr)

    def test_standalone_coverage_propagates_append_failure(self):
        destination = self.base / "read-only-backlog"
        destination.write_text("- [x] already complete\n")
        destination.chmod(0o444)
        self.addCleanup(destination.chmod, 0o644)
        if os.access(destination, os.W_OK):
            self.skipTest("requires a user without write access to a read-only file")
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "spec-trio/bin/spec-coverage.sh"),
                "--spec",
                str(self.repo / "spec.md"),
                "--no-partial",
                "--requeue",
                str(destination),
            ],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("0 additions written", result.stderr)
        self.assertNotIn("appended 1", result.stderr)
        self.assertEqual(destination.read_text(), "- [x] already complete\n")

    def test_requeue_uses_guarded_atomic_publication(self):
        backlog = self.repo / "BACKLOG.md"
        backlog.write_text("- [x] already complete")
        self.run_driver("--coverage-requeue")
        self.rc(3)
        self.assertEqual(
            backlog.read_text(),
            "- [x] already complete\n- [ ] (spec coverage gap §5.1) valid value\n",
        )
        self.assertFalse((self.state / "coder.count").exists())

    def check_intermediate_symlink_retarget(self, name):
        original = self.repo / name
        old = self.base / ("old-" + name)
        new = self.base / ("new-" + name)
        chain = self.base / ("middle-" + name)
        content = original.read_text()
        old.write_text(content)
        new.write_text(content)
        chain.symlink_to(old)
        original.unlink()
        original.symlink_to(chain)
        self.git("add", name)
        self.git("commit", "-qm", "chain fixture")
        self.env.update(FIXTURE_CHAIN=str(chain), FIXTURE_NEW=str(new))
        self.command = 'ln -sfn "$FIXTURE_NEW" "$FIXTURE_CHAIN"; ' + self.command
        self.run_driver()
        self.rc(4)
        self.assertEqual(old.read_text(), content)
        self.assertEqual(new.read_text(), content)
        self.assertEqual(original.resolve(), new)
        self.assertFalse((self.state / "reviewer.count").exists())
        self.assertIn("completed=0", self.result.stderr)

    def test_backlog_chain_retarget_cannot_complete_old_destination(self):
        self.check_intermediate_symlink_retarget("BACKLOG.md")

    def test_spec_chain_retarget_is_a_contract_change(self):
        self.check_intermediate_symlink_retarget("spec.md")

    def physical_parent_fixture(self, name, *, direct=False):
        local = self.base / "local"
        remote = self.base / "remote"
        local.mkdir()
        (remote / "child").mkdir(parents=True)
        content = (self.repo / name).read_text()
        actual = remote / name
        decoy = local / name
        actual.write_text(content)
        decoy.write_text(content)
        (local / "dirlink").symlink_to(remote / "child")
        if direct:
            supplied = local / "dirlink" / ".." / name
        else:
            supplied = local / "input"
            supplied.symlink_to("dirlink/../" + name)
        self.assertEqual(supplied.read_text(), content)
        return supplied, actual, decoy, content

    def test_physical_parent_spec_guard(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("spec.md")
        self.env.update(MUTATE="coder", FIXTURE_SPEC=str(actual))
        self.run_driver("--spec", str(supplied))
        self.rc(4)
        self.assertEqual(decoy.read_text(), content)
        self.pending()
        self.assertFalse((self.state / "reviewer.count").exists())

    def test_physical_parent_completion(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("BACKLOG.md")
        self.run_driver("--backlog", str(supplied))
        self.rc(0)
        self.assertEqual(actual.read_text(), content.replace("[ ]", "[x]"))
        self.assertEqual(decoy.read_text(), content)
        self.assertTrue(supplied.is_symlink())

    def test_physical_parent_requeue(self):
        supplied, actual, decoy, content = self.physical_parent_fixture("BACKLOG.md")
        actual.write_text("- [x] already complete\n")
        self.run_driver("--backlog", str(supplied), "--coverage-requeue")
        self.rc(3)
        self.assertEqual(
            actual.read_text(),
            "- [x] already complete\n- [ ] (spec coverage gap §5.1) valid value\n",
        )
        self.assertEqual(decoy.read_text(), content)
        self.assertFalse((self.state / "coder.count").exists())

    def test_direct_physical_parent_backlog_path(self):
        supplied, actual, decoy, content = self.physical_parent_fixture(
            "BACKLOG.md", direct=True
        )
        self.run_driver("--backlog", str(supplied))
        self.rc(0)
        self.assertEqual(actual.read_text(), content.replace("[ ]", "[x]"))
        self.assertEqual(decoy.read_text(), content)

    def test_post_publication_edit_is_not_adopted_as_expected_content(self):
        real_mv = shutil.which("mv")
        (self.bin / "mv").write_text(
            "#!/usr/bin/env python3\nimport sys,subprocess\nfrom pathlib import Path\n"
            + f"subprocess.run([{real_mv!r}] + sys.argv[1:], check=True)\n"
            + 'if any(".spec-trio." in a for a in sys.argv[1:]):\n'
            + '    Path(sys.argv[-1]).write_text("external replacement\\n")\n'
        )
        (self.bin / "mv").chmod(0o755)
        self.run_driver("--autoship")
        self.rc(4)
        self.assertEqual(
            (self.repo / "BACKLOG.md").read_text(), "external replacement\n"
        )
        self.assertNotIn("status=completed", self.result.stderr)

    def test_coverage_requeue_makes_run_pending(self):
        self.run_driver("--coverage-requeue")
        self.rc(3)
        self.assertIn("spec coverage gap §5.1", (self.repo / "BACKLOG.md").read_text())
        self.assertIn("reason=coverage-requeued", self.result.stderr)

    def test_worktree_success(self):
        self.run_driver("--worktree")
        self.rc(0)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")

    def test_worktree_spec_mutation(self):
        self.env["MUTATE"] = "coder-worktree"
        self.run_driver("--worktree")
        self.rc(4)
        self.pending()
        self.assertEqual((self.repo / "file.txt").read_text(), "baseline\n")

    def test_worktree_merge_failure(self):
        self.env["GIT_FAIL"] = "merge"
        self.run_driver("--worktree")
        self.rc(1)
        self.pending()
        self.assertEqual((self.repo / "file.txt").read_text(), "baseline\n")

    def test_worktree_cleanup_failure_after_merge(self):
        self.env["GIT_FAIL"] = "cleanup"
        self.run_driver("--worktree")
        self.rc(1)
        self.pending(False)
        self.assertEqual((self.repo / "file.txt").read_text(), "good\n")
        self.assertIn("completed=1", self.result.stderr)

    def test_interrupt_retains_pending_task(self):
        self.env["INTERRUPT"] = "1"
        proc = subprocess.Popen(
            self.args(),
            cwd=self.repo,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 15
            while (
                not (self.state / "ready").exists()
                and time.monotonic() < deadline
                and proc.poll() is None
            ):
                time.sleep(0.05)
            self.assertTrue((self.state / "ready").exists())
            os.killpg(proc.pid, signal.SIGINT)
            _, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 130, err)
            self.pending()
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()

    def test_coverage_uses_complete_identifier(self):
        (self.repo / "file.txt").write_text("changed\n")
        self.git("add", "file.txt")
        self.git("commit", "-qm", "spec §5.10, §5.100 and §5.1.2 only")
        args = [
            "bash",
            str(ROOT / "spec-trio/bin/spec-coverage.sh"),
            "--spec",
            str(self.repo / "spec.md"),
            "--no-partial",
        ]
        result = subprocess.run(
            args,
            cwd=self.repo,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("NOT-COVERED", result.stdout)
        self.git("commit", "--allow-empty", "-qm", "spec §5.1. Also §5.10.")
        result = subprocess.run(
            args,
            cwd=self.repo,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertNotIn("NOT-COVERED", result.stdout)
        self.assertIn("COVERED", result.stdout)


if __name__ == "__main__":
    unittest.main()
