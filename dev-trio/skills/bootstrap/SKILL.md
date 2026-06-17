---
description: Set up the 3-pane tmux layout for the dev-trio team (left = Claude PM, top-right = Antigravity researcher dashboard, bottom-right = Codex reviewer dashboard). Run this once after starting `claude` inside tmux. Required before `/dev-trio:research` and `/dev-trio:review`.
disable-model-invocation: true
allowed-tools: Bash(team-layout.sh:*) Bash(tmux:*) Bash(echo:*)
---

# Bootstrap the dev-trio layout

This skill prepares a 3-pane tmux view: this Claude session stays in the left pane, the top-right pane live-renders the Antigravity researcher dashboard, the bottom-right pane live-renders the Codex reviewer dashboard.

## Steps

1. **Verify tmux**. Run a Bash check:
   ```bash
   [ -n "$TMUX" ] && echo "in-tmux" || echo "no-tmux"
   ```
   If the result is `no-tmux`, stop and tell the user:
   > Bootstrap requires running inside a tmux session. Exit Claude, then:
   > ```
   > tmux new-session -s mywork
   > claude
   > /dev-trio:bootstrap
   > ```

2. **Apply the 3-pane split** by calling:
   ```bash
   team-layout.sh --here
   ```
   `team-layout.sh` is on the plugin's PATH while the plugin is active. The script splits the current pane and launches `dashboard.sh agy` (top-right) and `dashboard.sh codex` (bottom-right). It also stamps the window with `@team-name` so the wrappers and dashboards agree on the log namespace.

   Logs land in `$PWD/.dev-trio/log/<team>/`. Override the log root with the `DEV_TRIO_LOG_DIR` env var if needed.

3. **Confirm and instruct**. After the split succeeds, tell the user:
   > Layout ready. The top-right pane will live-render Antigravity status and the bottom-right Codex status as soon as you dispatch a call. Next:
   > - One-shot research → `/dev-trio:research <question>` (or raw: `ask-agy.sh "..."`)
   > - One-shot review → `/dev-trio:review [focus]` (or raw: `ask-codex.sh ...`)
   > - Optional: install the PM orchestration policy into this workspace's `CLAUDE.md` → `/dev-trio:install-pm`

Do NOT launch a research or review from this skill — that's `research` / `review`'s job. Bootstrap is layout-only.
