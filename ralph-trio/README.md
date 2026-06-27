# ralph-trio

Iterative LLM-driven coder loops, in four variants. The "Ralph Wiggum" pattern: re-feed the same prompt every iteration, let the agent re-read `PROMPT.md` + `fix_plan.md` + the repo, do one coherent unit of work, and stop only when the agent itself writes `<promise>COMPLETE</promise>` into `fix_plan.md` (or when `--max-iter` / `--max-runtime` is hit).

| Variant | Driver | When to use | Plugin deps |
| :--- | :--- | :--- | :--- |
| **solo** | `ralph-solo.sh` (bash) **or** in-session Stop hook | Single-agent loop. Smallest moving parts. | none |
| **trio** | `ralph-trio.sh` (bash) | 3-stage planner→coder→reviewer per backlog task, with optional NEED RESEARCH branch. | [`dev-trio`](../dev-trio) |
| **debate** | `ralph-debate.sh` (bash) | Outer loop wrapping the debate-conductor over per-topic backlog. Produces text artifacts, not code diffs. | [`debate-conductor`](../debate-conductor) |
| **meta** | `ralph-meta.sh` (bash) | One-shot post-run audit; categorises ralph commits into shipped / revert / retry-with-context. | [`dev-trio`](../dev-trio) |

## Prerequisites

- `bash` (≥ 4 recommended; the scripts work with bash 3.2 on macOS too)
- `git`
- `jq` 1.6+ — required for RFC 0004 run manifests
- `python3` — used by the Stop-hook JSON emitter
- `claude` (Claude Code CLI) — for `ralph-solo.sh` / `ralph-trio.sh` planner & coder stages
- Optional: `tmux` (only for `dashboard.sh`)

Override the model CLI per stage:

```bash
CLAUDE_CLI=/path/to/claude      # used by every stage by default
PLANNER_CLI=...                 # overrides CLAUDE_CLI for the planner stage
CODER_CLI=...                   # overrides for the coder stage
WORKER_CLI=...                  # overrides for solo's single stage
```

## Install

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install ralph-trio@pandas-studio

# For trio + meta (Codex reviewer + Antigravity researcher):
/plugin install dev-trio@pandas-studio

# For debate (Generator vs Critic debate runner):
/plugin install debate-conductor@pandas-studio
```

Local development:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git
claude --plugin-dir ./agent-team-plugins/ralph-trio
```

## Use

### Solo (single-agent loop)

```bash
/ralph-trio:bootstrap                  # seed PROMPT.md, BACKLOG.md, fix_plan.md from templates
# edit PROMPT.md — fill in mission + completion criteria
ralph-solo.sh --max-iter 50 --max-runtime 6h
```

Each iteration runs `claude -p "$(cat PROMPT.md)"` in your cwd. The loop exits when `fix_plan.md` contains `<promise>COMPLETE</promise>`, or `--max-iter` / `--max-runtime` is reached, or you Ctrl-C.

**In-session driver** (Stop-hook, solo only):

```
/ralph-trio:install-stop-hook
```

Then, in a fresh shell:

```bash
export RALPH_PROMPT=$PWD/PROMPT.md
export RALPH_FIX_PLAN=$PWD/fix_plan.md
export RALPH_MAX_ITER=50
export RALPH_VARIANT=solo
claude
```

Give Claude any opening message. The hook re-injects `PROMPT.md` every Stop event until the completion marker appears or `RALPH_MAX_ITER` is hit.

### Trio (3-stage with Codex review)

Needs `dev-trio` plugin installed.

```bash
# Add tasks to BACKLOG.md (one per line, GitHub task-list syntax: "- [ ] task description")
ralph-trio.sh --max-iter 20 --backlog BACKLOG.md
```

Per backlog task:

1. **Stage 1 — Planner** (`claude -p` with `lib/roles/planner.md`)
2. **Stage 2 — Coder** (`claude -p` with `lib/roles/worker.md` + plan)
3. **Stage 3 — Reviewer** (`ask-codex.sh` against HEAD diff) → verdict: SHIP / NEEDS-FIX / DISCUSS
4. If codex emits a `## NEED RESEARCH` block: invoke `ask-agy.sh` (Antigravity), re-run Stage 2 with research context, re-review.

Verdict dispatch:

| Verdict | Action |
| :--- | :--- |
| `SHIP` | Log to fix_plan.md, continue. |
| `NEEDS-FIX` | Re-queue the task to BACKLOG.md with the review log path. |
| `DISCUSS` | Log to fix_plan.md and continue (human attention). |
| `UNKNOWN` | Log to fix_plan.md (codex output unparseable). |

Useful flags: `--worktree` (run each iter in a throwaway git worktree, fast-forward merge on SHIP), `--autoship` (skip review — useful for trivial mechanical refactors), `--dry-run` (no model calls; manifest emission only), `--no-research` (skip the NEED RESEARCH branch).

### Debate (per-topic debate outer loop)

Needs `debate-conductor` plugin installed.

```bash
# BACKLOG.md lines = debate topics
ralph-debate.sh --max-iter 5 --backlog BACKLOG.md --rounds 3
```

Per topic: runs `debate.sh -n $ROUNDS "$topic"`, parses the last critic round's verdict (`STRENGTHEN` / `RECONSIDER` / `OVERTURN`), logs to `fix_plan.md`, and (on `RECONSIDER`) re-queues to BACKLOG.

Produces *text artifacts*, not code diffs. The debate transcripts live under `$PWD/.debate-conductor/log/<team>/debate-<TS>/`.

