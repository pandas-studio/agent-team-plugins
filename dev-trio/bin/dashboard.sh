#!/usr/bin/env bash
# dashboard.sh — live, formatted summary view of researcher/reviewer runs.
#
# Usage:
#   dashboard.sh agy            # render researcher status
#   dashboard.sh codex          # render reviewer status
#   dashboard.sh codex --once   # render one frame and exit (tests, scripts)
#
# `agy` and `codex` are compatibility identifiers for the two log channels
# (agy-*.log, codex-*.log), not the model that runs — any CLI can fill any role
# via the registry, and the header shows the model this run actually used.
#
# Every rendered value comes from the run's *.run.json (lib/runstate.sh) and
# *.review.json (lib/review-result.sh), both written by the wrapper. This
# script never parses the log body: the log interleaves the wrapper's framing
# with untrusted text, so a focus or a model response could otherwise forge the
# model, the start time or the completion state. A log with no run metadata
# beside it is rendered as `legacy` — named, not guessed at.
#
# Run this in a side tmux pane. Re-renders only when the source log changes
# (no flicker), and shows distilled key points — the full raw output stays
# in the Claude (PM) pane and on disk.
#
# Controls:
#   l       open full log in less (q to return)
#   space   toggle pause (auto-refresh on/off)
#   q       quit
#   Ctrl-C  also quits
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/namespace.sh
. "$PLUGIN_ROOT/lib/namespace.sh" || exit 2
# shellcheck source=../lib/review-result.sh
. "$PLUGIN_ROOT/lib/review-result.sh" || exit 2
# shellcheck source=../lib/runstate.sh
. "$PLUGIN_ROOT/lib/runstate.sh" || exit 2

ROLE="${1:?usage: $0 agy|codex [--once]}"
shift
ONCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    *) echo "usage: $0 agy|codex [--once]" >&2; exit 2 ;;
  esac
done

case "$ROLE" in
  agy)
    ICON="🔍"; TITLE="Researcher"
    HEADER_COLOR=$'\033[1;36m'   # bright cyan
    LABEL="Query"
    ;;
  codex)
    ICON="🧐"; TITLE="Reviewer"
    HEADER_COLOR=$'\033[1;35m'   # bright magenta
    LABEL="Focus"
    ;;
  *)
    echo "usage: $0 agy|codex [--once]" >&2; exit 2 ;;
esac

