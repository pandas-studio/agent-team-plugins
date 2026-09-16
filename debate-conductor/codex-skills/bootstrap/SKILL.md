---
name: bootstrap
description: Set up optional debate-conductor tmux transcript panes for a Codex PM when the user requests the debate layout.
---

# Optional Codex Debate Layout

Resolve the plugin root two directories above this skill directory. The shared
entry point is [team-3pane.sh](../../bin/team-3pane.sh). Do not assume the
plugin added its bin directory to PATH.

When already inside tmux and the user requests this window's debate layout, run:

```bash
DEBATE_CONDUCTOR_PM_HOST=codex "<plugin-root>/bin/team-3pane.sh" --here
```

Outside tmux, create a detached layout with `--new-session --no-attach` and
show the emitted attach command. Do not attach a terminal from Codex's command
tool or replace its session. Debate runs work without tmux; report that option
if tmux is unavailable. Preserve an explicitly requested team name with `-n`.
