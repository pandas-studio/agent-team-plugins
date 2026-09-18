---
name: continue
description: Continue the most recent debate from Codex by appending more rounds to the same transcript directory.
---

# Continue a Debate from Codex

Resolve the plugin root two directories above this skill directory and use
[debate.sh](../../bin/debate.sh). Continue only an existing transcript; do not
start a fresh debate from this skill.

Find `$PWD/.debate-conductor/log/*/latest-debate`. If exactly one exists, use
its real directory. If several exist, list the team names and ask which one to
continue. If none exist, tell the user to run `$debate-conductor:run` first.

Read `<debate-dir>/topic.txt` and run:

```bash
DEBATE_CONDUCTOR_PM_HOST=codex "<plugin-root>/bin/debate.sh" --continue-from "<debate-dir>" -n <extra-rounds> "<topic>"
```

Default extra rounds to `2` when the user does not specify a number. Rounds
continue after the last completed one, which `debate.sh` reads from the
debate's append-only attempt ledger `index.jsonl` (never edit or delete it); if round 1 never completed, `debate.sh`
resumes at round 1 and reuses the round-1 context saved in `context.md`. `debate.sh`
persists and reuses the transcript's model pair and any saved rotation unless
this invocation supplies explicit model flags/env vars. Start a fresh debate to
change model pairs inside rotation or to change whether rotation is enabled.
After completion, read all round files in the same transcript directory and
summarize the latest verdict plus only the new shifts introduced by the appended
rounds. The verdict comes from the latest *completed* critic round: a critic
round counts as completed when either `index.jsonl` in that directory holds a
line with `"t":"end"`, `"rc":0` and `"role":"crit"` for it, or a
`.round-<N>-crit*.done` sidecar exists for it — check both, because a debate
started before the ledger keeps its early rounds in the sidecars alone. Only
when the directory has neither an `index.jsonl` nor any `.done` sidecar may you
fall back to the highest-numbered non-empty `round-*-crit*.md`; if it has them
and none records a completed critic round, report that no critic round
completed rather than quoting an unfinished one.
