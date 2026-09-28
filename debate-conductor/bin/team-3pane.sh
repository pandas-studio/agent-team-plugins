#!/usr/bin/env bash
# team-3pane.sh — apply the debate-conductor 3-pane live-view layout.
#
#   ┌─────────────────┬─────────────────┬─────────────────┐
#   │                 │                 │                 │
#   │  Claude PM      │  Generator      │  Critic         │
#   │  (this pane)    │ stream-gen.log  │ stream-crit.log │
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

case "${DEBATE_CONDUCTOR_PM_HOST:-claude}" in
  claude) PM_LABEL="Claude"; RUN_HINT="/debate-conductor:run" ;;
  codex)  PM_LABEL="Codex";  RUN_HINT="\$debate-conductor:run" ;;
  *) echo "error: DEBATE_CONDUCTOR_PM_HOST must be claude or codex" >&2; exit 2 ;;
esac

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
  local gen_cmd crit_cmd
  printf -v gen_cmd '%q %q' "$TAIL" gen
  printf -v crit_cmd '%q %q' "$TAIL" crit
  tmux send-keys -t "$MID"   "$gen_cmd"  Enter
  tmux send-keys -t "$RIGHT" "$crit_cmd" Enter
  tmux select-pane -t "$MAIN"
  SPLIT_PANES="$MID $RIGHT"
}

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
  HERE_PANE="${TMUX_PANE:-}"
  if [ -z "$HERE_PANE" ]; then
    HERE_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || HERE_PANE=""
  fi
  [ -n "$HERE_PANE" ] && tmux display-message -t "$HERE_PANE" -p '#S' >/dev/null 2>&1 || {
    echo "error: cannot reach tmux server from \$TMUX=$TMUX" >&2; exit 2; }
  guard_rc=0
  here_guard debate-3pane || guard_rc=$?
  if [ "$guard_rc" = 3 ]; then
    echo "✓ 3-pane layout already present (team: ${SESSION}). Run ${RUN_HINT} in the ${PM_LABEL} pane."
    exit 0
  fi
  [ "$guard_rc" = 0 ] || exit "$guard_rc"
  tmux set-option -w -t "$HERE_PANE" '@team-name' "$SESSION"
  tmux rename-window -t "$HERE_PANE" "$SESSION"
  apply_3pane_split "$HERE_PANE"
  # shellcheck disable=SC2086  # two pane ids
  here_stamp debate-3pane "$HERE_PANE" $SPLIT_PANES || exit $?
  echo "✓ 3-pane split applied (team: ${SESSION}). Run ${RUN_HINT} in the ${PM_LABEL} pane."
  exit 0
fi

# --new-session path: detached session; primarily for headless smoke testing.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists — attaching."
else
  MAIN_P=$(tmux new-session -d -s "$SESSION" -n "$SESSION" -P -F "#{pane_id}")
  tmux set-option -w -t "$SESSION" '@team-name' "$SESSION"
  apply_3pane_split "$MAIN_P"
  tmux send-keys -t "$MAIN_P" "# debate-conductor ready for ${PM_LABEL} (team: ${SESSION}). Run ${RUN_HINT} to start." Enter
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
