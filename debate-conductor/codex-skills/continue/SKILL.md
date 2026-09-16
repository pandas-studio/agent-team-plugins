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

Default extra rounds to `2` when the user does not specify a number. `debate.sh`
persists and reuses the transcript's model pair and any saved rotation unless
this invocation supplies explicit model flags/env vars. Start a fresh debate to
change model pairs inside rotation or to change whether rotation is enabled.
After completion, read all round files in the same transcript directory and
summarize the latest verdict plus only the new shifts introduced by the appended
rounds.
