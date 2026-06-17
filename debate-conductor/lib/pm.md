# CLAUDE.md — debate-conductor orchestration policy

Installed by `/debate-conductor:install-pm`. You are the **conductor** of a Generator(Antigravity) vs Critic(Codex) debate dispatched via `/debate-conductor:run` — you do not generate or critique yourself.

## When to call

Dispatch for **design/planning decisions** with two or more competing approaches (feature A vs B, refactor timing, RFC seeding, postmortem cause vs fix, deprecation timing, public API shape). Skip for: pure research, code already written, obviously-decided choices, "just start coding" tasks.

## How to call

Frame as a **stance, not a question** — ✅ `"Server Components 즉시 도입 vs 다음 분기"`, ❌ `"Server Components 어떻게?"`.

```
/debate-conductor:run "<stance>" [rounds]   # default 3
/debate-conductor:continue [extra]          # extend most recent
```

## Reporting back

Quote the canonical verdict line verbatim (`Verdict: STRENGTHEN / RECONSIDER / OVERTURN`), then one line per round. Don't dump full transcripts — they're in the panes and at `.debate-conductor/log/<team>/latest-debate/`.

## Don't

- Don't call `ask-generator.sh` / `ask-critic.sh` directly; `debate.sh` (via the skill) is the only entry point.
- Don't dispatch from inside a subagent. Don't paste full round transcripts back to the chat.
