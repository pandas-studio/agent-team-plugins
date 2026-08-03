#!/usr/bin/env bash
# dashboard.sh — minimal live view for a ralph run.
#
# Usage:
#   dashboard.sh                # auto-detect: tail latest-ralph.log
#   dashboard.sh solo|trio|debate
#
# This is a thin wrapper around `tail -F` with a colored header. The dev-trio
# plugin's dashboard.sh is structured around agy/codex roles and hardcodes
# those names — it doesn't render ralph logs. Use that one for the trio
# variant's inner ask-codex/ask-agy calls; use this one for the ralph
# outer-loop summary.
#
# Reads logs from $RALPH_TRIO_WORKSPACE/log/<team>/ (default $PWD/.ralph-trio).
set -uo pipefail

VARIANT="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$PLUGIN_ROOT/lib/common.sh"

TEAM=$(detect_team) || exit 2
LOG_DIR="$(ralph_workspace_root)/log/$TEAM"

case "$VARIANT" in
  ""|any)        TARGET="$LOG_DIR/latest-ralph.log";        TITLE="RALPH (any variant)" ;;
  solo)          TARGET="$LOG_DIR/latest-ralph-solo.log";   TITLE="RALPH-SOLO" ;;
  trio)          TARGET="$LOG_DIR/latest-ralph-trio.log";   TITLE="RALPH-TRIO" ;;
  debate)        TARGET="$LOG_DIR/latest-ralph-debate.log"; TITLE="RALPH-DEBATE" ;;
  *)             echo "usage: $0 [solo|trio|debate|any]" >&2; exit 2 ;;
esac

CYAN=$'\033[1;36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
printf '%s═══════════════════════════════════════════════%s\n' "$CYAN" "$RESET"
printf '%s  %s%s  %s[team: %s]%s\n' "$CYAN" "$TITLE" "$RESET" "$DIM" "$TEAM" "$RESET"
printf '%s═══════════════════════════════════════════════%s\n' "$CYAN" "$RESET"
printf '  log: %s\n' "$TARGET"
printf '  %s(Ctrl-C to exit)%s\n\n' "$DIM" "$RESET"

if [ ! -e "$TARGET" ]; then
  printf '  %s(no runs yet — waiting for first call)%s\n' "$DIM" "$RESET"
  while [ ! -e "$TARGET" ]; do sleep 1; done
fi

exec tail -F "$TARGET"
