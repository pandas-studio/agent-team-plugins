#!/usr/bin/env bash
# team-layout.sh — set up the 3-agent team layout in tmux.
#
#   ┌─────────────────┬──────────────────┐
#   │                 │  antigravity     │
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
# shellcheck source=../lib/host.sh
. "$SCRIPT_DIR/../lib/host.sh"
PM_HOST="$(dev_trio_host)" || exit $?
DASH="$SCRIPT_DIR/dashboard.sh"
printf -v DASH_AGY_CMD '%q agy' "$DASH"
printf -v DASH_CODEX_CMD '%q codex' "$DASH"
# Panes inherit the user's workspace cwd ($PWD at invocation), not the plugin
# install directory. Logs land in $PWD/.dev-trio/log/... that way.
REPO_DIR="${PWD}"

SESSION="dev-trio"
HERE=0
ATTACH=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Sets up the 3-agent team tmux layout (${PM_HOST} PM + researcher/reviewer dashboards).

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

# ---- --here guard (#100) ----------------------------------------------------
# Kept identical in debate-conductor/bin/team-3pane.sh and
# dev-trio/bin/team-layout.sh. A layout is only ever built from a one-pane
# window, and @team-layout ("<layout> <pane ids>") is written only once it is
# complete, so a re-run can tell a finished layout from a half-built or
# hand-split window. Every tmux call targets $HERE_PANE's window.

# here_panes — the window's pane ids, sorted, space-separated.
here_panes() {
  tmux list-panes -t "$HERE_PANE" -F '#{pane_id}' | sort | tr '\n' ' '
}

# here_guard LAYOUT — rc 0: build the layout (one-pane window); rc 3: this
# team's LAYOUT is already complete here; rc 2: refused, with a hint on stderr;
# rc 1: a tmux read failed. Callers use `|| rc=$?`, which turns errexit and the
# ERR trap off in here, so every read checks its own status.
here_guard() {
  local layout="$1" tag record live n rec_ids others p
  tag=$(tmux show-options -wqv -t "$HERE_PANE" '@team-name') &&
    record=$(tmux show-options -wqv -t "$HERE_PANE" '@team-layout') &&
    live=$(here_panes) || {
    printf 'error: cannot read the state of the tmux window of %s\n' "$HERE_PANE" >&2
    return 1
  }
  n=$(printf '%s' "$live" | wc -w | tr -d ' ')
  if [ -n "$tag" ] && [ "$tag" != "$SESSION" ]; then
    printf 'error: this window belongs to team %s, not %s.\n' "$tag" "$SESSION" >&2
    printf 'Open a new tmux window (prefix + c) and run this there.\n' >&2
    printf 'To reuse this window instead, close its other panes, then run:\n' >&2
    printf '  tmux set-option -wu -t %s @team-name; tmux set-option -wu -t %s @team-layout\n' \
      "$HERE_PANE" "$HERE_PANE" >&2
    return 2
  fi
  [ "$n" != 1 ] || return 0
  if [ "$tag" = "$SESSION" ] && [ "${record%% *}" = "$layout" ]; then
    # shellcheck disable=SC2086  # the record is a space-separated id list
    rec_ids=$(printf '%s\n' ${record#* } | sort | tr '\n' ' ')
    [ "$rec_ids" != "$live" ] || return 3
  fi
  others=""
  for p in $live; do [ "$p" = "$HERE_PANE" ] || others="$others $p"; done
  printf 'error: this window already has other panes (%s) that are not a complete %s layout for team %s.\n' \
    "${others# }" "$layout" "$SESSION" >&2
  printf 'Open a new tmux window (prefix + c) and run this there, or close the other panes first:\n' >&2
  for p in $others; do printf '  tmux kill-pane -t %s\n' "$p" >&2; done
  return 2
}

# here_stamp LAYOUT PANE... — record the finished layout, but only if the
# window holds exactly these panes (another run may have split it meanwhile).
here_stamp() {
  local layout="$1" want now
  shift
  want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  now=$(here_panes) || return 1
  if [ "$now" != "$want" ]; then
    printf 'error: the window changed while the layout was being built; not recording it.\n' >&2
    printf 'Re-run to see what to close, or open a new tmux window.\n' >&2
    return 2
  fi
  tmux set-option -w -t "$HERE_PANE" '@team-layout' "$layout $*"
}
# -----------------------------------------------------------------------------

if [ "$HERE" = "1" ]; then
  [ -n "${TMUX:-}" ] || { echo "error: --here requires running inside tmux" >&2; exit 2; }
  HERE_PANE="${TMUX_PANE:-}"
  if [ -z "$HERE_PANE" ]; then
    HERE_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || HERE_PANE=""
  fi
  [ -n "$HERE_PANE" ] && tmux display-message -t "$HERE_PANE" -p '#S' >/dev/null 2>&1 || {
    echo "error: cannot reach tmux server from \$TMUX=$TMUX" >&2; exit 2; }
  guard_rc=0
  here_guard dev-trio-layout || guard_rc=$?
  if [ "$guard_rc" = 3 ]; then
    echo "✓ Layout already present in this window (team: ${SESSION}). Run '$PM_HOST' in the left pane."
    exit 0
  fi
  [ "$guard_rc" = 0 ] || exit "$guard_rc"
  # Stamp this window with the team name (used by wrappers/dashboard for log isolation)
  # and rename the window for visibility.
  tmux set-option -w -t "$HERE_PANE" '@team-name' "$SESSION"
  tmux rename-window -t "$HERE_PANE" "$SESSION"
  AGY_P=$(tmux split-window -h -t "$HERE_PANE" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$AGY_P" "$DASH_AGY_CMD" Enter
  CODEX_P=$(tmux split-window -v -t "$AGY_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$CODEX_P" "$DASH_CODEX_CMD" Enter
  tmux select-pane -t "$HERE_PANE"
  here_stamp dev-trio-layout "$HERE_PANE" "$AGY_P" "$CODEX_P" || exit $?
  echo "✓ Layout applied to current window (team: ${SESSION}). Run '$PM_HOST' in the left pane."
  exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists — attaching."
else
  MAIN_P=$(tmux new-session -d -s "$SESSION" -n "$SESSION" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux set-option -w -t "$SESSION" '@team-name' "$SESSION"
  AGY_P=$(tmux split-window -h -t "$MAIN_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$AGY_P" "$DASH_AGY_CMD" Enter
  CODEX_P=$(tmux split-window -v -t "$AGY_P" -c "$REPO_DIR" -P -F "#{pane_id}")
  tmux send-keys -t "$CODEX_P" "$DASH_CODEX_CMD" Enter
  tmux select-pane -t "$MAIN_P"
  tmux send-keys -t "$MAIN_P" "# 3-agent team ready (team: ${SESSION}). Run '$PM_HOST' to start." Enter
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
