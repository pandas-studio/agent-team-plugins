# spec-trio

Spec-anchored ralph-trio: an external `spec.md` is the load-bearing contract that gates the planner / coder / reviewer pipeline. Each agent sees the same frozen spec snapshot in its prompt; the driver enforces an allowlist scope check on the planner's `<allowed-paths>` and (optionally) a §5.N coverage classifier against commits made during the run.

Use spec-trio when you want **user intent to live outside the model** — the spec is the thing you edit when the model goes off-mission, not a re-prompt.

## When to use spec-trio vs ralph-trio

- **ralph-trio**: BACKLOG.md is your source of truth, completion is "agent writes `<promise>COMPLETE</promise>`". Good for open-ended exploration, refactors, "keep going until done".
- **spec-trio**: `spec.md` is your source of truth; BACKLOG entries cite `§N.M` sections of it. Reviewer rejects diffs that drift from the spec contract or touch §4 Constraints. Good for shipping a defined feature with verifiable test criteria — when you can write down what success looks like before the loop starts.

## Prerequisites

- `bash` (works with macOS 3.2; ≥ 4 recommended)
- `git`
- `jq` 1.6+ — required for RFC 0004 run manifests
- `claude` (Claude Code CLI) — for planner & coder stages
- **`dev-trio` plugin** (provides `ask-codex.sh` reviewer + `ask-agy.sh` Antigravity researcher on PATH)

Override the model CLI per stage:

```bash
CLAUDE_CLI=/path/to/claude       # default for every claude-driven stage
PLANNER_CLI=...                  # override planner only
CODER_CLI=...                    # override coder only
```

`ask-codex.sh` also honors `CODEX_CLI` / `REVIEWER_CLI` (set inside dev-trio) for stubbing the reviewer.

### Model configuration

The reviewer (`ask-codex.sh`) and researcher (`ask-agy.sh`) come from the **dev-trio** plugin, which resolves each role through a shared, configurable model registry (`agent-team-models`). spec-trio inherits that resolution unchanged — point the reviewer or researcher at a different CLI globally with `agent-team-models set-role`, or per-run with dev-trio's `*_MODEL` env vars. See dev-trio's README for the registry reference.

## Install

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install spec-trio@pandas-studio
/plugin install dev-trio@pandas-studio        # required (reviewer + researcher)
```

The reviewer dispatcher uses `DEV_TRIO_REVIEW_PROFILE=spec` with dev-trio 0.4.3 or newer so `OUT-OF-SCOPE` remains an explicit fourth verdict. Update both plugins together. Malformed reviews return a nonzero dispatcher exit code and are handled as UNKNOWN; nested reviewer dispatches do not overwrite the parent verdict.

Local development:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git
claude --plugin-dir ./agent-team-plugins/spec-trio
```

## Quick start

```bash
/spec-trio:bootstrap                          # seeds spec.md, BACKLOG.md from templates
# edit spec.md — fill in §1 Goals, §2 Interfaces, §3 Behavior, §4 Constraints, §5 Test criteria, §6 Non-goals
# edit BACKLOG.md — add `- [ ] (§3.1) ...` task lines
spec-trio.sh --spec spec.md --backlog BACKLOG.md --max-iter 10 --test-cmd 'pytest -q'
```

Real runs require `--test-cmd 'COMMAND'`, including `--autoship`. Choose a
command that proves the task's behavior; the driver runs it with `bash -c` in
the active workspace (the iteration worktree when enabled). A missing or blank
command exits 2 before creating files or calling models. `--dry-run` needs no
test command and does not modify the backlog, even with `--coverage-requeue`.

Per backlog task, each iteration runs:

1. Select the first unchecked task without marking it complete. Capture one
   spec snapshot for the run; plan, code, review and coverage all use it.
2. Planner declares `<allowed-paths>`. Missing paths under strict scope block
   the run. Planner `## NEED RESEARCH` triggers research before implementation.
3. Coder implements the task. A failed coder cannot proceed to review or SHIP.
4. Check the contract and allowed paths, execute the test command, then check
   scope again. Record the command, test log and exit code in the coder manifest.
5. Reviewer returns its invocation-specific result. Research-informed retries
   repeat the coder, scope and test gates before re-review.
6. Mark the selected row `[x]` only after success and, in worktree mode, successful
   validation and merge. An agent's completion marker cannot skip pending rows.

Verdict dispatch:

| Result | Action |
| :--- | :--- |
| `SHIP` | Complete after gates and any required merge succeed. |
| `NEEDS-FIX`, planner/coder/test failure | Keep the same row pending; retry with failure-log context within the run caps. |
| `OUT-OF-SCOPE`, `DISCUSS`, `UNKNOWN` | Stop immediately, retain the pending task and preserve an active worktree for inspection. |
| Changed/deleted spec or changed backlog | Stop immediately; do not restore user files or silently adopt a new contract. |

