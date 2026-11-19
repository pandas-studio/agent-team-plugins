"""Content evidence and stream separation for the two loop drivers."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "ralph-trio/lib/stage-result.sh"
RUN = r'''
set -uo pipefail
. "$1"
ORIGINAL_DIR="$2"
STAGE_IGNORE_PATHS=("$2/.harness" "$2/BACKLOG.md" "$2/fix_plan.md")
rc=0
stage_run "$3" "$2" "$2/.harness/stage.log" bash -c "$4" || rc=$?
jq -cn --argjson rc "$rc" --arg cli "$STAGE_CLI_RC" --arg evidence "$STAGE_EVIDENCE" \
  '{rc:$rc,cli:$cli,evidence:$evidence}'
'''


class StageResultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="stage-results-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo with spaces"
        self.repo.mkdir()
        # Isolate XDG ignore rules for this repository and nested clone fixtures.
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                        XDG_CONFIG_HOME=str(Path(self.tmp.name) / "xdg"))
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Fixture")
        (self.repo / "file.txt").write_text("baseline\n")
        self.git("add", "file.txt")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
        (self.repo / ".harness").mkdir()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              check=True, capture_output=True, text=True).stdout

    def run_stage(self, command, role="coder", expected=0, cli="0", evidence=None, setup=""):
        script = RUN.replace("rc=0\n", setup + "\nrc=0\n", 1)
        result = subprocess.run(["bash", "-c", script, "test", str(LIB), str(self.repo), role, command],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["rc"], expected, result.stderr)
        self.assertEqual(data["cli"], cli, result.stderr)
        if evidence:
            self.assertEqual(data["evidence"], evidence)
        return data

    def test_non_git_original_keeps_physical_path_for_ignore_mapping(self):
        original = Path(self.tmp.name) / "original"
        original.mkdir()
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(original, target_is_directory=True)
        result = subprocess.run(
            ["bash", "-c", '\n'.join([
                '. "$1"',
                'STAGE_IGNORE_PATHS=("$3/state")',
                'stage_prepare_ignores "$2" "$3" || exit $?',
                'stage_path_ignored "$2/state/file"',
            ]), "test", str(LIB), str(self.repo.resolve()), str(alias)],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stderr_and_whitespace_are_not_evidence(self):
        for command in ("echo denied >&2", "printf ' \\n\\t'; echo denied >&2", ":"):
            with self.subTest(command=command):
                self.run_stage(command, expected=5, evidence="none")

    def test_planner_stdout_is_separate_from_diagnostics(self):
        self.run_stage("echo real-plan; echo '<allowed-paths>fake</allowed-paths>' >&2", role="planner", evidence="stdout")
        self.assertEqual((self.repo / ".harness/stage.stdout.log").read_text(), "real-plan\n")
        self.assertIn("fake", (self.repo / ".harness/stage.log").read_text())
        self.run_stage("echo denied >&2", role="planner", expected=5)
        self.assertEqual((self.repo / ".harness/stage.stdout.log").read_text(), "")

    def test_planner_file_change_is_not_a_plan(self):
        self.run_stage("echo changed > file.txt", role="planner", expected=5)

    def test_summary_without_change(self):
        self.run_stage("echo 'already satisfied'", evidence="stdout")

    def test_silent_changes(self):
        for command in ("echo changed > file.txt", "echo new > new.txt", "echo newer > new.txt",
                        "rm file.txt", "mv new.txt renamed.txt", "chmod +x renamed.txt",
                        "ln -s renamed.txt link", "rm link; ln -s missing link"):
            with self.subTest(command=command):
                self.run_stage(command, evidence="change")

    def test_same_status_different_bytes(self):
        (self.repo / "file.txt").write_text("already dirty\n")
        self.run_stage("echo changed-again > file.txt", evidence="change")
        self.run_stage("echo denied >&2", expected=5)

    def test_preexisting_untracked_content_is_not_evidence(self):
        (self.repo / "new.txt").write_text("already here\n")
        self.run_stage(":", expected=5)

    def test_staging_alone_is_not_content_change(self):
        (self.repo / "file.txt").write_text("already dirty\n")
        self.run_stage("git add file.txt", expected=5)
        self.run_stage("git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm existing", expected=5)

    def test_silent_committed_change_and_empty_commit(self):
        commit = "git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture"
        self.run_stage("echo changed > file.txt; git add file.txt; " + commit, evidence="change")
        self.run_stage(commit + " --allow-empty", expected=5)

    def test_nonzero_cli_wins_over_content_and_output(self):
        self.run_stage("echo changed > file.txt; echo summary; exit 17", expected=17, cli="17")

    def test_harness_changes_are_not_content_evidence(self):
        self.run_stage("echo data > .harness/extra; echo denied > fix_plan.md; echo bookkeeping > BACKLOG.md; echo denied >&2", expected=5)

    def test_harness_symlink_target_is_excluded(self):
        (self.repo / "notes.txt").write_text("old bookkeeping")
        (self.repo / "fix_plan.md").symlink_to("notes.txt")
        self.run_stage("echo bookkeeping >> fix_plan.md", expected=5)

    def test_submodule_content_not_just_head(self):
        source = Path(self.tmp.name) / "sub-source"
        subprocess.run(["git", "clone", "-q", str(self.repo), str(source)],
                       env=self.env, check=True, capture_output=True)
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(source), "vendor")
        self.run_stage(":", expected=5)
        self.run_stage("echo changed > vendor/file.txt", evidence="change")
        self.run_stage("echo new > vendor/new.txt", evidence="change")
        self.run_stage(":", expected=5)

    def test_unusual_filenames(self):
        self.run_stage("printf content > $'한글\\nfile with spaces.txt'", evidence="change")
        self.run_stage(":", expected=5)

    def test_tmpdir_inside_repo_does_not_create_evidence(self):
        self.env["TMPDIR"] = str(self.repo)
        self.run_stage(":", expected=5)
        self.assertEqual(list(self.repo.glob("trio-stage.*")), [])

    def test_unborn_repository(self):
        self.git("checkout", "--orphan", "unborn")
        self.git("rm", "-q", "-f", "file.txt")
        self.run_stage("echo first > first.txt; git add first.txt; git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm first", evidence="change")

    def test_no_git_requires_stdout(self):
        import shutil
        shutil.rmtree(self.repo / ".git")
        self.run_stage("echo change > file.txt", expected=5)
        self.run_stage("echo summary", evidence="stdout")

    def test_snapshot_failure_is_not_success(self):
        (self.repo / "file.txt").unlink()
        os.mkfifo(self.repo / "file.txt")
        self.run_stage("echo summary", expected=6, cli="")

    def test_capture_failure_and_native_error_precedence(self):
        (self.repo / ".harness/stage.stdout.log").mkdir()
        self.run_stage("echo summary", expected=6)
        self.run_stage("echo summary; exit 17", expected=17, cli="17")

    def test_hash_batch_preserves_quotes_and_control_characters(self):
        name = 'quote"back\\tab\tcarriage\rline\n한글'
        (self.repo / name).write_text("before")
        self.env["TRICKY_FILE"] = name
        self.run_stage('printf after > "$TRICKY_FILE"', evidence="change")
        self.run_stage(":", expected=5)

    def test_snapshot_errors_propagate_without_pipefail(self):
        (self.repo / "link").symlink_to("file.txt")
        self.run_stage(":", expected=6, cli="",
                       setup="set +o pipefail; readlink() { return 9; }")
        (self.repo / "link").unlink()
        self.run_stage("echo changed > file.txt", evidence="change", setup="set +o pipefail")

    def test_nested_snapshot_error_propagates_without_pipefail(self):
        source = Path(self.tmp.name) / "sub-source"
        subprocess.run(["git", "clone", "-q", str(self.repo), str(source)],
                       env=self.env, check=True, capture_output=True)
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(source), "vendor")
        self.run_stage(":", expected=6, cli="", setup=
                       'set +o pipefail; git() { case "$*" in *vendor*ls-files*) return 9 ;; esac; command git "$@"; }')

    def test_gitignore_excludes_new_files_not_tracked_files(self):
        (self.repo / ".git/info/exclude").write_text("ignored.txt\nfile.txt\n")
        self.run_stage("echo ignored > ignored.txt", expected=5)
        self.run_stage("echo changed > file.txt", evidence="change")

    def test_regular_files_use_batched_processes(self):
        import shutil
        for i in range(1000):
            (self.repo / f"source-{i}.txt").write_text("content")
        bins = Path(self.tmp.name) / "bin"
        bins.mkdir()
        calls = Path(self.tmp.name) / "calls"
        for name in ("git", "jq"):
            real = shutil.which(name)
            wrapper = bins / name
            wrapper.write_text(f'#!/bin/sh\nprintf "%s\\n" {name} "$*" >> "$BATCH_CALLS"\nexec {real} "$@"\n')
            wrapper.chmod(0o755)
        self.env.update(PATH=str(bins) + os.pathsep + self.env["PATH"], BATCH_CALLS=str(calls))
        self.run_stage(":", expected=5)
        lines = calls.read_text().splitlines()
        self.assertEqual(sum("hash-object" in line for line in lines), 2)
        self.assertEqual(sum("--stdin-paths" in line for line in lines), 2)
        self.assertEqual(lines.count("jq"), 3)

    def test_result_recording_without_invocation_fails_cleanly(self):
        result = subprocess.run(["bash", "-uc", '. "$1"; stage_record_result 4', "test", str(LIB)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 6)
        self.assertNotIn("unbound", result.stderr)

    def test_stage_prompt_arrives_whole_on_stdin(self):
        """#102: the planner/coder prompt is stdin (plus a newline), not one argv element."""
        prompt = "# Role: worker\nline two é\n" + "x" * 300_000
        (Path(self.tmp.name) / "prompt.txt").write_text(prompt)
        self.run_stage('cat > "$PWD/.harness/seen"; echo done', evidence="stdout",
                       setup=f'STAGE_PROMPT=$(cat {str(Path(self.tmp.name) / "prompt.txt")!r}; printf .)'
                             '; STAGE_PROMPT=${STAGE_PROMPT%.}')
        self.assertEqual((self.repo / ".harness/seen").read_text(), prompt + "\n")
        self.assertEqual(sorted(p.name for p in (self.repo / ".harness").iterdir()),
                         ["seen", "stage.log", "stage.stdout.log"])

    def test_unread_prompt_keeps_the_cli_status(self):
        """A CLI that ignores its stdin keeps its own status under the caller's pipefail."""
        setup = 'STAGE_PROMPT=$(printf "%300000s" "")'
        self.run_stage("echo answered", role="planner", evidence="stdout", setup=setup)
        self.run_stage("echo failed; exit 7", role="planner", expected=7, cli="7", setup=setup)

    def test_child_holding_stdin_does_not_hold_up_the_stage(self):
        """A `printf | cli` writer would block on a 300 KB prompt held by a leaked reader."""
        release = Path(self.tmp.name) / "release"
        self.addCleanup(release.touch)
        command = (f'( i=0; while [ ! -e {str(release)!r} ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; '
                   f'[ -e {str(release)!r} ] || : > {str(release)!r}.gave-up ) <&0 >/dev/null 2>&1 & echo answered')
        self.run_stage(command, role="planner", evidence="stdout", setup='STAGE_PROMPT=$(printf "%300000s" "")')
        self.assertFalse(Path(f"{release}.gave-up").exists(), "stage_run waited for the leaked reader")
        release.touch()

    def test_stage_prompt_is_consumed_and_never_reaches_a_later_call(self):
        script = RUN.replace("rc=0\n", "STAGE_PROMPT=first\nrc=0\n", 1) + \
            'echo "left=${STAGE_PROMPT+set}"\n' \
            'stage_run "$3" "$2" "$2/.harness/second.log" bash -c "cat > .harness/second-seen; echo ok"\n'
        result = subprocess.run(["bash", "-c", script, "test", str(LIB), str(self.repo), "planner",
                                 "cat > .harness/first-seen; echo ok"],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("left=\n", result.stdout)
        self.assertEqual((self.repo / ".harness/first-seen").read_text(), "first\n")
        self.assertEqual((self.repo / ".harness/second-seen").read_text(), "")


class NeedSectionTests(unittest.TestCase):
    """stage_need_section reads the NEED RESEARCH request a role ends with."""

    def section(self, text, heading="NEED RESEARCH"):
        with tempfile.TemporaryDirectory(prefix="need-section-") as tmp:
            answer = Path(tmp) / "answer.md"
            answer.write_bytes(text.encode())
            result = subprocess.run(["bash", "-c", '. "$1"; stage_need_section "$2" "$3"', "test",
                                     str(LIB), str(answer), heading],
                                    capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_questions_end_at_the_next_section(self):
        self.assertEqual(self.section("## Verdict\nNEEDS-FIX — x\n\n## NEED RESEARCH\n- q1\n\n- q2\n"
                                      "## NEED CONTEXT\n- `gh pr view 9`\n"), "- q1\n- q2\n")

    def test_heading_suffix_is_allowed_but_not_a_longer_word(self):
        self.assertEqual(self.section("## NEED RESEARCH (only if applicable)\n- q\n"), "- q\n")
        self.assertEqual(self.section("## NEED RESEARCHER\n- q\n"), "")

    def test_empty_markers_and_blank_sections_request_nothing(self):
        for body in ("- None.\n", "None.\n", "- none\n", "- 없음.\n", "- N/A\n", "\n\n", ""):
            with self.subTest(body=body):
                self.assertEqual(self.section("## Verdict\nSHIP — ok\n\n## NEED RESEARCH\n" + body), "")

    def test_a_marker_next_to_a_question_is_dropped(self):
        self.assertEqual(self.section("## NEED RESEARCH\n- None.\n- real question\n"), "- real question\n")

    def test_fenced_or_indented_heading_is_an_example(self):
        self.assertEqual(self.section("## What I checked\n```\n## NEED RESEARCH\n- example\n```\n"), "")
        self.assertEqual(self.section("## What I checked\n    ## NEED RESEARCH\n    - example\n"), "")

    def test_fenced_lines_inside_the_section_belong_to_the_question(self):
        self.assertEqual(self.section("## NEED RESEARCH\n- does this parse?\n```\n## not a heading\n```\n"),
                         "- does this parse?\n```\n## not a heading\n```\n")

    def test_a_fence_closes_only_on_its_own_character(self):
        # "`~~" is not three backticks, so it does not close a ``` fence.
        self.assertEqual(self.section("```\n`~~\n## NEED RESEARCH\n- example\n```\n"), "")
        # "~~~`" opens a three-tilde fence; a "~~~" line closes it.
        self.assertEqual(self.section("~~~`\nx\n~~~\n## NEED RESEARCH\n- real\n"), "- real\n")
        # A backtick opener whose info string holds a backtick is not a fence.
        self.assertEqual(self.section("``` a`b\n## NEED RESEARCH\n- real\n"), "- real\n")

    def test_kimi_envelope_is_unwrapped(self):
        text = ("• ## Verdict\n  NEEDS-FIX — x\n\n  ## NEED RESEARCH\n  - kimi question\n"
                "To resume this session: kimi -r 0123abcd-4567\n")
        self.assertEqual(self.section(text), "- kimi question\n")

    def test_crlf_and_missing_file(self):
        self.assertEqual(self.section("## NEED RESEARCH\r\n- q\r\n"), "- q\n")
        result = subprocess.run(["bash", "-c", '. "$1"; stage_need_section "" "NEED RESEARCH" </dev/null; echo rc=$?',
                                 "test", str(LIB)], input="## NEED RESEARCH\n- stdin\n",
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.stdout, "rc=0\n")


if __name__ == "__main__":
    unittest.main()
