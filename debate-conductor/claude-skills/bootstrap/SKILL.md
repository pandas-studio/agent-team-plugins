---
description: Prepare optional debate live viewers and optionally open a separate terminal window, without running a debate.
disable-model-invocation: true
allowed-tools: Bash(team-3pane.sh:*) Bash(open-view.sh:*) Read
argument-hint: "[--view=auto|tmux|none] [--open-view] [--terminal=auto|ghostty|terminal]"
---

# Prepare or open the debate view

This explicit user entry point is **view-only**. Never launch `debate.sh`,
`run-debate.sh`, or a model from bootstrap.

Read the [shared viewing contract](../../lib/view-workflow.md), parse its
controls, and call `team-3pane.sh --view=<mode>` (default auto). Add
`--view-only` for `--open-view` so the new terminal never mirrors the PM pane.

Inside tmux the helper can build a guarded three-pane layout from one pane,
or verify and reuse a managed layout. A hand-split, foreign or unverified
legacy window remains intact; a separate detached view is prepared instead.
Outside tmux it prepares two viewers with the same team/log directory the
debate uses. No terminal automatically appears from preparation alone.

With `--open-view`, call `open-view.sh --context '<exact context_file>'` and
the selected `--terminal` value. Report the helper's actual connection state;
window launch alone is not confirmed tmux attachment. Without opening, show
the exact attach command for another terminal tab/window on this machine/user.
For manual fallback, show both tail commands and the actual reason.

Preserve the context path for later requests. Never unset tmux options, kill
user panes, implicitly change another window, or change permission settings.
Tell the user they can now run `/debate-conductor:run <topic> [rounds]`.
