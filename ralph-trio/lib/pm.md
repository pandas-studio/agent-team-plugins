# CLAUDE.md — ralph-trio orchestration policy

Installed by `/ralph-trio:install-pm`. ralph-trio runs an **autonomous Ralph loop**: a bash driver re-invokes `claude -p` (and, for trio, Codex + Antigravity) per iteration until the agent writes `<promise>COMPLETE</promise>` into `fix_plan.md` or a cap is hit. You set the loop up and read its results — the loop itself runs **headless**, not turn-by-turn in this session.

## When to launch a loop

Reach for a Ralph loop when a task is **large, mechanical, and checklist-shaped** (a backlog of similar fixes, a long migration, a sweep) — work that benefits from many small commit-sized iterations. Skip it for one-shot changes, anything needing live human judgement per step, or exploratory design (use `/debate-conductor` for that).

| Variant | Driver | Use when | Deps |
|---|---|---|---|
| **solo** | `ralph-solo.sh` | single-agent loop, smallest moving parts | none |
| **trio** | `ralph-trio.sh` | planner→coder→**Codex reviewer** per task, with NEED RESEARCH → Antigravity | dev-trio |
| **debate** | `ralph-debate.sh` | per-topic adversarial debate loop (text artifacts, not diffs) | debate-conductor |
| **meta** | `ralph-meta.sh` | one-shot post-run audit (shipped / revert / retry) | dev-trio |

## How to launch

1. `/ralph-trio:bootstrap` — seeds `PROMPT.md`, `BACKLOG.md`, `fix_plan.md` (refuses to overwrite).
2. Edit `PROMPT.md` (mission + completion criteria) and `BACKLOG.md` (one `- [ ]` task per line).
3. **Always cap and dry-run first:**
   ```bash
   ralph-trio.sh --max-iter 1 --dry-run --backlog BACKLOG.md      # smoke the pipeline
   ralph-trio.sh --max-iter 20 --max-runtime 4h --backlog BACKLOG.md
   ```
4. For risky/parallel work add `--worktree` (each iter runs in a throwaway worktree, fast-forward-merged only on SHIP + pre-merge validation).

## Reporting back to the user

- After a run: give the per-iter **verdict tally** (SHIP / NEEDS-FIX / DISCUSS / UNKNOWN) from the summary log, and surface anything in `fix_plan.md` marked DISCUSS or `> BLOCKER:`.
- The trio reviewer's authoritative verdict is read from Codex's `--output-last-message` file, not the streamed transcript — quote it, don't re-derive it.
- Logs live under `.ralph-trio/log/<team>/` (gitignored); typed run manifests sit beside each stage log. Link them, don't dump them.

## Don't

- **Never launch uncapped.** Always pass `--max-iter` and/or `--max-runtime`. An unbounded loop burns tokens and can churn the repo.
- Don't launch a loop from inside a subagent (`Agent` tool) — keep it in the main session so the user can watch and Ctrl-C.
- Don't hand-edit `BACKLOG.md`'s `[x]` markers mid-run; the driver owns task popping. Re-queues land at the bottom as fresh `- [ ]` lines.
- Don't paste secrets into `PROMPT.md`/`BACKLOG.md` — trio/meta route content to Codex and Antigravity (external providers).
