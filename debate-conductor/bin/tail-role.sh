#!/usr/bin/env bash
# tail-role.sh — wait for the latest debate run, then live-tail one role's transcript.
#
# Usage:
#   tail-role.sh <gen|crit>
#
# Pane controls:
#   c       clear the pane (also wipes scrollback)
#   space   pause / resume tailing (debate keeps writing; we just stop showing)
#   q       quit this pane
#
# Colors:
#   - Generator pane uses cyan for round banners.
#   - Critic pane uses magenta.
#   - Verdict tokens (only on critic pane) are colored: STRENGTHEN=green,
#     RECONSIDER=yellow, OVERTURN=red.
#
# debate.sh pre-creates empty round-N-{gen,crit}*.md files so `tail -F` can
# follow them all from the start. tail's own `==> filename <==` separators
# are intercepted by awk and rewritten as colored round banners. Round files
# themselves stay clean markdown — colors only live on the live-view pane.
#
# Multi-debate handling: when the user starts a new debate run, debate.sh
# retargets the `latest-debate` symlink. The control loop polls that symlink
# and tears down the current tail pipeline so the outer loop can re-glob and
# tail the new run's round files.
#
# Log location: $DEBATE_LOG_DIR (default: $PWD/.debate-conductor/log) / $TEAM /
set -euo pipefail
set -m  # job control: each backgrounded pipeline gets its own process group

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/namespace.sh
. "$SCRIPT_DIR/../lib/namespace.sh" || exit 2

ROLE="${1:-}"
case "$ROLE" in
  gen|crit) ;;
  *) echo "usage: $(basename "$0") <gen|crit>" >&2; exit 2 ;;
esac

TEAM=$(agent_team_detect_team) || exit 2
LOG_BASE="${DEBATE_LOG_DIR:-$PWD/.debate-conductor/log}"
LOG_DIR="$LOG_BASE/$TEAM"
LATEST="$LOG_DIR/latest-debate"

