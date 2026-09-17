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
# What it follows: debate.sh appends every attempt of this role (retries
# included) to one append-only file per debate, `stream-<role>.log`, starting
# each attempt with a header line that begins with \x1e. That file is never
# truncated or replaced, so a single `tail -n +1 -F` shows the whole debate
# exactly once, in order, however the rounds were retried or appended. awk turns
# headers into colored round banners. Round files stay clean markdown and are
# not followed.
#
# Multi-debate handling: a new debate retargets the `latest-debate` symlink.
# The controller resolves the symlink to the physical debate directory and tails
# that directory's stream, so only the controller switches debates: it polls
# the symlink, stops the pipeline, then starts one on the new directory.
#
# A debate created before streams existed has round files but no stream. The
# pane says so once and shows new rounds after the debate is continued.
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

# mawk reads a pipe in large blocks, so stream lines from `tail -F` would sit in
# its input buffer and the pane would stay empty; fflush() only flushes output.
# `-W interactive` makes mawk read line by line. gawk and BSD awk already do.
AWK_STREAM=(awk)
case "$(awk -W version 2>&1 </dev/null || true)" in
  mawk*) AWK_STREAM=(awk -W interactive) ;;
esac

RS_BYTE="$(printf '\036')"
LEGACY_NOTED=""

stop_pipeline() {
  [ -n "$PIPE_PG" ] || return 0
  kill -CONT -- "-$PIPE_PG" 2>/dev/null || true
  kill -TERM -- "-$PIPE_PG" 2>/dev/null || true
  wait "$PIPE_PG" 2>/dev/null || true
  PIPE_PG=""
}

# current_debate: physical directory latest-debate resolves to, or empty.
current_debate() {
  (cd "$LATEST" 2>/dev/null && pwd -P) || true
}

while true; do
  DIR="$(current_debate)"
  if [ -z "$DIR" ]; then sleep 1; continue; fi
  STREAM="$DIR/stream-$ROLE.log"
  if [ ! -f "$STREAM" ]; then
    if [ "$LEGACY_NOTED" != "$DIR" ]; then
      legacy_rounds=( "$DIR"/round-*-"$ROLE"*.md )
      if [ "${#legacy_rounds[@]}" -gt 0 ]; then
        printf '%sThis debate predates live streams: its rounds are in %s/round-*-%s*.md.\nRounds added by /continue will appear here.%s\n' \
          "$DIM" "$DIR" "$ROLE" "$RESET"
        LEGACY_NOTED="$DIR"
      fi
    fi
    sleep 1
    continue
  fi

  # tail + awk pipeline backgrounded into its own process group (set -m).
  # `tail -n +1`: replay the stream from the start; every line in it is
  # displayed exactly once per debate.
  #
  # awk:
  #   - a line starting with \x1e is a record written by debate.sh: an attempt
  #     header becomes a colored 3-line round banner; an end record with a
  #     nonzero rc becomes an "attempt failed" line. Model output cannot contain
  #     \x1e (debate.sh deletes it), so model text cannot forge either.
  #   - plain `<!-- debate-round: ... -->` lines (the round file's own marker,
  #     copied into the stream, or one quoted by a model) are dropped
  #   - colors `Verdict: STRENGTHEN|RECONSIDER|OVERTURN` lines (critic only)
  #   - fflush() after every line keeps streaming visible
  {
    tail -n +1 -F "$STREAM" 2>/dev/null \
      | "${AWK_STREAM[@]}" \
          -v ROLE_COLOR="$ROLE_COLOR" \
          -v RESET="$RESET" \
          -v GREEN="$GREEN" \
          -v YELLOW="$YELLOW" \
          -v RED="$RED" \
          -v BORDER="$BORDER" \
          -v HDR="$RS_BYTE" '
        # A round file marker, as copied into the stream or quoted by a model.
        function is_marker(line) {
          return line ~ /^<!-- debate-round: [0-9]+ (gen|crit)( [^ ]+)? -->[[:space:]]*$/
        }
        # Records written by debate.sh are `R ROLE` then space-separated tokens
        # (MODEL and id= in headers, rc= and id= in end records). Tokens this
        # viewer does not know are ignored (#53).
        index($0, HDR) == 1 && substr($0, 2) ~ /^<!-- debate-round-end: [0-9]+ (gen|crit)( [^ ]+)+ -->$/ {
          # End record: say so only when the attempt failed. It needs exactly
          # one rc= token, and a numeric one.
          payload = substr($0, 2)
          sub(/^<!-- debate-round-end: /, "", payload)
          sub(/ -->$/, "", payload)
          n = split(payload, parts, " ")
          rc = ""
          rcs = 0
          for (i = 3; i <= n; i++)
            if (parts[i] ~ /^rc=/) { rcs++; rc = substr(parts[i], 4) }
          if (rcs == 1 && rc ~ /^[0-9]+$/ && rc != "0") { printf "\n%s── attempt failed (rc=%s) ──%s\n", YELLOW, rc, RESET; fflush() }
          next
        }
        index($0, HDR) == 1 {
          payload = substr($0, 2)
          if (payload !~ /^<!-- debate-round: [0-9]+ (gen|crit)( [^ ]+)* -->[[:space:]]*$/) next
          sub(/^<!-- debate-round: /, "", payload)
          sub(/ -->[[:space:]]*$/,  "", payload)
          n = split(payload, parts, " ")
          m_role  = (parts[2] == "gen") ? "Generator" : "Critic"
          m_model = (n >= 3 && parts[3] !~ /=/) ? parts[3] : ""
          printf "\n%s%s%s\n", ROLE_COLOR, BORDER, RESET
          if (m_model != "")
            printf "%s  Round %s · %s · %s%s\n", ROLE_COLOR, parts[1], m_role, m_model, RESET
          else
            printf "%s  Round %s · %s%s\n", ROLE_COLOR, parts[1], m_role, RESET
          printf "%s%s%s\n\n", ROLE_COLOR, BORDER, RESET
          fflush()
          next
        }
        is_marker($0) { next }
        /^Verdict: STRENGTHEN[[:space:]]*$/ { printf "%s%s%s\n", GREEN,  $0, RESET; fflush(); next }
        /^Verdict: RECONSIDER[[:space:]]*$/ { printf "%s%s%s\n", YELLOW, $0, RESET; fflush(); next }
        /^Verdict: OVERTURN[[:space:]]*$/   { printf "%s%s%s\n", RED,    $0, RESET; fflush(); next }
        { print; fflush() }
      '
  } &
  PIPE_PG=$!

  PAUSED=0
  RETARGETED=0
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
        stop_pipeline
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

    # A new debate: stop following this one before saying so, so nothing from
    # the old pipeline can print after the notice.
    NOW="$(current_debate)"
    if [ -n "$NOW" ] && [ "$NOW" != "$DIR" ]; then
      stop_pipeline
      RETARGETED=1
      printf '\n%s── new debate run detected — following it ──%s\n\n' "$DIM" "$RESET"
      break
    fi
  done

  if [ "$RETARGETED" = "0" ]; then
    # The pipeline ended on its own (e.g. tail or awk was killed). Starting a
    # new one would replay the stream from the start and show every line
    # again, so stop and say so instead.
    stop_pipeline
    printf '\n%s── stream follower stopped — restart this pane to follow the debate again ──%s\n' "$YELLOW" "$RESET"
    exit 0
  fi
done