# Team namespace — must match what wrappers use.
TEAM=$(agent_team_detect_team) || exit 2
LOG_DIR="${DEV_TRIO_LOG_DIR:-$PWD/.dev-trio/log}/$TEAM"
case "$LOG_DIR" in /*) ;; *) LOG_DIR="$PWD/$LOG_DIR" ;; esac
LATEST="$LOG_DIR/latest-$ROLE.log"

RESET=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
GUTTER='│'   # untrusted text is rendered behind this, never bare

# Byte and character policy for everything that originates in a model, in the
# user's own input, or in a filename. In order: drop invalid UTF-8 (which also
# repairs a partial character left by a byte-level cut), drop every C0 control
# and DEL except tab and newline, then drop the UTF-8 encodings of the C1
# controls U+0080-U+009F, which are valid UTF-8 and so pass iconv untouched.
#
# Only \011 (tab) and \012 (newline) survive. ESC (\033) is the obvious one to
# remove, but carriage return (\015) matters just as much: it returns the cursor
# to column 0, so a line of model text can be written over the gutter and over
# whatever this script printed before it.
_scrub() {
  iconv -c -f UTF-8 -t UTF-8 2>/dev/null \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | LC_ALL=C sed $'s/\302[\200-\237]//g'
}

# sanitize_line <max-chars> — a value rendered inside one of our own lines.
# Newlines and tabs go too: such a value must not be able to fabricate a second
# rendered line that looks like a dashboard field.
sanitize_line() {
  local max="$1" out
  out=$(_scrub | LC_ALL=C tr -d '\011\012' | head -c $((max * 4)) | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  out=$(printf '%s' "$out" | fold -w "$max" | head -1)
  printf '%s' "$out"
}

# sanitize_block — a multi-line value; newlines survive, controls do not.
# Callers render the result behind $GUTTER.
ANSWER_SCAN_KB=64
ANSWER_SCAN_BYTES=$((ANSWER_SCAN_KB * 1024))
sanitize_block() {
  head -c "$ANSWER_SCAN_BYTES" | _scrub
}

# The team name and the log root come from the environment ($AGENT_TEAM,
# $DEV_TRIO_LOG_DIR), which this process does not own, and both are rendered.
# namespace.sh validates the team; nothing validates the log root, and this
# script is not the place to decide which env values were checked elsewhere —
# so both go through the same containment as model text.
TEAM_SHOWN=$(printf '%s' "$TEAM" | sanitize_line 48)
LATEST_SHOWN=$(printf '%s' "$LATEST" | sanitize_line 120)

DASH_TMPDIR=""   # set below; declared here so the traps are safe under set -u
_dash_discard_snapshots() { [ -z "$DASH_TMPDIR" ] || rm -rf "$DASH_TMPDIR"; }
cleanup() { _dash_discard_snapshots; printf '\033[?25h\033[H\033[2J'; exit 0; }
trap cleanup INT TERM
trap _dash_discard_snapshots EXIT
[ "$ONCE" = "1" ] || printf '\033[?25l'   # hide cursor

# A frame is rebuilt on every poll, so the inputs it parses are bounded rather
# than the output alone. Anything larger is named, not loaded.
MAX_DOC_BYTES=$((1024 * 1024))

# Per-frame snapshots. A reader that must bound what it loads has to hold the
# bytes somewhere; a file rather than a shell variable, because command
# substitution strips trailing newlines and ${#var} counts characters, not
# bytes. A document padded with a megabyte of newlines and a second JSON value
# appended measured 736 "characters" that way, passing both the size limit and
# the single-document rule.
DASH_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/dev-trio-dashboard.XXXXXX") || exit 2
chmod 700 "$DASH_TMPDIR" 2>/dev/null || true
RUN_SNAP="$DASH_TMPDIR/run.json"
RESULT_SNAP="$DASH_TMPDIR/result.json"
ANSWER_SNAP="$DASH_TMPDIR/answer.txt"

# read_bounded <path> <limit> <dest> — copy at most limit+1 bytes of a regular
# file into dest from one open, then judge the copy's real byte count.
#   rc 0  the whole source is in dest, within the limit
#   rc 1  not a readable regular file, or the copy failed
#   rc 2  the source exceeds the limit; dest holds a prefix, never a document
# Sizing a path and then reopening it would let the file be replaced or grown in
# between, and would block on a named pipe. Parsing happens against dest, so the
# single-document rule is enforced over exactly the bytes that were accepted.
read_bounded() {
  local path="$1" limit="$2" dest="$3" bytes
  # Empty the snapshot first: it outlives the frame, and a caller that reads it
  # after a failed copy would otherwise be shown the previous run's bytes.
  : > "$dest" 2>/dev/null || return 1
  [ -f "$path" ] && [ -r "$path" ] || return 1
  head -c $((limit + 1)) < "$path" > "$dest" 2>/dev/null || return 1
  bytes=$(wc -c < "$dest" 2>/dev/null) || return 1
  bytes=${bytes//[^0-9]/}
  [ -n "$bytes" ] || return 1
  [ "$bytes" -le "$limit" ] || return 2
}

get_wrap_width() {
  local c
  c=$(tput cols 2>/dev/null || echo 80)
  [ "$c" -lt 40 ] && c=40
  echo $((c - 6))
}

# append_block <indent> <text> <max-lines> — fold and emit untrusted text behind
# the gutter, marking truncation rather than silently dropping the rest.
append_block() {
  local indent="$1" text="$2" max_lines="$3"
  local wrapped total shown line
  wrapped=$(printf '%s\n' "$text" | fold -s -w $((WRAP_W - 2)))
  total=$(printf '%s\n' "$wrapped" | wc -l | tr -d ' ')
  shown=0
  while IFS= read -r line; do
    shown=$((shown + 1))
    [ "$shown" -gt "$max_lines" ] && break
    BUF+="${indent}${DIM}${GUTTER}${RESET} ${line}"$'\n'
  done <<< "$wrapped"
  if [ "$total" -gt "$max_lines" ]; then
    BUF+="${indent}${DIM}${GUTTER} … $((total - max_lines)) more line(s) not shown${RESET}"$'\n'
  fi
}

LAST_HASH=""
PAUSED=0
# A terminal never reaches EOF; any other stdin eventually does. See the poll
# at the bottom of the loop.
STDIN_LIVE=1
STDIN_INSTANT=0

while true; do
  if [ "$PAUSED" = "0" ]; then
    WRAP_W=$(get_wrap_width)
    # Canonical form of the team directory, resolved every frame. A pane is
    # normally opened before the first call creates it (that is what
    # /dev-trio:bootstrap does), and a name resolved once at startup would keep
    # whatever spelling the environment supplied — a `./`, a `..`, a symlinked
    # parent — while every later comparison is against a canonical path. Empty
    # means the directory still does not exist, which the states below already
    # render as "no runs yet"; containment is never checked against a name that
    # was never resolved.
    LOG_DIR_REAL=$(cd "$LOG_DIR" 2>/dev/null && pwd -P) || LOG_DIR_REAL=""
    # Freeze the latest log target for this frame. Every sibling artifact is
    # resolved from this path, never from an independently changing latest link.
    SOURCE="$LATEST"
    LINK_TARGET=""
    if [ -L "$LATEST" ]; then
      LINK_TARGET=$(readlink "$LATEST" 2>/dev/null) || LINK_TARGET=""
      case "$LINK_TARGET" in
        /*) SOURCE="$LINK_TARGET" ;;
        *) SOURCE="$LOG_DIR/$LINK_TARGET" ;;
      esac
    fi

    # ── Resolve exactly one state for this frame ────────────────────────────
    STATE=""
    STATE_DETAIL=""
    RUN_JSON=""
    if [ ! -e "$LATEST" ] && [ ! -L "$LATEST" ]; then
      STATE="no-link"
    elif [ ! -e "$SOURCE" ]; then
      STATE="dangling"
      STATE_DETAIL=$(printf '%s' "${LINK_TARGET:-$LATEST}" | sanitize_line 80)
    else
      RUN_PATH="$(runstate_path "$SOURCE")"
      RUN_READ_RC=0
      if [ -e "$RUN_PATH" ]; then
        read_bounded "$RUN_PATH" "$MAX_DOC_BYTES" "$RUN_SNAP" || RUN_READ_RC=$?
      fi
      if [ ! -e "$RUN_PATH" ]; then
        STATE="legacy"
      elif [ "$RUN_READ_RC" = "2" ]; then
        # Bound the input before it is parsed, not after: everything below holds
        # whole documents in shell variables and re-parses them every poll.
        STATE="oversized"
        STATE_DETAIL="run metadata"
      elif [ "$RUN_READ_RC" != "0" ]; then
        STATE="unreadable"
      elif ! RUN_JSON=$(runstate_read "$RUN_SNAP"); then
        STATE="unreadable"
        RUN_JSON=""
      else
        RUN_CHANNEL=$(printf '%s\n' "$RUN_JSON" | jq -r '.channel')
        RUN_TEAM=$(printf '%s\n' "$RUN_JSON" | jq -r '.team')
        RUN_LOG=$(printf '%s\n' "$RUN_JSON" | jq -r '.log_path')
        # The metadata must describe *this* log. A valid run.json belonging to
        # another invocation in the same directory is a mismatch, not a frame.
        SOURCE_DIR=$(cd "$(dirname "$SOURCE")" 2>/dev/null && pwd -P) || SOURCE_DIR=""
        RUN_LOG_DIR=$(cd "$(dirname "$RUN_LOG")" 2>/dev/null && pwd -P) || RUN_LOG_DIR=""
        if [ -z "$LOG_DIR_REAL" ] || [ -z "$SOURCE_DIR" ] || [ "$SOURCE_DIR" != "$LOG_DIR_REAL" ]; then
          # A latest link may only name a run inside this team's directory.
          # Matching a team string is not containment: another directory can
          # carry the same team name in its metadata.
          STATE="mismatch"
          STATE_DETAIL="log is outside the team directory"
        elif [ "$RUN_LOG_DIR" != "$LOG_DIR_REAL" ]; then
          STATE="mismatch"
          STATE_DETAIL="metadata names a log outside the team directory"
        elif [ "$RUN_CHANNEL" != "$ROLE" ]; then
          STATE="mismatch"
          STATE_DETAIL="channel $(printf '%s' "$RUN_CHANNEL" | sanitize_line 24) != $ROLE"
        elif [ "$RUN_TEAM" != "$TEAM" ]; then
          STATE="mismatch"
          STATE_DETAIL="team $(printf '%s' "$RUN_TEAM" | sanitize_line 40) != $TEAM"
        elif [ ! "$RUN_LOG" -ef "$SOURCE" ] 2>/dev/null; then
          STATE="mismatch"
          STATE_DETAIL="metadata names another log: $(basename "$RUN_LOG" | sanitize_line 60)"
        elif [ "$(printf '%s\n' "$RUN_JSON" | jq -r 'if (.completion // null) == null then "run" else "done" end')" = "run" ]; then
          STATE="running"
        else
          STATE="done"
        fi
      fi
    fi

    MODEL=""
    if [ -n "$RUN_JSON" ]; then
      MODEL=$(printf '%s\n' "$RUN_JSON" | jq -r '.model' | sanitize_line 40)
    fi

    BUF=""
    BUF+="${HEADER_COLOR}═══════════════════════════════════════════════${RESET}"$'\n'
    BUF+="${HEADER_COLOR}  ${ICON}  ${TITLE}${MODEL:+ · $MODEL}${RESET}  ${DIM}[team: ${TEAM_SHOWN}]${RESET}"$'\n'
    BUF+="${HEADER_COLOR}═══════════════════════════════════════════════${RESET}"$'\n\n'

    case "$STATE" in
      no-link)
        BUF+="  ${DIM}(no runs yet — waiting for first call)${RESET}"$'\n'
        BUF+="  ${DIM}path: $LATEST_SHOWN${RESET}"$'\n\n'
        ;;
      dangling)
        BUF+="  ${YELLOW}latest link points at a missing log${RESET}"$'\n'
        BUF+="  ${DIM}target: ${STATE_DETAIL}${RESET}"$'\n\n'
        ;;
      oversized)
        BUF+="  ${YELLOW}${STATE_DETAIL} is too large to render safely${RESET}"$'\n'
        BUF+="  ${DIM}open the files directly; the dashboard will not load them${RESET}"$'\n\n'
        ;;
      unreadable)
        BUF+="  ${YELLOW}run metadata unreadable — this run cannot be described${RESET}"$'\n'
        BUF+="  ${DIM}file: $(basename "$(runstate_path "$SOURCE")" | sanitize_line 60)${RESET}"$'\n\n'
        ;;
      mismatch)
        BUF+="  ${YELLOW}run metadata does not describe this log${RESET}"$'\n'
        BUF+="  ${DIM}${STATE_DETAIL}${RESET}"$'\n\n'
        ;;
      legacy)
        # No metadata: the only trustworthy value left is the path itself, so
        # take the start time from the filename stem and claim nothing else.
        REAL=$(basename "$SOURCE")
        TS=""
        case "$REAL" in
          "$ROLE"-*.log)
            TS="${REAL#"$ROLE"-}"
            TS="${TS%.log}"
            ;;
        esac
        BUF+="  ${BOLD}Started:${RESET} $(printf '%s' "${TS:-unknown}" | sanitize_line 40)"$'\n'
        BUF+="  ${DIM}(legacy log — no run metadata; model, ${LABEL} and completion unavailable)${RESET}"$'\n\n'
        ;;
      running|done)
        TS=$(printf '%s\n' "$RUN_JSON" | jq -r '.started_display' | sanitize_line 40)
        BUF+="  ${BOLD}Started:${RESET} ${TS}"$'\n\n'

        BODY=$(printf '%s\n' "$RUN_JSON" \
          | jq -r '(.inputs // []) | map(select(.kind == "focus" or .kind == "question")) | .[0].value // ""' \
          | sanitize_block)
        BUF+="  ${BOLD}${LABEL}:${RESET}"$'\n'
        if [ -n "$BODY" ]; then
          append_block "    " "$BODY" 5
        fi
        REFS=$(printf '%s\n' "$RUN_JSON" \
          | jq -r '(.inputs // []) | map(select(.path != null)) | .[] | "\(.kind): \(.path)"' 2>/dev/null)
        if [ -n "$REFS" ]; then
          shown=0
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            shown=$((shown + 1))
            if [ "$shown" -gt 6 ]; then
              BUF+="    ${DIM}+ … more referenced files${RESET}"$'\n'
              break
            fi
            BUF+="    ${DIM}+ $(printf '%s' "$line" | sanitize_line $((WRAP_W - 6)))${RESET}"$'\n'
          done <<< "$REFS"
        fi
        BUF+=$'\n'

        if [ "$STATE" = "running" ]; then
          BUF+="  ${BOLD}Status:${RESET} ${YELLOW}⏳ running — no completion recorded yet${RESET}"$'\n\n'
        else
          RC=$(printf '%s\n' "$RUN_JSON" | jq -r '.completion.exit_code')
          REASON=$(printf '%s\n' "$RUN_JSON" | jq -r '.completion.reason // "ok"' | sanitize_line 40)
          if [ "$RC" = "0" ]; then
            BUF+="  ${BOLD}Status:${RESET} ${GREEN}✓ done${RESET}"$'\n\n'
          else
            BUF+="  ${BOLD}Status:${RESET} ${RED}✗ failed (rc=$RC)${RESET}"
            [ "$REASON" = "ok" ] || [ "$REASON" = "failed" ] || BUF+=" ${DIM}(${REASON})${RESET}"
            BUF+=$'\n\n'
          fi
        fi

        # ── Role-specific summary ──────────────────────────────────────────
        # The metadata says which artifacts this run has; where they are is not
        # its call. Every wrapper writes them beside the log under the same
        # stem, so derive them from the log this frame is pinned to and open
        # nothing the metadata names. Comparing its paths as strings instead
        # would drop an answer whenever the two processes spell one directory
        # differently — /var against /private/var is enough.
        STEM="${SOURCE%.log}"
        FINAL_PATH=""
        RESULT_PATH=""
        [ "$(printf '%s\n' "$RUN_JSON" | jq -r 'if .final_path  == null then 0 else 1 end')" = "0" ] \
          || FINAL_PATH="$STEM.final.md"
        [ "$(printf '%s\n' "$RUN_JSON" | jq -r 'if .result_path == null then 0 else 1 end')" = "0" ] \
          || RESULT_PATH="$STEM.review.json"

        if [ "$ROLE" = "agy" ] && [ "$STATE" = "done" ]; then
          ANSWER=""
          ANSWER_PARTIAL=0
          if [ -n "$FINAL_PATH" ]; then
            ANSWER_READ_RC=0
            read_bounded "$FINAL_PATH" "$ANSWER_SCAN_BYTES" "$ANSWER_SNAP" || ANSWER_READ_RC=$?
            # An answer, unlike a document, is still useful truncated: rc 2
            # leaves the prefix and only marks the citation count partial. rc 1
            # is no answer at all — the source vanished or stopped being a
            # readable regular file between frames — and must not be rendered.
            case "$ANSWER_READ_RC" in
              0) ANSWER=$(sanitize_block < "$ANSWER_SNAP") ;;
              2) ANSWER_PARTIAL=1; ANSWER=$(sanitize_block < "$ANSWER_SNAP") ;;
            esac
          fi
          if [ -z "$ANSWER" ]; then
            BUF+="  ${YELLOW}No answer captured — see the full log.${RESET}"$'\n'
            BUF+="  ${BOLD}Sources cited:${RESET} —"$'\n\n'
          else
            # Lead: the answer's first non-empty paragraph, as written.
            LEAD=$(printf '%s\n' "$ANSWER" | awk '
              /[^[:space:]]/ { started=1; print; next }
              started { exit }
            ')
            if [ -n "$LEAD" ]; then
              BUF+="  ${BOLD}Answer (lead):${RESET}"$'\n'
              append_block "    " "$LEAD" 8
              BUF+=$'\n'
            fi
            # Distinct citations, not lines containing a URL: two links on one
            # line are two, and the same link twice is one.
            SRC_COUNT=$(printf '%s\n' "$ANSWER" \
              | grep -oE 'https?://[^[:space:]<>")'"'"']+' \
              | sed 's/[.,;:)]*$//' \
              | sort -u | grep -c . )
            SRC_COUNT=${SRC_COUNT//[^0-9]/}; SRC_COUNT=${SRC_COUNT:-0}
            if [ "$ANSWER_PARTIAL" = "1" ]; then
              BUF+="  ${BOLD}Sources cited:${RESET} ${SRC_COUNT} unique ${DIM}(first ${ANSWER_SCAN_KB}KB only)${RESET}"$'\n\n'
            else
              BUF+="  ${BOLD}Sources cited:${RESET} ${SRC_COUNT} unique"$'\n\n'
            fi
          fi

        elif [ "$ROLE" = "codex" ] && [ "$STATE" = "done" ]; then
          RESULT_JSON=""
          if [ -n "$RESULT_PATH" ] && read_bounded "$RESULT_PATH" "$MAX_DOC_BYTES" "$RESULT_SNAP"; then
            RESULT_JSON=$(review_result_read "$RESULT_SNAP") || RESULT_JSON=""
          fi
          if [ -z "$RESULT_JSON" ]; then
            BUF+="  ${YELLOW}Review result unavailable — verdict and findings unknown.${RESET}"$'\n'
          elif [ "$(printf '%s\n' "$RESULT_JSON" | jq -r '.status')" != "ok" ]; then
            ERROR=$(printf '%s\n' "$RESULT_JSON" | jq -r '.error' | sanitize_line $((WRAP_W - 18)))
            BUF+="  ${RED}Review failed: $ERROR${RESET}"$'\n'
          else
            VERDICT_LINE=$(printf '%s\n' "$RESULT_JSON" | jq -r '.verdict_line' | sanitize_block)
            VERB=$(printf '%s\n' "$RESULT_JSON" | jq -r '.verdict' | sanitize_line 16)
            VC="$DIM"
            case "$VERB" in
              SHIP) VC="$GREEN" ;;
              NEEDS-FIX|OUT-OF-SCOPE) VC="$RED" ;;
              DISCUSS) VC="$YELLOW" ;;
            esac
            VWRAP=$(printf '%s\n' "$VERDICT_LINE" | fold -s -w $((WRAP_W - 8)) | head -6)
            FIRST=1
            while IFS= read -r line; do
              if [ "$FIRST" = "1" ]; then
                BUF+="  ${VC}┃${RESET} ${BOLD}Verdict:${RESET} $line"$'\n'
                FIRST=0
              else
                BUF+="  ${VC}┃${RESET}   $line"$'\n'
              fi
            done <<< "$VWRAP"
            BUF+=$'\n'
            BL=$(printf '%s\n' "$RESULT_JSON" | jq -r '.findings.blocker | if . == null then "?" else length end')
            MJ=$(printf '%s\n' "$RESULT_JSON" | jq -r '.findings.major | if . == null then "?" else length end')
            MN=$(printf '%s\n' "$RESULT_JSON" | jq -r '.findings.minor | if . == null then "?" else length end')
            BUF+="  ${BOLD}Findings:${RESET} ${RED}${BL} blocker${RESET} · ${YELLOW}${MJ} major${RESET} · ${DIM}${MN} minor${RESET}"$'\n\n'
            if [ "$BL" = "?" ] || [ "$MJ" = "?" ] || [ "$MN" = "?" ]; then
              BUF+="  ${DIM}? = section missing; count unknown${RESET}"$'\n'
            fi
            BLMJ=$(printf '%s\n' "$RESULT_JSON" \
              | jq -r '((.findings.blocker // []) + (.findings.major // []))[]' \
              | sanitize_block)
            if [ -n "$BLMJ" ]; then
              BUF+="  ${BOLD}${RED}Blockers + Major:${RESET}"$'\n'
              append_block "    " "$BLMJ" 40
              BUF+=$'\n'
            fi
          fi
        fi

        BUF+="  ${DIM}log: $(basename "$SOURCE" | sanitize_line 60)${RESET}"$'\n'
        ;;
    esac

    if [ "$STATE" = "legacy" ]; then
      BUF+="  ${DIM}log: $(basename "$SOURCE" | sanitize_line 60)${RESET}"$'\n'
    fi

    # Bottom control hint
    BUF+=$'\n'
    BUF+="  ${DIM}controls: ${BOLD}l${RESET}${DIM}=full log · ${BOLD}space${RESET}${DIM}=pause · ${BOLD}q${RESET}${DIM}=quit${RESET}"$'\n'

    # Flicker-free render: only redraw if content changed.
    HASH=$(printf '%s' "$BUF" | cksum 2>/dev/null | awk '{print $1}')
    if [ "$HASH" != "$LAST_HASH" ]; then
      RENDERED="${BUF//$'\n'/$'\033[K\n'}"
      printf '\033[H%s\033[J' "$RENDERED"
      LAST_HASH="$HASH"
    fi
  fi

  [ "$ONCE" = "1" ] && { printf '\033[?25h'; exit 0; }

  # Wait up to 1s for a keypress (also the polling cadence). On bash 3.2 `read`
  # returns 1 for a timeout AND for EOF, so the return code cannot tell them
  # apart — a closed or redirected stdin would spin this loop at full speed.
  #
  # Tell them apart by how long the read took instead. A timeout costs about a
  # second, so the clock moves; at EOF the read returns at once, over and over.
  # A terminal never reaches EOF, so it is never a candidate. Treating any empty
  # failed read as EOF would be wrong the other way: a pipe that is open but
  # quiet — a driver that sends a key after a few seconds — would be abandoned
  # after the first idle second.
  KEY=""
  if [ "$STDIN_LIVE" = "1" ]; then
    _tick=$SECONDS
    if ! IFS= read -rs -t 1 -n 1 KEY 2>/dev/null; then
      if [ -z "$KEY" ] && [ ! -t 0 ] && [ "$SECONDS" = "$_tick" ]; then
        STDIN_INSTANT=$((STDIN_INSTANT + 1))
        [ "$STDIN_INSTANT" -lt 5 ] || STDIN_LIVE=0
      else
        STDIN_INSTANT=0
      fi
    else
      STDIN_INSTANT=0
    fi
  else
    sleep 1
  fi
  case "$KEY" in
    l)
      printf '\033[?25h\033[H\033[2J'
      if [ -e "$LATEST" ]; then
        less -R "$LATEST" || true
      else
        echo "(no log yet — waiting for first call)"; sleep 1
      fi
      printf '\033[?25l'
      LAST_HASH=""   # force redraw on return
      ;;
    ' ')
      if [ "$PAUSED" = "0" ]; then
        PAUSED=1
        printf "\n  %s[PAUSED]%s press space to resume — Ctrl-b [ to scroll\n" "$YELLOW" "$RESET"
        printf '\033[?25h'
      else
        PAUSED=0
        printf '\033[?25l'
        LAST_HASH=""   # force redraw
      fi
      ;;
    q) cleanup ;;
  esac
done