### Meta (post-run audit)

Needs `dev-trio` plugin installed.

```bash
# After an overnight ralph-solo run:
ralph-meta.sh --since-latest-run

# Or with explicit cutoff:
ralph-meta.sh --since "2026-05-10 22:00" --variant solo

# To auto-append "retry-with-context" tasks back into BACKLOG.md:
ralph-meta.sh --since "2 hours ago" --rewrite-backlog BACKLOG.md
```

Inspects ralph commits + log manifests since the cutoff, calls `ask-codex.sh` once with a focused audit brief, and writes a categorised audit Markdown to `$PWD/.ralph-trio/log/<team>/ralph-meta-<TS>.md`.

## Workspace artifacts

Logs and state both land in `$PWD/.ralph-trio/` (override with `RALPH_TRIO_WORKSPACE=/path/elsewhere`). Add this to your `.gitignore`:

```
.ralph-trio/
```

Structure (per team):

```
$PWD/.ralph-trio/
├── log/<team>/
│   ├── ralph-solo-<TS>.log                        per-run summary
│   ├── ralph-solo-<TS>-iter-N.log                 per-iter claude output
│   ├── ralph-solo-<TS>-iter-N.manifest.json       RFC 0004 typed manifest
│   ├── ralph-trio-<TS>{,-iter-N-{plan,code,review,research}.log}
│   ├── ralph-trio-<TS>-iter-N-{plan,code,review,research}.manifest.json
│   ├── ralph-debate-<TS>.log
│   ├── ralph-meta-<TS>.{log,md,codex.log}
│   ├── latest-ralph-{solo,trio,debate}.log        symlinks to most-recent
│   └── latest-ralph.log                           symlink to most-recent any-variant
└── state/<team>/
    ├── iter                                       Stop-hook iteration counter
    └── prompt.sha256                              Stop-hook tamper detection
```

Team namespace priority: `$AGENT_TEAM` env var → tmux `@team-name` window option → tmux session name → `default`.

## Variant-internal helpers

`dashboard.sh [solo|trio|debate|any]` — coloured `tail -F` against the latest-* symlink. Run from any pane while a ralph run is going.

`ralph-trio-doctor.sh` — env probe + cross-plugin dependency check + stub-CLI smoke. Exits 0 on healthy install; FAILED with detail on broken layout or missing required tools; WARN (still exits 0) on missing optional cross-plugin deps. Run any time:

```bash
ralph-trio-doctor.sh
```

## Architecture

```
ralph-trio/
├── bin/                          # on PATH while the plugin is active
│   ├── ralph-solo.sh             # single-agent loop
│   ├── ralph-trio.sh             # 3-stage planner+coder+reviewer
│   ├── ralph-debate.sh           # outer loop over debate-conductor
│   ├── ralph-meta.sh             # one-shot post-run audit
│   ├── dashboard.sh              # tail-F wrapper with coloured header
│   ├── stop-hook.sh              # Claude Code Stop hook (in-session solo driver)
│   └── ralph-trio-doctor.sh      # env probe + stub smoke
├── lib/                          # internal (sourced, not on PATH)
│   ├── common.sh                 # detect_team, init_log_dir, worktree helpers, …
│   ├── manifest.sh               # RFC 0004 run manifest helper (vendored from core/lib/)
│   └── roles/
│       ├── planner.md            # trio Stage 1 role prompt
│       └── worker.md             # trio Stage 2 + solo role prompt
├── prompts/                      # workspace seed templates (copied by bootstrap skill)
│   ├── PROMPT.md.template
│   ├── BACKLOG.md.template
│   └── fix_plan.md.template
├── templates/
│   └── launchd/com.user.ralph.plist.template     # overnight scheduling on macOS
├── hooks/
│   └── settings.snippet.json     # Stop-hook registration (used by install-stop-hook skill)
├── skills/
│   ├── bootstrap/SKILL.md        # /ralph-trio:bootstrap
│   └── install-stop-hook/SKILL.md  # /ralph-trio:install-stop-hook
└── .claude-plugin/plugin.json
```

## Security model

Ralph runs untrusted LLM output in a loop. Defenses:

- **Trust boundary in role prompts.** Untrusted data (task text, plan, prior fix_plan excerpts, research, prompt context) is always wrapped in named XML tags (`<task>`, `<plan>`, `<fix_plan_md>`, `<research>`, `<prompt_md>`). The role prompts (`lib/roles/{planner,worker}.md`) instruct the model to treat tag contents as data, not instructions.
- **Literal-string tag stripping.** Before injection, the driver strips literal closing tags from untrusted strings (`</task>` → `[STRIPPED-CLOSING-TAG]`) so untrusted content cannot escape its boundary.
- **Team-name sanitization.** `$AGENT_TEAM` / tmux window names flow into filesystem paths. We strip everything except `[a-zA-Z0-9_-]` and warn loudly when sanitization changes the value.
- **Pre-merge validation** (worktree mode): `git diff --check` (whitespace, conflict markers) + secret-pattern scan on added lines + diff-size cap (default 10,000 lines). Failure → discard the iteration's branch instead of merging.
- **Stop-hook tamper detection.** First invocation records SHA-256 of `PROMPT.md`; subsequent invocations compare. On mismatch, hook allows the stop and resets the iter counter so the operator can consciously restart.
- **Fail-safe defaults.** Worktree without `--test-cmd` discards every iteration. Hook setup errors allow the stop rather than block forever.

## License

MIT
