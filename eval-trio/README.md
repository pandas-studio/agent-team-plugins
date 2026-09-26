# Eval Trio (EP E)

Eval Trio evaluates a **submitted result** against a task and criteria. It
freezes local input, runs fixed checks, asks a Challenger for counterexamples,
then asks an independent Judge. It reports evidence; it does not edit the
submission or merge anything. Python 3.9+, Git (for Git cases), jq and an
authenticated dev-trio reviewer are needed for full runs. Checks-only needs
neither dev-trio nor a model login.

## Run

From the repository root:

```bash
./eval-trio/bin/eval-trio run --case case.json --output-dir /private/tmp/eval-run-001 --allow-execution
./eval-trio/bin/eval-trio run --case case.json --output-dir /private/tmp/eval-checks-001 --checks-only --allow-execution
```

`--output-dir` must not exist; a new 0700 directory is created. No run
overwrites an earlier report. `--allow-execution` is an explicit acknowledgement
that fixed checks and model tools can execute submitted code with your user
privileges. Workspaces are copies, **not OS sandboxes**. They do not block
network access or reads and writes elsewhere on the host. Use only inputs you
trust to run locally. Checks get only PATH, LANG, and scratch HOME/TMPDIR; model
wrappers retain their own authentication environment. Check timeouts kill the
process group. For stronger isolation, run Eval Trio in a separate VM/container.

The `DEV_TRIO_BIN` environment variable can point at dev-trio's `bin/`
directory. Otherwise the CLI looks for a sibling checkout, PATH, then an
enabled `dev-trio@pandas-studio` install. `DEV_TRIO_PM_HOST=codex|claude`
selects the Judge's default model (`claude|codex`) and defaults to `claude`;
the Challenger defaults to
`agy`. `EVAL_TRIO_CHALLENGER_MODEL` and `EVAL_TRIO_JUDGE_MODEL` can override
the models, but must name different models. Full runs fail with `ERROR` when
authentication or a wrapper result is unavailable.

## Case format

Task, criteria, and check file sources are regular files beneath the case
directory; symlinks and path traversal are rejected. Submission paths may be
absolute or relative to that directory. Directory submissions omit `.git` and
reject symlinks and special files. Git submissions read committed objects at
the resolved SHAs, require base to be an ancestor of head, and reject
symlinks, gitlinks, and special modes. Dirty working-tree data is excluded;
the Git source recheck compares the selected commit refs, not unrelated
working-tree files.

```json
{
  "schema_version": 1,
  "preset": "bug-fix",
  "task": "task.md",
  "criteria": "criteria.md",
  "submission": {"kind": "git", "repo": "../project", "base": "main", "head": "fix"},
  "checks": [
    {
      "id": "reproducer",
      "baseline": true,
      "argv": ["python3", "-m", "unittest", "tests.test_reproducer"],
      "timeout_seconds": 30,
      "expected_base": {"rc": [1], "stderr_regex": "AssertionError"},
      "files": [{"source": "reproducer.py", "target": "tests/test_reproducer.py"}]
    },
    {"id": "regression", "argv": ["python3", "-m", "unittest", "discover", "-s", "tests"]}
  ]
}
```

`preset` is `generic` or `bug-fix`. For a generic case, `submission` can be a
`directory` or `file` with `path`, or a Git range. Checks run against the head
copy and must exit zero. For `bug-fix`, at least one `baseline: true` check
runs the **same argv and independent check files** on base and head. Base must
exit with one of the nonzero `expected_base.rc` values and match any optional
`stdout_regex`/`stderr_regex`; head must exit zero. Check IDs must be unique,
and all check definitions and independent files are validated before any check
runs. Check files cannot replace
submission files. A missing test on base therefore cannot count as a valid
failure. Timeouts, signal deaths, spawn errors and output-limit events are
`ERROR`, never an expected base failure. Output is capped at 64 KiB combined;
an over-cap result is `ERROR`, so a pattern cannot be silently missed. Checks
run once; non-determinism is not retried or hidden.

## Decision contract

`report.json` schema version 1 is authoritative; `report.md` is a summary.
The public schemas are in `schema/case.schema.json` and
`schema/report.schema.json`.
`mode` is `full`, `checks-only`, or `review-only` (no fixed checks). The final
`status` and process exit code are independent of the mode:

| Precedence | Condition | Status | Exit |
| --- | --- | --- | ---: |
| 1 | Invalid input, infrastructure/model failure, missing or malformed exact review result, timeout, signal death, or output cap | `ERROR` | 3 |
| 2 | Head check nonzero, base failure signal mismatch, Judge `NEEDS-FIX`, or Judge Blocker/Major finding | `FAIL` | 1 |
| 3 | Challenger verdict other than `SHIP` or any finding, Judge `DISCUSS`/Minor finding, checks-only success, or no fixed checks | `HOLD` | 2 |
| 4 | All fixed checks pass, Challenger `SHIP` with empty findings, Judge `SHIP` with no findings | `PASS` | 0 |

An open Challenger finding always blocks PASS in v1, even when the Judge says
SHIP. `--checks-only` success is HOLD because it has no independent model
review. A review-only result is HOLD because it has no fixed checks; the Judge
verdict remains in `models.judge.result`. Valid `SHIP`, `NEEDS-FIX`, and
`DISCUSS` come from the exact dev-trio `.review.json`. `parse-failed`,
`invocation-failed`, `permission-denied`, a missing receipt, or a wrapper
exit/result mismatch produce ERROR. No Markdown or `latest` link determines a
status. The per-invocation receipt binds the result path; its hash is recorded.

The Challenger uses a separate dev-trio `ask-reviewer.sh` invocation with an
adversarial role prompt and the `agy` model by default. This gives it the same
structured `.review.json` contract as the Judge. Both receive task, criteria,
and frozen check evidence in the run's evidence directory; the Judge also sees
the Challenger's exact result. These inputs are untrusted prompt data.
The directory includes `submission/`, `checks/<check-index>/` copies of the
independent check files, and `base/` for Git cases. `checks.json` names each
copied file. Scratch HOME and TMPDIR for each check live outside its copied
submission workspace. Reviewer Git discovery is bounded at the run directory
parent so an output directory inside a repository does not point the reviewer
at the live source tree.
The evidence directory is fixed before review, not protected from a model that
has host file access. The report records evidence digests for audit, and the
submission is never intentionally modified.

`report.json` is published last with `complete: true`. It includes input and
workspace hashes, check commands and bounded outputs, model result paths and
hashes, final reason, and exit code. On interruption or evaluation error it
records `ERROR` where possible. Test output and model logs are private under
the run directory; anyone with access to that directory can read them.
