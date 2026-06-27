# spec-trio

Spec-anchored ralph-trio: an external `spec.md` is the load-bearing contract that gates the planner / coder / reviewer pipeline. Each agent sees the spec body in its prompt; the driver enforces an allowlist scope check on the planner's `<allowed-paths>` and (optionally) a §5.N coverage classifier against commits made during the run.

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
spec-trio.sh --spec spec.md --backlog BACKLOG.md --max-iter 10
```

Per backlog task, each iteration runs:

1. **Stage 1 — Planner** (`claude -p` with `lib/roles/planner.md` + `<spec>` body). Plan must include an `<allowed-paths>` block declaring every file/dir the coder may touch.
2. **Scope gate 1** — if `<allowed-paths>` is missing or empty under `--strict-scope` (default), the iteration short-circuits to `OUT-OF-SCOPE` (no coder, no reviewer).
3. **Stage 1.5 — Pre-coding research** — if the plan emits `## NEED RESEARCH`, `ask-agy.sh` (Antigravity) answers it **before** coding and the answer is grafted into the first coder prompt. Fires even under `--autoship`; skipped with `--no-research`.
4. **Stage 2 — Coder** (`claude -p` with `lib/roles/worker.md` + `<spec>` + plan + any pre-coding research).
5. **Scope gate 2** — every uncommitted/committed/untracked path that the coder produced is compared against the allowlist. If any path is outside, the iteration short-circuits to `OUT-OF-SCOPE` (no reviewer).
6. **Stage 3 — Reviewer** (`ask-codex.sh --with-spec spec.md` against HEAD diff) → verdict: `SHIP / NEEDS-FIX / DISCUSS / OUT-OF-SCOPE`. The verdict is read from codex's `--output-last-message` file (`latest-codex.final.md`), not the streamed transcript, so it survives worktree teardown and stdout buffering.
7. If codex emits `## NEED RESEARCH`: invoke `ask-agy.sh`, re-run Stage 2 with research context (stacked above any pre-coding research), re-review.

Verdict dispatch:

| Verdict | Action |
| :--- | :--- |
| `SHIP` | Log to fix_plan.md, continue. |
| `NEEDS-FIX` | Re-queue the task to BACKLOG.md with the review log path. |
| `OUT-OF-SCOPE` | Log to fix_plan.md as `human attention — spec violation`. **Not re-queued** — retrying with the same bad allowlist would loop. |
| `DISCUSS` | Log to fix_plan.md (human attention). |
| `UNKNOWN` | Log to fix_plan.md (codex output unparseable). |

Useful flags:

- `--strict-scope` (default ON) — enforce both gates. `--no-strict-scope` downgrades both to warnings.
- `--coverage-check` — after the run, classify each `### §5.N` test-criterion subsection against commits made during the run (`COVERED` / `PARTIAL` / `NOT-COVERED`).
- `--coverage-requeue` — additionally append each `NOT-COVERED` criterion as a new BACKLOG task.
- `--worktree` — run each iter in a throwaway git worktree; fast-forward merge on SHIP, discard otherwise.
- `--autoship` — skip the reviewer stage (still gates on scope). Useful for mechanical refactors with a tight allowlist.
- `--dry-run` — no model calls; still emits manifests. **Bypasses both scope gates.**
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

Classification rules:

- **COVERED**: at least one commit message in the range contains the literal `§5.N` (worker.md commit convention: `git commit -m "spec §N.M: ..."`).
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

`tests/smoke-pr5.sh` — comprehensive 134-assertion smoke (RFC 0004 PR 5 fixtures): both scope gates, all six dispatch states, manifest schema invariants, and the coverage `--manifest-history` rollup with anchored-regex behavior (§5.3 doesn't match §5.30).

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
│   ├── spec-helpers.sh           # parse_allowed_paths, check_scope, parse_test_criteria, criterion_keywords
│   └── roles/
│       ├── planner.md            # Stage 1 spec-aware planner (emits <allowed-paths>)
│       ├── worker.md             # Stage 2 spec-aware coder (respects allowlist, cites §N in commits)
│       └── reviewer.md           # Stage 3 spec-aware reviewer (adds OUT-OF-SCOPE verdict tier)
├── prompts/                      # workspace seed templates (copied by bootstrap skill)
│   ├── spec.md.template          # §1–§6 spec scaffold
│   ├── BACKLOG.md.template       # task-list with §-citation examples
│   └── fix_plan.md.template      # iteration log + completion marker
├── tests/
│   └── smoke-pr5.sh              # 134-assert smoke (manifests + gates + coverage rollup)
├── skills/
│   └── bootstrap/SKILL.md        # /spec-trio:bootstrap
└── .claude-plugin/plugin.json
```

## Security model

spec-trio runs untrusted LLM output in a loop against a spec contract. Defenses (mostly inherited from ralph-trio's playbook, plus spec-specific):

- **Trust boundary in role prompts.** Untrusted data (task text, spec body, plan, prior fix_plan excerpts, research, prompt context) is always wrapped in named XML tags (`<task>`, `<spec>`, `<plan>`, `<fix_plan_md>`, `<research>`, `<prompt_md>`). The role prompts instruct the model to treat tag contents as data, not instructions.
- **Literal-string tag stripping.** Before injection, the driver strips literal closing tags from untrusted strings (`</spec>` → `[STRIPPED-CLOSING-TAG]`) so untrusted content cannot escape its boundary.
- **Scope gates as hard contract enforcement.** The planner's `<allowed-paths>` block becomes a deterministic filter — gate 1 rejects plans without one (under strict-scope), gate 2 rejects coder output that touches anything outside it. §4 Constraints get an additional absolute check in the reviewer prompt.
- **Team-name sanitization.** `$AGENT_TEAM` / tmux window names flow into filesystem paths. We strip everything except `[a-zA-Z0-9_-]` and warn loudly when sanitization changes the value.
- **Pre-merge validation** (worktree mode): `git diff --check` (whitespace, conflict markers) + secret-pattern scan on added lines + diff-size cap (default 10,000 lines). Failure → discard the iteration's branch instead of merging.
- **OUT-OF-SCOPE routes to human attention**, not to retry. A bad allowlist that loops the reviewer would burn iterations; the driver routes it to fix_plan with `human attention — spec violation` and lets the operator fix the spec or re-scope the task.

## License

MIT
