#!/usr/bin/env bash
# team-layout.sh — set up the 3-agent team layout in tmux.
#
#   ┌─────────────────┬──────────────────┐
#   │                 │  gemini          │
#   │  Claude (PM)    │  dashboard       │
#   │  shell —        ├──────────────────┤
#   │  run 'claude'   │  codex           │
#   │  yourself       │  dashboard       │
#   └─────────────────┴──────────────────┘
#
# Default: creates a new tmux session named "dev-trio" and attaches.
# Use --here to apply to the current window instead. The new panes inherit
# cwd from the caller, so workspace-relative log paths resolve correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH="$SCRIPT_DIR/dashboard.sh"
# Panes inherit the user's workspace cwd ($PWD at invocation), not the plugin
# install directory. Logs land in $PWD/.dev-trio/log/... that way.
REPO_DIR="${PWD}"

SESSION="dev-trio"
HERE=0
ATTACH=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Sets up the 3-agent team tmux layout (Claude main + Gemini/Codex dashboards).

Options:
  -n NAME        Session / @team-name (default: ${SESSION})
  --here         Apply layout to the current tmux window instead of creating a
                 new session. Splits the current pane in place.
  --no-attach    Create the session detached; do not attach.
  -h, --help     Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) SESSION="$2"; shift 2 ;;
    --here) HERE=1; shift ;;
    --no-attach) ATTACH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

command -v tmux >/dev/null 2>&1 || { echo "error: tmux not installed" >&2; exit 2; }
[ -x "$DASH" ] || { echo "error: $DASH not found or not executable" >&2; exit 2; }

trap 'rc=$?; echo "error: tmux command failed (line $LINENO, exit $rc). Session=$SESSION may be in an inconsistent state — check with: tmux ls" >&2; exit $rc' ERR

if [ "$HERE" = "1" ]; then
  [ -n "${TMUX:-}" ] || { echo "error: --here requires running inside tmux" >&2; exit 2; }
  tmux display-message -p '#S' >/dev/null 2>&1 || {
    echo "error: cannot reach tmux server from \$TMUX=$TMUX" >&2; exit 2; }
  # Stamp this window with the team name (used by wrappers/dashboard for log isolation)
  # and rename the window for visibility.
  tmux set-option -w '@team-name' "$SESSION"
  tmux rename-window "$SESSION"
  GEMINI_P=$(tmux split-window -h -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$GEMINI_P" "$DASH gemini" Enter
  CODEX_P=$(tmux split-window -v -t "$GEMINI_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$CODEX_P" "$DASH codex" Enter
  tmux select-pane -L 2>/dev/null || true
  echo "✓ Layout applied to current window (team: ${SESSION}). Run 'claude' in the left pane."
  exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists — attaching."
else
  MAIN_P=$(tmux new-session -d -s "$SESSION" -n "$SESSION" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux set-option -w -t "$SESSION" '@team-name' "$SESSION"
  GEMINI_P=$(tmux split-window -h -t "$MAIN_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$GEMINI_P" "$DASH gemini" Enter
  CODEX_P=$(tmux split-window -v -t "$GEMINI_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$CODEX_P" "$DASH codex" Enter
  tmux select-pane -t "$MAIN_P"
  tmux send-keys -t "$MAIN_P" "# 3-agent team ready (team: ${SESSION}). Run 'claude' to start." Enter
fi

if [ "$ATTACH" = "1" ]; then
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$SESSION"
  else
    tmux attach -t "$SESSION"
  fi
else
  echo "✓ Session '$SESSION' ready (detached). Attach with:  tmux attach -t $SESSION"
fi