# ANSI color setup
RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[1;36m'
MAGENTA=$'\033[1;35m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
BORDER='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

if [ "$ROLE" = "gen" ]; then
  LABEL="GENERATOR"
  ROLE_COLOR="$CYAN"
else
  LABEL="CRITIC"
  ROLE_COLOR="$MAGENTA"
fi

print_header() {
  printf '%s── %s ──%s %s(team: %s)%s\n' "$ROLE_COLOR" "$LABEL" "$RESET" "$DIM" "$TEAM" "$RESET"
  printf '%s── log dir: %s%s\n' "$DIM" "$LOG_DIR" "$RESET"
}

# tmux: enable pane-border-status (bottom) and set this pane's title to a
# sticky controls hint. The border is part of tmux's chrome (not the pane
# content), so the hint never scrolls off when content streams in.
setup_tmux_border() {
  [ -z "${TMUX:-}" ] && return 0
  tmux set-option -w pane-border-status bottom 2>/dev/null || true
  tmux set-option -w pane-border-format ' #{pane_title} ' 2>/dev/null || true
  # xterm OSC 2 — sets tmux pane_title
  printf '\033]2;%s · c=clear · space=pause · q=quit\033\\' "$LABEL"
}

# Save tty state so we can restore on exit. Read mode is set to raw single-char
# with no echo so we can poll keystrokes alongside the symlink watcher.
STTY_SAVE=""
if [ -t 0 ]; then
  STTY_SAVE=$(stty -g </dev/tty 2>/dev/null || true)
fi

PIPE_PG=""
cleanup() {
  if [ -n "$PIPE_PG" ]; then
    kill -CONT -- "-$PIPE_PG" 2>/dev/null || true   # in case we exit while paused
    kill -TERM -- "-$PIPE_PG" 2>/dev/null || true
  fi
  [ -n "$STTY_SAVE" ] && stty "$STTY_SAVE" </dev/tty 2>/dev/null || true
  printf '\033[?25h' 2>/dev/null || true             # cursor visible
}
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT TERM

if [ -n "$STTY_SAVE" ]; then
  stty -icanon -echo min 0 time 0 </dev/tty 2>/dev/null || true
fi

setup_tmux_border
print_header
printf '%swaiting for debate to start...%s\n' "$DIM" "$RESET"

shopt -s nullglob

# Tracks the highest round number this viewer has already streamed. Persists
# across outer-loop iterations so the awk MIN_ROUND filter knows which
# markers in re-globbed tail output belong to "already-seen" rounds (replay
# from default `tail -F` last-N-lines per file) vs new rounds appended by
# /continue. Starts at 0 → on first run every round is treated as new.
KNOWN_MAX_ROUND=0

while true; do
  while [ ! -d "$LATEST" ]; do sleep 1; done

  files=( "$LATEST"/round-*-"$ROLE"*.md )
  while [ "${#files[@]}" -eq 0 ]; do
    sleep 1
    files=( "$LATEST"/round-*-"$ROLE"*.md )
    [ -d "$LATEST" ] || break
  done
  [ "${#files[@]}" -eq 0 ] && continue

  INITIAL_TARGET=$(readlink "$LATEST" 2>/dev/null || true)
  INITIAL_FILE_COUNT="${#files[@]}"
  MIN_NEW_ROUND=$((KNOWN_MAX_ROUND + 1))

  # tail (default last-N-lines) + awk pipeline backgrounded into its own
  # process group (set -m). default tail (NOT -n 0) so a `/continue` restart
  # picks up the new round's marker line even when our 1s file-count poll
  # arrives after debate.sh has already written the marker + first body
  # lines. Replay of already-seen rounds is filtered by awk's MIN_ROUND
  # check (skips any round number < min_round).
  #
  # awk:
  #   - parses `<!-- debate-round: N role model -->` markers (written by
  #     debate.sh as the first line of each round file) into colored 3-line
  #     round banners; suppresses the marker itself from the viewer
  #   - skips body of any round number below MIN_ROUND (replay protection
  #     after /continue restart)
  #   - ignores tail's per-file `==> path <==` headers entirely (absent
  #     when only one file is being tailed; unreliable across tail impls)
  #   - colors `Verdict: STRENGTHEN|RECONSIDER|OVERTURN` lines (critic only)
  #   - fflush() after every line keeps streaming visible
  {
    tail -F "${files[@]}" 2>/dev/null \
      | awk \
          -v ROLE_COLOR="$ROLE_COLOR" \
          -v RESET="$RESET" \
          -v GREEN="$GREEN" \
          -v YELLOW="$YELLOW" \
          -v RED="$RED" \
          -v BORDER="$BORDER" \
          -v MIN_ROUND="$MIN_NEW_ROUND" '
        BEGIN { min_round = MIN_ROUND + 0; in_replay = (min_round > 1) ? 1 : 0 }
        /^==> .* <==$/ { next }
        /^<!-- debate-round: [0-9]+ (gen|crit)( [^ ]+)? -->[[:space:]]*$/ {
          payload = $0
          sub(/^<!-- debate-round: /, "", payload)
          sub(/ -->[[:space:]]*$/,  "", payload)
          n = split(payload, parts, " ")
          m_round = parts[1] + 0
          if (m_round < min_round) { in_replay = 1; next }
          in_replay = 0
          m_role  = (parts[2] == "gen") ? "Generator" : "Critic"
          m_model = (n >= 3) ? parts[3] : ""
          printf "\n%s%s%s\n", ROLE_COLOR, BORDER, RESET
          if (m_model != "")
            printf "%s  Round %s · %s · %s%s\n", ROLE_COLOR, m_round, m_role, m_model, RESET
          else
            printf "%s  Round %s · %s%s\n", ROLE_COLOR, m_round, m_role, RESET
          printf "%s%s%s\n\n", ROLE_COLOR, BORDER, RESET
          fflush()
          next
        }
        in_replay { next }
        /^Verdict: STRENGTHEN[[:space:]]*$/ { printf "%s%s%s\n", GREEN,  $0, RESET; fflush(); next }
        /^Verdict: RECONSIDER[[:space:]]*$/ { printf "%s%s%s\n", YELLOW, $0, RESET; fflush(); next }
        /^Verdict: OVERTURN[[:space:]]*$/   { printf "%s%s%s\n", RED,    $0, RESET; fflush(); next }
        { print; fflush() }
      '
  } &
  PIPE_PG=$!

  PAUSED=0
  while kill -0 "$PIPE_PG" 2>/dev/null; do
    KEY=""
    if [ -n "$STTY_SAVE" ]; then
      # NOTE: integer timeout — macOS default bash 3.2 doesn't support
      # sub-second `-t` values (added in bash 4.0). With 0.5, 3.2 treats it
      # as 0 (instant timeout) and `read` returns empty without ever seeing
      # the keystroke, so c/space/q appear unresponsive.
      IFS= read -rs -t 1 -n 1 KEY </dev/tty 2>/dev/null || true
    else
      sleep 1
    fi

    case "$KEY" in
      c|C)
        # Clear visible buffer + scrollback (\033[3J), reprint header
        printf '\033[H\033[2J\033[3J'
        print_header
        ;;
      q|Q)
        kill -TERM -- "-$PIPE_PG" 2>/dev/null || true
        wait "$PIPE_PG" 2>/dev/null || true
        PIPE_PG=""
        printf '\n%s[quit]%s\n' "$DIM" "$RESET"
        exit 0
        ;;
      ' ')
        if [ "$PAUSED" = "0" ]; then
          kill -STOP -- "-$PIPE_PG" 2>/dev/null || true
          PAUSED=1
          printf '\n%s[paused — press space to resume]%s\n' "$YELLOW" "$RESET"
        else
          kill -CONT -- "-$PIPE_PG" 2>/dev/null || true
          PAUSED=0
          printf '\n%s[resumed]%s\n' "$DIM" "$RESET"
        fi
        ;;
    esac

    # symlink retarget detection — break inner loop on new debate run
    CURRENT_TARGET=$(readlink "$LATEST" 2>/dev/null || true)
    if [ -n "$CURRENT_TARGET" ] && [ "$CURRENT_TARGET" != "$INITIAL_TARGET" ]; then
      printf '\n%s── new debate run detected — re-tailing ──%s\n\n' "$DIM" "$RESET"
      [ "$PAUSED" = "1" ] && kill -CONT -- "-$PIPE_PG" 2>/dev/null || true
      kill -TERM -- "-$PIPE_PG" 2>/dev/null || true
      wait "$PIPE_PG" 2>/dev/null || true
      PIPE_PG=""
      break
    fi

    # file-count change detection — /continue appends round files into the
    # same dir without retargeting the symlink, but `tail -F`'s file argv was
    # bound at startup and does not auto-pick-up new files matching the glob.
    # Break inner loop so the outer loop re-globs and starts a fresh tail.
    current_files=( "$LATEST"/round-*-"$ROLE"*.md )
    if [ "${#current_files[@]}" -gt "$INITIAL_FILE_COUNT" ]; then
      printf '\n%s── more rounds appended — re-tailing ──%s\n\n' "$DIM" "$RESET"
      [ "$PAUSED" = "1" ] && kill -CONT -- "-$PIPE_PG" 2>/dev/null || true
      kill -TERM -- "-$PIPE_PG" 2>/dev/null || true
      wait "$PIPE_PG" 2>/dev/null || true
      PIPE_PG=""
      break
    fi
  done

  # If pipeline exited on its own (SIGPIPE on pane close, etc.), fall through
  [ -n "$PIPE_PG" ] && wait "$PIPE_PG" 2>/dev/null || true
  PIPE_PG=""

  # Carry over the highest round number streamed so the next outer-loop
  # iteration's awk gets MIN_ROUND = KNOWN_MAX_ROUND + 1 — anything lower
  # arriving in the new tail's last-N-lines replay is suppressed.
  KNOWN_MAX_ROUND=$( { printf '%s\n' "${files[@]}" 2>/dev/null || true; } \
    | sed -E 's@.*/round-([0-9]+)-.*@\1@' \
    | sort -n | tail -1)
  KNOWN_MAX_ROUND="${KNOWN_MAX_ROUND:-0}"
  sleep 1
done
