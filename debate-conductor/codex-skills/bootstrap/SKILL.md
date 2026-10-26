---
name: bootstrap
description: Prepare optional debate live viewers for Codex and optionally open a separate terminal window, without starting a debate.
---

# Prepare or open a Codex debate view

Read the [shared viewing contract](../../lib/view-workflow.md). Resolve the
plugin root two directories above this skill directory and use **absolute**
`<plugin-root>/bin/team-3pane.sh` and `open-view.sh` paths. Do not assume the
plugin added its bin directory to PATH.

This is an explicit user view-only entry point. Parse leading
`--view=auto|tmux|none` (default auto), `--open-view` and optional
`--terminal=auto|ghostty|terminal`. Prepare via `team-3pane.sh --view=<mode>`,
adding `--view-only` for an opening request. Read the returned context JSON.

Inside tmux a verified layout is reused or a guarded one-pane window is split.
Other/legacy unverified windows stay intact and use a detached two-role view.
Outside tmux preparation creates a background view, **not a visible terminal**.

For `--open-view`, call the absolute `open-view.sh --context '<context_file>'`
with the selected terminal. Report confirmed attachment versus an unconfirmed
launch honestly. Otherwise show the exact attach command for another local
terminal tab/window; a manual fallback needs both tail commands and its reason.
Follow the shared socket/Automation permission rules without changing settings.

Never dispatch `run-debate.sh`, `debate.sh`, or any model from this skill.
Preserve user windows and context data; bootstrap is optional before run/continue.