The source spec, frozen snapshot and backlog are checked before and after each
external stage and before completion. A worktree's spec/backlog copies are also
protected against changes from their starting state. This detects changes at
stage boundaries; it is not an OS-level write sandbox.

### Exit status and migration

Existing real-run commands must add `--test-cmd`. Previous `[x]` entries remain
unchanged; inspect and reopen any historical tasks you want verified again.

| Exit | Meaning |
| :--- | :--- |
| 0 | All queued tasks completed, or successful dry-run (explicitly labeled). |
| 1 | Execution, persistence, coverage execution or worktree operation failed. |
| 2 | Invalid arguments or missing prerequisites. |
| 3 | Pending tasks remain after a cap, or coverage requeued work. |
| 4 | Human attention required: contract/backlog change or blocking review. |
| 130 | Interrupted; the current uncompleted task remains pending. |

The final summary records `status`, `completed`, `pending`, `reason` and `exit`.
A successful merge followed by cleanup failure counts the task completed but
exits 1; a failed merge leaves the task pending. A coverage gap alone remains
advisory, but `--coverage-requeue` creates pending work and therefore exits 3.

Useful flags:

- `--strict-scope` (default ON) — enforce both gates. `--no-strict-scope` downgrades both to warnings.
- `--coverage-check` — after the run, classify each `### §5.N` test-criterion subsection against commits made during the run (`COVERED` / `PARTIAL` / `NOT-COVERED`).
- `--coverage-requeue` — additionally append each `NOT-COVERED` criterion as a new BACKLOG task.
- `--worktree` — run each iter in a throwaway git worktree; fast-forward merge after tests and SHIP; discard retryable failed attempts and preserve blocked worktrees.
- `--autoship` — skip the reviewer stage (still gates on contract, scope and tests). Useful for mechanical refactors with a tight allowlist.
- `--dry-run` — no model calls; still emits manifests. **Bypasses scope and test execution; preserves the backlog.**
- `--no-research` — skip both NEED RESEARCH branches (planner Stage 1.5 + reviewer Stage 3.5; no `ask-agy.sh` dep).

## Workspace artifacts

Logs land in `$PWD/.spec-trio/log/<team>/` (override with `SPEC_TRIO_WORKSPACE=/path/elsewhere`). Add `.spec-trio/` to `.gitignore`.

```
$PWD/.spec-trio/
└── log/<team>/
    ├── spec-trio-<TS>.log                                per-run summary
    ├── spec-trio-<TS>-iter-N-{plan,code,review,research}.log
    ├── spec-trio-<TS>-iter-N-{plan,code,review,research}.manifest.json
    ├── spec-trio-<TS>-iter-N-scope.log                   when a gate fires
    ├── spec-trio-<TS>-coverage.log                       --coverage-check output
    └── latest-spec-trio.log                              symlink to most-recent summary
```

Team namespace priority: `$AGENT_TEAM` env > tmux `@team-name` window option > tmux session name > `default`.

## Standalone coverage classifier

```bash
spec-coverage.sh --spec spec.md --since-ref HEAD~10
# or, for legacy audits, omit --since-ref to scan all reachable commits:
spec-coverage.sh --spec spec.md
# with reviewer verdict rollup (per-row [reviewer: X SHIP, Y NEEDS-FIX, …]):
spec-coverage.sh --spec spec.md --since-ref HEAD~10 \
                 --manifest-history $PWD/.spec-trio/log/<team>
```

**This is implementation-trace classification, not proof of passing tests.** Test
commands and their outcomes are recorded separately in coder manifests.

Classification rules:

- **COVERED**: at least one commit message in the range contains the exact `§5.N` identifier (so `§5.10` or `§5.1.2` cannot cover `§5.1`) (worker.md commit convention: `git commit -m "spec §N.M: ..."`).
- **PARTIAL**: no §-citation, but a distinctive keyword from the criterion heading appears in some commit's message or diff (catches "did the work, forgot to cite"). Skipped with `--no-partial`.
- **NOT-COVERED**: neither.

`--requeue BACKLOG.md` appends NOT-COVERED criteria as `- [ ] (spec coverage gap §5.N) <name>` for a follow-up run.

## When to reach for debate (spec amendment, not clarification)

Repeated `OUT-OF-SCOPE` verdicts or coverage gaps that won't close usually signal **the spec itself is wrong** — not the implementation. When the spec needs *amendment* (a §3 behavior contradicts §4 constraints; a §5 test criterion is unreachable without adding a non-goal), don't hand-edit `spec.md` in isolation. Frame the amendment as a stance and run the debate-conductor plugin against it:

