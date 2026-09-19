#!/usr/bin/env bash
# dashboard.sh — live, formatted summary view of researcher/reviewer runs.
#
# Usage:
#   dashboard.sh agy       # render researcher status
#   dashboard.sh codex     # render reviewer status
#
# `agy` and `codex` are compatibility identifiers for the two log channels
# (agy-*.log, codex-*.log), not the model that runs — the header shows that.
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

ROLE="${1:?usage: $0 agy|codex}"

case "$ROLE" in
  agy)
    ICON="🔍"; TITLE="Researcher"
    WRAPPER="ask-researcher.sh"; WRAPPER_LEGACY="ask-agy.sh"
    HEADER_COLOR=$'\033[1;36m'   # bright cyan
    LABEL="Query"
    ;;
  codex)
    ICON="🧐"; TITLE="Reviewer"
    WRAPPER="ask-reviewer.sh"; WRAPPER_LEGACY="ask-codex.sh"
    HEADER_COLOR=$'\033[1;35m'   # bright magenta
    LABEL="Focus"
    ;;
  *)
    echo "usage: $0 agy|codex" >&2; exit 2 ;;
esac

# Team namespace — must match what wrappers use.
TEAM=$(agent_team_detect_team) || exit 2
LOG_DIR="${DEV_TRIO_LOG_DIR:-$PWD/.dev-trio/log}/$TEAM"
LATEST="$LOG_DIR/latest-$ROLE.log"

RESET=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'

cleanup() { printf '\033[?25h\033[H\033[2J'; exit 0; }   # show cursor + clear
trap cleanup INT TERM
printf '\033[?25l'   # hide cursor

get_wrap_width() {
  local c
  c=$(tput cols 2>/dev/null || echo 80)
  [ "$c" -lt 40 ] && c=40
  echo $((c - 6))
}

LAST_HASH=""
PAUSED=0

