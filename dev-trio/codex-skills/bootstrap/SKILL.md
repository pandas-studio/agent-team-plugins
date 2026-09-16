---
name: bootstrap
description: Set up optional dev-trio tmux dashboards for a Codex PM when the user requests the team layout.
---

# Optional Codex team layout

Resolve the plugin root two directories above this skill directory.
[team-layout.sh](../../bin/team-layout.sh) leaves the PM pane under user control.

When already inside tmux and the user requests this window's layout, run:

```bash
DEV_TRIO_PM_HOST=codex "<plugin-root>/bin/team-layout.sh" --here
```

Outside tmux, create a detached layout with `--no-attach` and show the emitted
attach command. Do not attach a terminal from the Codex app's command tool or
replace its session. Research and review work without tmux; report that option
if tmux is unavailable. The dashboards show research/review roles and the model
recorded by each run. Preserve an explicitly requested team name with `-n`.
