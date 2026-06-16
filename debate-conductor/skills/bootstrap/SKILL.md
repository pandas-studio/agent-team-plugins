---
description: Set up the 3-pane tmux layout for the debate conductor (left = Claude PM, middle = Generator, right = Critic). Run this once after starting `claude` inside tmux. Required before `/debate-conductor:run`.
disable-model-invocation: true
allowed-tools: Bash(team-3pane.sh:*) Bash(tmux:*) Bash(echo:*)
---

# Bootstrap the debate-conductor layout

This skill prepares a 3-pane tmux view: this Claude session stays in the left pane, the middle pane live-tails the Generator transcript, the right pane live-tails the Critic transcript.

## Steps

1. **Verify tmux**. Run a Bash check:
   ```bash
   [ -n "$TMUX" ] && echo "in-tmux" || echo "no-tmux"
   ```
   If the result is `no-tmux`, stop and tell the user:
   > Bootstrap requires running inside a tmux session. Exit Claude, then:
   > ```
   > tmux new-session -s debate
   > claude
   > /debate-conductor:bootstrap
   > ```

2. **Apply the 3-pane split** by calling:
   ```bash
   team-3pane.sh --here
   ```
   `team-3pane.sh` is on the plugin's PATH while the plugin is active. The script splits the current pane into three equal columns and launches `tail-role.sh gen|crit` in the new panes. Logs land in `$PWD/.debate-conductor/log/<team>/` — the team name is the tmux window's `@team-name` option (set automatically) or session name.

3. **Confirm and instruct**. After the split succeeds, tell the user:
   > Layout ready. The middle pane will live-tail the Generator (Antigravity) and the right pane the Critic (Codex) once a debate starts. Pick a topic and run:
   > ```
   > /debate-conductor:run <topic-number-or-name> [rounds]
   > ```

Do NOT launch a debate from this skill — that's `run`'s job. Bootstrap is layout-only.