while true; do
  if [ "$PAUSED" = "0" ]; then
    WRAP_W=$(get_wrap_width)
    # Freeze the latest log target for this frame. Every sibling artifact is
    # resolved from this path, never from an independently changing latest link.
    SOURCE="$LATEST"
    if [ -L "$LATEST" ]; then
      TARGET=$(readlink "$LATEST" 2>/dev/null) || TARGET=""
      case "$TARGET" in
        /*) SOURCE="$TARGET" ;;
        *) SOURCE="$LOG_DIR/$TARGET" ;;
      esac
    fi
    MODEL=""
    if [ -f "$SOURCE" ]; then
      MODEL=$(sed -n 's/^=== MODEL: \(.*\) ===$/\1/p' "$SOURCE" | head -1)
    fi
    BUF=""
    BUF+="${HEADER_COLOR}═══════════════════════════════════════════════${RESET}"$'\n'
    BUF+="${HEADER_COLOR}  ${ICON}  ${TITLE}${MODEL:+ · $MODEL}${RESET}  ${DIM}[team: ${TEAM}]${RESET}"$'\n'
    BUF+="${HEADER_COLOR}═══════════════════════════════════════════════${RESET}"$'\n\n'

    if [ ! -e "$SOURCE" ]; then
      BUF+="  ${DIM}(no runs yet — waiting for first call)${RESET}"$'\n'
      BUF+="  ${DIM}path: $LATEST${RESET}"$'\n\n'
    else
      # The wrapper writes its authoritative header as the log's first line,
      # one run per file — so read that line and match it literally, rather
      # than searching the body where research context can quote a header.
      # The legacy spelling is accepted so logs written by a pre-0.7.0
      # dev-trio still render a start time.
      HEADER=$(head -1 "$SOURCE" 2>/dev/null)
      TS=""
      case "$HEADER" in
        "=== $WRAPPER @ "*|"=== $WRAPPER_LEGACY @ "*)
          TS=$(printf '%s\n' "$HEADER" | awk '{print $4}') ;;
      esac
      BUF+="  ${BOLD}Started:${RESET} ${TS:-unknown}"$'\n\n'

      # Query/Focus body
      if [ "$ROLE" = "agy" ]; then
        BODY=$(awk '/^=== QUERY ===$/{flag=1; next} /^=== /{flag=0} flag' "$SOURCE" 2>/dev/null)
      else
        BODY=$(awk '/^=== FOCUS ===$/{flag=1; next} /^=== /{flag=0} flag' "$SOURCE" 2>/dev/null)
      fi
      BUF+="  ${BOLD}${LABEL}:${RESET}"$'\n'
      if [ -n "$BODY" ]; then
        WRAPPED=$(echo "$BODY" | fold -s -w "$WRAP_W" | head -5)
        while IFS= read -r line; do BUF+="    $line"$'\n'; done <<< "$WRAPPED"
      fi
      BUF+=$'\n'

      RESPONSE=""
      RESULT_JSON=""
      if [ "$ROLE" = "agy" ]; then
        RESPONSE=$(awk '/^=== RESPONSE ===$/{flag=1; next} /^=== END /{flag=0} flag' "$SOURCE" 2>/dev/null)
      fi

      # Status (END marker = done)
      DONE=0; RC=""
      if grep -q '^=== END ' "$SOURCE" 2>/dev/null; then
        DONE=1
        RC=$(grep '^=== END ' "$SOURCE" | tail -1 | sed 's/.*rc=\([0-9]*\).*/\1/')
        # END is published after the result; read in that order to avoid a
        # transient missing-result frame when completion races this refresh.
        if [ "$ROLE" = "codex" ]; then
          RESULT_JSON=$(review_result_read "${SOURCE%.log}.review.json") || RESULT_JSON=""
        fi
        if [ "$ROLE" = "codex" ] && [ -n "$RESULT_JSON" ]; then
          RC=$(printf '%s\n' "$RESULT_JSON" | jq -r '.exit_code')
        fi
        if [ "$RC" = "0" ]; then
          BUF+="  ${BOLD}Status:${RESET} ${GREEN}✓ done${RESET}"$'\n\n'
        else
          BUF+="  ${BOLD}Status:${RESET} ${RED}✗ failed (rc=$RC)${RESET}"$'\n\n'
        fi
      else
        BUF+="  ${BOLD}Status:${RESET} ${YELLOW}⏳ running...${RESET}"$'\n\n'
      fi

      # ── Role-specific summary ────────────────────────────────────────────
      if [ "$ROLE" = "agy" ] && [ "$DONE" = "1" ]; then
        # Lead: first paragraph of answer (skip Antigravity CLI preamble lines)
        LEAD=$(echo "$RESPONSE" | awk '
          BEGIN { started=0 }
          /^Ripgrep|^Falling back/ { next }
          /^[^[:space:]]/ {
            if (!started) started=1
            if (started) print
          }
          started && /^$/ { exit }
        ')
        if [ -n "$LEAD" ]; then
          BUF+="  ${BOLD}Answer (lead):${RESET}"$'\n'
          WRAPPED=$(echo "$LEAD" | fold -s -w "$WRAP_W" | head -8)
          while IFS= read -r line; do
            BUF+="    ${line}"$'\n'
          done <<< "$WRAPPED"
          BUF+=$'\n'
        fi

        # Source count (URLs cited)
        SRC_COUNT=$(echo "$RESPONSE" | grep -cE 'https?://' || true)
        SRC_COUNT=${SRC_COUNT//[^0-9]/}; SRC_COUNT=${SRC_COUNT:-0}
        BUF+="  ${BOLD}Sources cited:${RESET} ${SRC_COUNT}"$'\n\n'

      elif [ "$ROLE" = "codex" ] && [ "$DONE" = "1" ]; then
        if [ -z "$RESULT_JSON" ]; then
          BUF+="  ${YELLOW}Review result unavailable — verdict and findings unknown.${RESET}"$'\n'
        elif [ "$(printf '%s\n' "$RESULT_JSON" | jq -r '.status')" != "ok" ]; then
          ERROR=$(printf '%s\n' "$RESULT_JSON" | jq -r '.error')
          BUF+="  ${RED}Review failed: $ERROR${RESET}"$'\n'
        else
          VERDICT_LINE=$(printf '%s\n' "$RESULT_JSON" | jq -r '.verdict_line')
          VERB=$(printf '%s\n' "$RESULT_JSON" | jq -r '.verdict')
          case "$VERB" in
            SHIP) VC="$GREEN" ;;
            NEEDS-FIX|OUT-OF-SCOPE) VC="$RED" ;;
            DISCUSS) VC="$YELLOW" ;;
          esac
          VWRAP=$(printf '%s\n' "$VERDICT_LINE" | fold -s -w $((WRAP_W - 8)))
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
          BLMJ=$(printf '%s\n' "$RESULT_JSON" | jq -r '((.findings.blocker // []) + (.findings.major // []))[]')
          if [ -n "$BLMJ" ]; then
            BUF+="  ${BOLD}${RED}Blockers + Major:${RESET}"$'\n'
            WRAPPED=$(printf '%s\n' "$BLMJ" | fold -s -w "$WRAP_W")
            while IFS= read -r line; do
              [ -n "$line" ] && BUF+="    $line"$'\n'
            done <<< "$WRAPPED"
            BUF+=$'\n'
          fi
        fi
      fi

      REAL=$(basename "$SOURCE")
      BUF+="  ${DIM}log: $REAL${RESET}"$'\n'
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

  # Wait up to 1s for keypress (also serves as the polling cadence).
  KEY=""
  IFS= read -rs -t 1 -n 1 KEY 2>/dev/null || true
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
