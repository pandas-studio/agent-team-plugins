# CLAUDE.md — spec-trio orchestration policy

Installed by `/spec-trio:install-pm`. spec-trio runs an **autonomous, spec-anchored Ralph loop**: a bash driver re-invokes `claude -p` (plus a Codex reviewer and, on NEED RESEARCH, an Antigravity researcher) per iteration until the agent writes `<promise>COMPLETE</promise>` into `fix_plan.md` or a cap is hit. Every stage is gated by an **external `spec.md`** — the planner, coder, and reviewer all read it as the contract, and an allowlist + §-citation coverage check keeps the work in scope. You set the loop up and read its results — the loop runs **headless**, not turn-by-turn in this session.

## When to launch a loop

Reach for spec-trio when the work is **large, checklist-shaped, and governed by a written contract** — a backlog of tasks that each cite a clause of a spec you can pin down up front (a migration with hard constraints, a conformance pass, a refactor that must not touch certain files). The spec is the point: if you can't express the tasks as `§N` citations against a stable `spec.md`, use plain `/ralph-trio` (unanchored loop) or `/debate-conductor` (exploratory design) instead. Skip all of them for one-shot changes or anything needing live human judgement per step.

spec-trio adds three things over a bare Ralph loop:

- **Spec gating** — `spec.md` (§1 Goals … §6 Non-goals) is injected into every planner/coder/reviewer prompt as the authoritative contract.
- **Scope allowlist** — the planner declares which paths a task may touch; `--strict-scope` (default) fails the iteration if the coder strays, and the reviewer can return **OUT-OF-SCOPE**.
- **§-citation coverage** — `--coverage-check` classifies each `### §5.N` test criterion against the commits a run produced; `--coverage-requeue` appends NOT-COVERED criteria as fresh backlog tasks.

## How to launch

1. `/spec-trio:bootstrap` — seeds `spec.md`, `BACKLOG.md`, `fix_plan.md` (refuses to overwrite).
2. Fill in `spec.md` (§1–§6 — keep the numbered headings stable; §-IDs are long-lived citation handles) and `BACKLOG.md` (one `- [ ]` task per line, each citing a `§N`). If a task can't be expressed within the spec, amend the spec, not the task.
3. **Always cap and dry-run first:**
   ```bash
   spec-trio.sh --spec spec.md --backlog BACKLOG.md --max-iter 1 --dry-run   # smoke the pipeline
   spec-trio.sh --spec spec.md --backlog BACKLOG.md --max-iter 20 --max-runtime 4h --coverage-check
   ```
4. For risky/parallel work add `--worktree` (each iter runs in a throwaway worktree, fast-forward-merged only on SHIP + pre-merge validation; uncommitted coder edits are auto-committed at SHIP so they survive the merge).

## Reporting back to the user

- After a run: give the per-iter **verdict tally** (SHIP / NEEDS-FIX / DISCUSS / OUT-OF-SCOPE / UNKNOWN) from the summary log, and surface anything in `fix_plan.md` marked DISCUSS or `> BLOCKER:`.
- With `--coverage-check`, report the **§-coverage table** (COVERED / NOT-COVERED per `§5.N`) — that's the spec-conformance signal, distinct from the per-task verdict.
- The reviewer's authoritative verdict is read from Codex's `--output-last-message` file (`latest-codex.final.md`), **not** the streamed transcript — quote it, don't re-derive it.
- Logs live under `.spec-trio/log/<team>/` (gitignored); typed run manifests sit beside each stage log. Link them, don't dump them.

## Don't

- **Never launch uncapped.** Always pass `--max-iter` and/or `--max-runtime`. An unbounded loop burns tokens and can churn the repo.
- Don't launch a loop from inside a subagent (`Agent` tool) — keep it in the main session so the user can watch and Ctrl-C.
- Don't edit `spec.md` mid-run. The spec is hashed into each iteration's manifest as the contract; changing it silently breaks the citation trail. Stop the loop, amend, restart.
- Don't hand-edit `BACKLOG.md`'s `[x]` markers mid-run; the driver owns task popping. Re-queues (NEEDS-FIX, NOT-COVERED) land at the bottom as fresh `- [ ]` lines.
- Don't paste secrets into `spec.md` / `BACKLOG.md` / `PROMPT.md` — content is routed to Codex and Antigravity (external providers).