```bash
debate.sh -n 3 \
  "spec.md §3.2 'idempotent retry' vs §4.1 'no shared state' — A: drop §4.1 / B: relax §3.2 to at-least-once" \
  spec.md
```

The transcript becomes the rationale for the spec edit. Re-run `spec-trio.sh` after committing the amended spec — coverage / scope verdicts now compare against an internally-consistent contract instead of diverging from a broken one.

## Variant-internal helpers

`spec-trio-doctor.sh` — env probe + cross-plugin dep check + stub smoke. Exits 0 on healthy install; FAILED on broken layout or missing required tools; WARN (still exits 0) on missing dev-trio (since `--dry-run` / `--autoship` can run without it).

```bash
spec-trio-doctor.sh
```

`tests/smoke-pr5.sh` — comprehensive manifest/scope smoke (RFC 0004 fixtures): both scope gates, dispatch states, manifest schema invariants, and the coverage `--manifest-history` rollup with anchored-regex behavior (§5.3 doesn't match §5.30).

```bash
bash $PLUGIN_ROOT/tests/smoke-pr5.sh
```

The smoke auto-discovers a sibling `dev-trio` plugin checkout and prepends its `bin/` to PATH; you don't need dev-trio installed if you're in a sibling-checkout layout.

## Architecture

```
spec-trio/
├── bin/                          # on PATH while the plugin is active
│   ├── spec-trio.sh              # main driver (3-stage + scope gates + coverage)
│   ├── spec-coverage.sh          # standalone §5.N coverage classifier
│   └── spec-trio-doctor.sh       # env probe + stub smoke
├── lib/                          # internal (sourced, not on PATH)
│   ├── common.sh                 # workspace / team / log / worktree / promise — vendored from ralph-trio
│   ├── manifest.sh               # RFC 0004 run manifest helper — vendored from ralph-trio
│   ├── verification.sh           # frozen contract, test gate and task lifecycle
│   ├── spec-helpers.sh           # parse_allowed_paths, check_scope, parse_test_criteria, criterion_keywords
│   └── roles/
│       ├── planner.md            # Stage 1 spec-aware planner (emits <allowed-paths>)
│       ├── worker.md             # Stage 2 spec-aware coder (respects allowlist, cites §N in commits)
│       └── reviewer.md           # Stage 3 spec-aware reviewer (adds OUT-OF-SCOPE verdict tier)
├── prompts/                      # workspace seed templates (copied by bootstrap skill)
│   ├── spec.md.template          # §1–§6 spec scaffold
│   ├── BACKLOG.md.template       # task-list with §-citation examples
│   └── fix_plan.md.template      # iteration log; driver owns completion
├── tests/
│   └── smoke-pr5.sh              # manifest/scope smoke (manifests + gates + coverage rollup)
├── skills/
│   └── bootstrap/SKILL.md        # /spec-trio:bootstrap
└── .claude-plugin/plugin.json
```

## Security model

spec-trio runs untrusted LLM output in a loop against a spec contract. Defenses (mostly inherited from ralph-trio's playbook, plus spec-specific):

- **Trust boundary in role prompts.** Untrusted data (task text, spec body, plan, prior fix_plan excerpts, research, prompt context) is always wrapped in named XML tags (`<task>`, `<spec>`, `<plan>`, `<fix_plan_md>`, `<research>`, `<prompt_md>`). The role prompts instruct the model to treat tag contents as data, not instructions.
- **Literal-string tag stripping.** Before injection, the driver strips literal closing tags from untrusted strings (`</spec>` → `[STRIPPED-CLOSING-TAG]`) so untrusted content cannot escape its boundary.
- **Scope gates as hard contract enforcement.** The planner's `<allowed-paths>` block becomes a deterministic filter — gate 1 rejects plans without one (under strict-scope), gate 2 rejects coder output that touches anything outside it. §4 Constraints get an additional absolute check in the reviewer prompt.
- **Team-name validation.** `$AGENT_TEAM` / tmux window names flow into filesystem paths and branch names. An explicit `$AGENT_TEAM` must match `[A-Za-z0-9][A-Za-z0-9._-]*` (max 48 chars) or the run exits with an error; a tmux-derived name is sanitized to that set with a loud warning.
- **Pre-merge validation** (worktree mode): `git diff --check` (whitespace, conflict markers) + secret-pattern scan on added lines + diff-size cap (default 10,000 lines). Failure → discard the iteration's branch instead of merging.
- **OUT-OF-SCOPE stops for human attention**, without marking the task done. A bad allowlist that loops the reviewer would burn iterations; the driver routes it to fix_plan with `human attention — spec violation` and lets the operator fix the spec or re-scope the task.

## License

MIT
