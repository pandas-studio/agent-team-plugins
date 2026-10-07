"""spec-forge gate and lint (RFC 0005 PR 1).

Every case starts from tests/fixtures/valid, copied into a temporary directory,
and changes one thing. A lint case asserts the exact set of rule IDs reported,
so a mutation aimed at one rule fails loudly if it trips another.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
ROOT = PLUGIN.parent
CLI = PLUGIN / "bin/spec-forge"
VALID = PLUGIN / "tests/fixtures/valid"
DRAFTS = ("spec.md", "BACKLOG.md", "report.md")


def scrubbed_path():
    dirs = ["/usr/bin", "/bin"]
    for tool in ("jq", "git"):
        found = shutil.which(tool)
        if found and os.path.dirname(found) not in dirs:
            dirs.append(os.path.dirname(found))
    return os.pathsep.join(dirs)


class SpecForgeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="spec-forge-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.env = {
            "PATH": scrubbed_path(),
            "HOME": str(self.tmp / "home"),
            "TMPDIR": str(self.tmp),
            "SPEC_TRIO_BIN": str(ROOT / "spec-trio/bin"),
            "DEBATE_CONDUCTOR_BIN": str(ROOT / "debate-conductor/bin"),
            "LANG": "C.UTF-8",
        }
        self.decision = self.tmp / "design-decision.md"
        shutil.copy(VALID / "decision.md", self.decision)

    def run_cli(self, *args, env=None):
        merged = dict(self.env, **(env or {}))
        return subprocess.run([str(CLI), *args], cwd=self.tmp, env=merged,
                              capture_output=True, text=True, timeout=60)

    def gate(self, *extra):
        return self.run_cli("gate", "--decision", str(self.decision),
                            "--workspace", str(self.tmp / "ws"), *extra)

    def edit(self, path, old, new):
        text = path.read_text()
        self.assertIn(old, text, f"fixture lacks {old!r}")
        path.write_text(text.replace(old, new, 1))


class GateTest(SpecForgeCase):
    def test_confirmed_decision_opens_a_private_run(self):
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        run = Path(result.stdout.strip())
        self.assertEqual(run.parent, (self.tmp / "ws/runs").resolve())
        for path in (run, run.parent, run.parent.parent):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700, path)
        self.assertEqual((run / "decision.md").read_bytes(), self.decision.read_bytes())
        meta = json.loads((run / "run.json").read_text())
        self.assertEqual(meta["schema_version"], 1)
        self.assertEqual(meta["run_id"], run.name)
        self.assertEqual(meta["decision"]["path"], str(self.decision.resolve()))
        self.assertEqual(meta["decision"]["sha256"],
                         hashlib.sha256(self.decision.read_bytes()).hexdigest())
        self.assertIsNone(meta["debate"])

    def test_each_run_is_fresh(self):
        first, second = self.gate(), self.gate()
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        self.assertNotEqual(first.stdout, second.stdout)

    def assert_refused(self, needle, *extra):
        result = self.gate(*extra)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn(needle, result.stderr)
        self.assertFalse((self.tmp / "ws/runs").exists() and any((self.tmp / "ws/runs").iterdir()))

    def test_undecided_status_is_refused(self):
        self.edit(self.decision, "- 상태: 확정 — 2026-10-06 사용자 확인",
                  "- 상태: 미결정 — 사용자 선택이 확인된 뒤 확정으로 변경")
        self.assert_refused("must start with 확정")

    def test_missing_status_is_refused(self):
        self.edit(self.decision, "- 상태: 확정 — 2026-10-06 사용자 확인\n", "")
        self.assert_refused("required field '상태' is missing")

    def test_placeholder_is_refused(self):
        self.edit(self.decision, "`python3 -m unittest tests.test_reports -v`", "__ACCEPTANCE_COMMAND__")
        self.assert_refused("placeholder __ACCEPTANCE_COMMAND__")

    def test_empty_required_field_is_refused(self):
        self.edit(self.decision,
                  "- 허용할 인터페이스 변경·호환성 요구: `GET /reports/{id}` 응답 형식 유지. `?refresh=1` 추가 허용.",
                  "- 허용할 인터페이스 변경·호환성 요구:")
        self.assert_refused("'허용할 인터페이스 변경·호환성 요구' is empty")

    def test_indented_continuation_fills_a_field(self):
        self.edit(self.decision,
                  "- 허용할 인터페이스 변경·호환성 요구: `GET /reports/{id}` 응답 형식 유지. `?refresh=1` 추가 허용.",
                  "- 허용할 인터페이스 변경·호환성 요구:\n  `GET /reports/{id}` 응답 형식 유지.")
        self.assertEqual(self.gate().returncode, 0)

    def test_duplicate_field_is_refused(self):
        self.decision.write_text(self.decision.read_text() + "- 수용 기준과 실제 검사 명령: `true`\n")
        self.assert_refused("appears 2 times")

    def test_missing_file_and_bad_arguments(self):
        self.decision.unlink()
        self.assertEqual(self.gate().returncode, 2)
        self.assertEqual(self.run_cli("gate").returncode, 2)
        self.assertEqual(self.run_cli("gate", "--bogus").returncode, 2)
        self.assertEqual(self.run_cli("audit").returncode, 2)
        self.assertEqual(self.run_cli("gate", "--help").returncode, 0)

    def debate(self, critic=True):
        debate_dir = self.tmp / "debate-20261001-090000"
        debate_dir.mkdir()
        if critic:
            (debate_dir / "round-2-crit.md").write_text("Verdict: STRENGTHEN\n")
        receipt = self.tmp / "receipt.json"
        receipt.write_text(json.dumps({
            "schema_version": 1, "debate_dir": str(debate_dir.resolve()), "last_round": 2,
            "critic_round": 2 if critic else None,
            "critic_file": "round-2-crit.md" if critic else None}))
        return debate_dir, receipt

    def test_debate_receipt_is_recorded(self):
        debate_dir, receipt = self.debate()
        result = self.gate("--debate-receipt", str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        meta = json.loads((Path(result.stdout.strip()) / "run.json").read_text())
        self.assertEqual(meta["debate"], {
            "receipt": str(receipt.resolve()), "debate_dir": str(debate_dir.resolve()),
            "critic_round": 2, "critic_file": "round-2-crit.md"})

    def test_debate_without_critic_round_warns(self):
        _, receipt = self.debate(critic=False)
        result = self.gate("--debate-receipt", str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no completed critic round", result.stderr)

    def test_moved_debate_transcripts_are_refused(self):
        debate_dir, receipt = self.debate()
        shutil.rmtree(debate_dir)
        self.assert_refused("transcripts moved", "--debate-receipt", str(receipt))

    def test_missing_debate_conductor_is_refused(self):
        _, receipt = self.debate()
        result = self.run_cli("gate", "--decision", str(self.decision), "--workspace",
                              str(self.tmp / "ws"), "--debate-receipt", str(receipt),
                              env={"DEBATE_CONDUCTOR_BIN": str(self.tmp / "nowhere")})
        self.assertEqual(result.returncode, 2)
        self.assertIn("DEBATE_CONDUCTOR_BIN", result.stderr)


class LintTest(SpecForgeCase):
    def setUp(self):
        super().setUp()
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_dir = Path(result.stdout.strip())
        for name in DRAFTS:
            shutil.copy(VALID / name, self.run_dir / name)

    def lint(self, env=None):
        return self.run_cli("lint", "--run", str(self.run_dir), env=env)

    def rules(self):
        result = self.lint()
        report = json.loads((self.run_dir / "lint.json").read_text())
        found = {v["rule"] for v in report["violations"]}
        self.assertEqual(result.returncode, 5 if found else 0, result.stdout + result.stderr)
        self.assertEqual(report["ok"], not found)
        lines = [l for l in result.stdout.splitlines() if l]
        self.assertEqual(len(lines), len(report["violations"]))
        return found

    def spec(self, old, new):
        self.edit(self.run_dir / "spec.md", old, new)

    def backlog(self, old, new):
        self.edit(self.run_dir / "BACKLOG.md", old, new)

    def report(self, old, new):
        self.edit(self.run_dir / "report.md", old, new)

    def test_valid_draft_is_clean(self):
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        report = json.loads((self.run_dir / "lint.json").read_text())
        self.assertTrue(report["ok"])
        self.assertEqual(sorted(report["files"]), sorted(DRAFTS))
        self.assertEqual(stat.S_IMODE((self.run_dir / "lint.json").stat().st_mode), 0o600)

    def test_criteria_match_spec_trio_parser(self):
        out = subprocess.run(
            ["bash", "-c", '. "$1"; parse_test_criteria "$2" | cut -f1',
             "_", str(ROOT / "spec-trio/lib/spec-helpers.sh"), str(self.run_dir / "spec.md")],
            capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(out, ["§5.1", "§5.2"])

    def test_violation_line_format(self):
        self.spec("- `python3 -m unittest tests.test_reports.CacheTest -v`", "- the cache is hit")
        result = self.lint()
        self.assertEqual(result.stdout.strip(),
                         "spec.md:28: S4 §5.1 has no command; quote at least one check in backticks")

    def test_F1_missing_file(self):
        (self.run_dir / "report.md").unlink()
        self.assertEqual(self.rules(), {"F1"})

    def test_S1_missing_section(self):
        self.spec("## §6 Non-goals\n", "")
        self.report("| §6 | 채택 대안·기각 대안과 이유 |\n", "")
        self.assertEqual(self.rules(), {"S1"})

    def test_S1_duplicate_and_out_of_order(self):
        (self.run_dir / "spec.md").write_text((self.run_dir / "spec.md").read_text() + "\n## §2 Again\n")
        self.assertEqual(self.rules(), {"S1"})
        self.assertIn("duplicate section ## §2", self.lint().stdout)

    def test_S2_no_criteria(self):
        self.spec("### §5.1 Cache hit", "### Cache hit")
        self.spec("### §5.2 Refresh bypass", "### Refresh bypass")
        self.backlog("(§2, §3.1, §5.1)", "(§2, §3.1)")
        self.backlog("(§3.2, §5.2)", "(§3.2)")
        self.report("| §5.1 | 수용 기준과 실제 검사 명령 |\n| §5.2 | acceptance |\n", "")
        self.assertEqual(self.rules(), {"S2"})

    def test_S2_fenced_criterion_counted_by_spec_trio(self):
        self.spec("python3 -m unittest tests.test_reports.RefreshTest -v\n",
                  "python3 -m unittest tests.test_reports.RefreshTest -v\n### §5.9 not a criterion\n")
        self.assertEqual(self.rules(), {"S2"})
        self.assertIn("spec-trio counts §5.9", self.lint().stdout)

    def test_S2_fenced_heading_hides_criterion_from_spec_trio(self):
        self.spec("### §5.2 Refresh bypass", "```text\n## §9 example\n```\n\n### §5.2 Refresh bypass")
        self.assertEqual(self.rules(), {"S2"})
        self.assertIn("spec-trio does not see §5.2", self.lint().stdout)

    def test_S3_duplicate_criterion(self):
        self.spec("## §6 Non-goals", "### §5.1 Cache hit again\n\n- `true`\n\n## §6 Non-goals")
        self.assertEqual(self.rules(), {"S3"})

    def test_S4_criterion_without_command(self):
        self.spec("- `python3 -m unittest tests.test_reports.CacheTest -v`", "- the cache is hit")
        self.assertEqual(self.rules(), {"S4"})

    def test_S4_commented_command_does_not_count(self):
        self.spec("- `python3 -m unittest tests.test_reports.CacheTest -v`",
                  "<!-- `python3 -m unittest tests.test_reports.CacheTest -v` -->")
        self.assertEqual(self.rules(), {"S4"})

    def test_B1_near_miss_task(self):
        self.backlog("- [x] (§4)", "* [ ] (§5.1) Also check the cache.\n- [x] (§4)")
        self.assertEqual(self.rules(), {"B1"})

    def test_B1_fenced_task(self):
        self.backlog("- [x] (§4)", "```\n- [ ] (§5.1) example\n```\n- [x] (§4)")
        self.assertEqual(self.rules(), {"B1"})

    def test_B1_no_pending_task(self):
        path = self.run_dir / "BACKLOG.md"
        path.write_text(path.read_text().replace("- [ ]", "- [x]"))
        self.assertEqual(self.rules(), {"B1", "B4"})

    def test_B2_task_without_citation(self):
        self.backlog("- [x] (§4)", "- [ ] Tidy up.\n- [x] (§4)")
        self.assertEqual(self.rules(), {"B2"})

    def test_B3_unknown_citation(self):
        self.backlog("- [x] (§4)", "- [ ] (spec §7.1) Something else.\n- [x] (§4)")
        self.assertEqual(self.rules(), {"B3"})

    def test_B4_uncited_criterion(self):
        self.backlog("(§3.2, §5.2)", "(spec §3.2)")
        self.assertEqual(self.rules(), {"B4"})

    def test_requeue_citation_form_counts(self):
        self.backlog("(§3.2, §5.2)", "(§3.2)")
        self.backlog("- [x] (§4)", "- [ ] (spec coverage gap §5.2) Refresh bypass\n- [x] (§4)")
        self.assertEqual(self.rules(), set())

    def test_P1_missing_row(self):
        self.report("| §3.2 | 허용할 인터페이스 변경·호환성 요구 |\n", "")
        self.assertEqual(self.rules(), {"P1"})

    def test_P1_unknown_label(self):
        self.report("| §5.2 | acceptance |", "| §5.2 | the user said so |")
        self.assertEqual(self.rules(), {"P1"})

    def test_P1_row_for_undefined_section(self):
        self.report("| §6 |", "| §7 | 채택 대안·기각 대안과 이유 |\n| §6 |")
        self.assertEqual(self.rules(), {"P1"})

    def test_P1_missing_table(self):
        self.report("## Provenance", "## Origins")
        self.assertEqual(self.rules(), {"P1"})

    def test_P2_template_placeholder(self):
        self.spec("- Background job processing (alternative B, rejected).",
                  "- Background job processing (alternative B, rejected).\n- <thing this spec does not address>")
        self.assertEqual(self.rules(), {"P2"})

    def test_P2_upper_snake_placeholder(self):
        self.report("- 없음", "- __OPEN_QUESTION__")
        self.assertEqual(self.rules(), {"P2"})

    def test_not_a_run_directory(self):
        (self.run_dir / "run.json").unlink()
        self.assertEqual(self.lint().returncode, 2)

    def test_missing_spec_trio(self):
        result = self.lint(env={"SPEC_TRIO_BIN": str(self.tmp / "nowhere")})
        self.assertEqual(result.returncode, 2)
        self.assertIn("SPEC_TRIO_BIN", result.stderr)


class SpecTrioCompatibilityTest(SpecForgeCase):
    """A clean draft is accepted by the spec-trio tools that will consume it."""

    def test_spec_trio_accepts_the_valid_draft(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        for name in ("spec.md", "BACKLOG.md"):
            shutil.copy(VALID / name, repo / name)
        git = ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t"]
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True, env=self.env)
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "init"], cwd=repo,
                       check=True, env=self.env)
        env = dict(self.env, SPEC_TRIO_WORKSPACE=str(self.tmp / "spec-trio-ws"))
        dry = subprocess.run([str(ROOT / "spec-trio/bin/spec-trio.sh"), "--spec", "spec.md",
                              "--backlog", "BACKLOG.md", "--max-iter", "1", "--dry-run"],
                             cwd=repo, env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertIn("pending=2", dry.stdout + dry.stderr)
        cov = subprocess.run([str(ROOT / "spec-trio/bin/spec-coverage.sh"), "--spec", "spec.md"],
                             cwd=repo, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(cov.returncode, 0, cov.stdout + cov.stderr)
        self.assertIn("§5.1", cov.stdout)
        self.assertIn("§5.2", cov.stdout)


if __name__ == "__main__":
    unittest.main()
