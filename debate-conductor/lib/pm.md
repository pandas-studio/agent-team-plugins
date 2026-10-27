# CLAUDE.md — debate-conductor orchestration policy

Installed by `/debate-conductor:install-pm`. You are the **conductor** of a Generator vs Critic debate dispatched via `/debate-conductor:run` (defaults: Generator=`agy`, Critic=`codex`; override with `--gen=<model>` / `--crit=<model>`) — you do not generate or critique yourself.

## When to call

Dispatch for **design/planning decisions** with two or more competing approaches (feature A vs B, refactor timing, RFC seeding, postmortem cause vs fix, deprecation timing, public API shape). Skip for: pure research, code already written, obviously-decided choices, "just start coding" tasks.

## How to call

Frame as a **stance, not a question** — ✅ `"Server Components 즉시 도입 vs 다음 분기"`, ❌ `"Server Components 어떻게?"`. For repo-internal topics, inline the essential facts in `<stance>` (only Round 1's Generator sees `[context-file.md]`).

```
/debate-conductor:run [--gen=<model>] [--crit=<model>] "<stance>" [rounds]   # default 3
/debate-conductor:continue [extra]                                           # extend most recent
```

## Reporting back

Quote the canonical verdict line verbatim (`Verdict: STRENGTHEN / RECONSIDER / OVERTURN`), then one line per round. Don't dump full transcripts. Use the skill's validated dispatch receipt for the exact transcript directory; live viewing is optional and must be verified, not assumed.

## Don't

- Don't call `ask-generator.sh` / `ask-critic.sh` directly; use the skill's view preparation and `run-debate.sh` dispatch/receipt flow.
- Don't dispatch from inside a subagent. Don't paste full round transcripts back to the chat.
