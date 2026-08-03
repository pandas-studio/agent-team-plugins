#!/usr/bin/env bash
# team-3pane.sh — apply the debate-conductor 3-pane live-view layout.
#
#   ┌─────────────────┬─────────────────┬─────────────────┐
#   │                 │                 │                 │
#   │  Claude PM      │  Generator      │  Critic         │
#   │  (this pane)    │  round-*-gen.md │  round-*-crit.md│
#   │                 │  (live tail)    │  (live tail)    │
#   │                 │                 │                 │
#   └─────────────────┴─────────────────┴─────────────────┘
#
# Primary mode: --here (default) — splits the current tmux window in place.
# Designed to be invoked from inside Claude Code's Bash tool, after the user
# starts a tmux session and runs `claude` in it. Panes inherit cwd from the
# caller, so workspace-relative log paths resolve correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAIL="$SCRIPT_DIR/tail-role.sh"

SESSION="debate-conductor"
ATTACH=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Apply the debate-conductor 3-pane layout (PM shell + per-role live tails).

Options:
  -n NAME        Team @team-name window option (default: ${SESSION})
                 Used to namespace logs across windows.
  --new-session  Create a new detached tmux session instead of splitting here.
  --no-attach    With --new-session, do not attach.
  -h, --help     Show this help.
EOF
}

# NEW_SESSION=0 is here-mode: this script primarily runs from inside Claude/tmux.
NEW_SESSION=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) SESSION="$2"; shift 2 ;;
    --here) NEW_SESSION=0; shift ;;
    --new-session) NEW_SESSION=1; shift ;;
    --no-attach) ATTACH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

command -v tmux >/dev/null 2>&1 || { echo "error: tmux not installed" >&2; exit 2; }
[ -x "$TAIL" ] || { echo "error: $TAIL not found or not executable" >&2; exit 2; }

# shellcheck disable=SC2154  # rc is assigned by the trap body itself.
trap 'rc=$?; echo "error: tmux command failed (line $LINENO, exit $rc). Session=$SESSION may be in an inconsistent state — check with: tmux ls" >&2; exit $rc' ERR

# Apply 3-pane split to a given main pane id, in a window already stamped
# with @team-name. Panes inherit cwd from $MAIN — no explicit -c, so logs
# resolve to the user's workspace.
apply_3pane_split() {
  local MAIN="$1"
  local MID
  MID=$(tmux split-window -h -t "$MAIN" -P -F "#{pane_id}")
  local RIGHT
  RIGHT=$(tmux split-window -h -t "$MID" -P -F "#{pane_id}")
  tmux select-layout -t "$MAIN" even-horizontal
  tmux send-keys -t "$MID"   "$TAIL gen"  Enter
  tmux send-keys -t "$RIGHT" "$TAIL crit" Enter
  tmux select-pane -t "$MAIN"
}

if [ "$NEW_SESSION" = "0" ]; then
  [ -n "${TMUX:-}" ] || {
    cat >&2 <<EOF
error: not inside a tmux session.

Start tmux first, then run this script (or invoke /debate-conductor:bootstrap):

    tmux new-session -s debate
    # inside tmux:
    claude
    # inside claude:
    /debate-conductor:bootstrap

Alternatively, use --new-session to create a detached session here.
EOF
    exit 2
  }
  tmux display-message -p '#S' >/dev/null 2>&1 || {
    echo "error: cannot reach tmux server from \$TMUX=$TMUX" >&2; exit 2; }
  tmux set-option -w '@team-name' "$SESSION"
  tmux rename-window "$SESSION"
  MAIN_P=$(tmux display-message -p '#{pane_id}')
  apply_3pane_split "$MAIN_P"
  echo "✓ 3-pane split applied (team: ${SESSION}). Run /debate-conductor:run in the left pane."
  exit 0
fi

# --new-session path: detached session; primarily for headless smoke testing.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists — attaching."
else
  MAIN_P=$(tmux new-session -d -s "$SESSION" -n "$SESSION" -P -F "#{pane_id}")
  tmux set-option -w -t "$SESSION" '@team-name' "$SESSION"
  apply_3pane_split "$MAIN_P"
  tmux send-keys -t "$MAIN_P" "# debate-conductor ready (team: ${SESSION}). Start: claude --plugin-dir <path-to-plugin>" Enter
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
