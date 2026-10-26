#!/usr/bin/env bash
# Attach a prepared view in a new local terminal; never launch a debate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/view.sh"
CONTEXT="" TERMINAL=auto seen=" "
while [ "$#" -gt 0 ]; do
  key=${1%%=*}
  case "$seen" in *" $key "*) view_error "duplicate $key"; exit 2 ;; esac
  seen="$seen$key "
  case "$1" in
    --context) CONTEXT="${2:?--context needs a file}"; shift 2 ;;
    --terminal=*) TERMINAL=${1#*=}; shift ;;
    -h|--help) echo 'Usage: open-view.sh --context FILE [--terminal=auto|ghostty|terminal]'; exit 0 ;;
    *) view_error "unknown argument $1"; exit 2 ;;
  esac
done
case "$TERMINAL" in auto|ghostty|terminal) ;; *) view_error 'invalid terminal'; exit 2 ;; esac
DATA=$(view_context_read "$CONTEXT") || exit 2
HANDLE=""
emit() {
  jq -cn --arg status "$1" --arg reason "$2" --arg code "$3" --arg terminal "$TERMINAL" \
    --arg handle "$HANDLE" --argjson context "$DATA" '{status:$status,reason:$reason,reason_code:$code,
      terminal:$terminal,context_file:$context.context_file,attach_command:$context.attach_command,
      terminal_handle:$handle,tail_commands:$context.tail_commands}'
}
fail() { emit manual "$1" "$2"; exit 2; }
[ "$(printf '%s' "$DATA" | jq -r .status)" = ready-detached ] || fail 'No detached view was prepared; prepare --view-only first.' no-view
VIEW_TMUX=$(printf '%s' "$DATA" | jq -r .tmux_bin)
VIEW_SOCKET=$(printf '%s' "$DATA" | jq -r .socket)
SESSION=$(printf '%s' "$DATA" | jq -r .session)
TARGET="=$SESSION"
record=$(view_record "$TARGET:") || fail 'Cannot reach the prepared tmux view.' setup-failed
view_record_matches "$record" "$(printf '%s' "$DATA" | jq -r .team)" "$(printf '%s' "$DATA" | jq -r .log_dir)" &&
  [ "$(printf '%s' "$record" | jq -r .type)" = detached ] &&
  view_geometry_matches "$TARGET:" "$record" || fail 'View identity or geometry changed; prepare it again.' changed-view
owner=$(view_tmux show-options -qv -t "$TARGET:" @debate-view-owner) || fail 'Cannot verify ownership.' changed-view
case "$owner" in debate-conductor-v1:*) ;; *) fail 'Unmanaged session.' changed-view ;; esac
view_wait_ready "$record" || fail 'Viewers are not ready; prepare the view again.' not-ready
clients=$(view_tmux list-clients -t "$TARGET" -F '#{client_name}') || fail 'Cannot inspect attached clients.' setup-failed
if [ -n "$clients" ]; then emit attached 'A client is already attached; no duplicate window opened.' ''; exit 0; fi
[ "$(uname -s)" = Darwin ] && [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || fail 'Open a terminal on the same machine/user and use attach_command.' unsupported-host

ghostty_supported() {
  local version major minor
  [ -d /Applications/Ghostty.app ] || return 1
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Ghostty.app/Contents/Info.plist 2>/dev/null) || return 1
  if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
    [ "$major" -gt 1 ] || { [ "$major" = 1 ] && [ "$minor" -ge 3 ]; }
  else return 1; fi
}
if [ "$TERMINAL" = auto ]; then
  term=${TERM_PROGRAM:-}
  if [ -n "${TMUX:-}" ]; then
    term=$(view_tmux list-clients -F '#{client_termname} #{client_termtype}' 2>/dev/null | sort -u) || term=""
    # A generic or ambiguous terminal identity is never guessed as Ghostty.
    if [ "$(printf '%s\n' "$term" | wc -l | tr -d ' ')" != 1 ]; then term=""; fi
  fi
  case "$term" in *ghostty*|*Ghostty*) if ghostty_supported; then TERMINAL=ghostty; else TERMINAL=terminal; fi ;;
    *) TERMINAL=terminal ;;
  esac
fi
if [ "$TERMINAL" = ghostty ]; then
  ghostty_supported || fail 'Ghostty >=1.3 with AppleScript support is required.' unsupported-terminal
  SCRIPT="$SCRIPT_DIR/../lib/open-ghostty.applescript"
else
  [ -d /System/Applications/Utilities/Terminal.app ] || fail 'Terminal.app is unavailable.' unsupported-terminal
  SCRIPT="$SCRIPT_DIR/../lib/open-terminal.applescript"
fi
command -v osascript >/dev/null || fail 'osascript is unavailable.' unsupported-host
CMD="exec /usr/bin/env -u TMUX -u TMUX_PANE $(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") attach-session -t $(view_quote "$TARGET")"
umask 077
ERR=$(mktemp "${CONTEXT%/*}/open-error.XXXXXX")
OUT=$(mktemp "${CONTEXT%/*}/open-output.XXXXXX")
pid=""
trap '[ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; rm -f "$ERR" "$OUT"' EXIT
osascript "$SCRIPT" "$CMD" "$(printf '%s' "$DATA" | jq -r .cwd)" >"$OUT" 2>"$ERR" &
pid=$!
deadline=$((SECONDS + 5))
while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
  fail 'Terminal opening timed out; use attach_command.' open-timeout
fi
rc=0
wait "$pid" || rc=$?
pid=""
if [ "$rc" != 0 ]; then
  reason=$(cat "$ERR")
  code=open-failed
  case "$reason" in *-1743*|*'not authorized to send Apple events'*) code=automation-denied ;;
    *'Operation not permitted'*|*'Permission denied'*|*'hiservices-xpcservice'*) code=sandbox-denied ;;
  esac
  fail "$reason" "$code"
fi
HANDLE=$(cat "$OUT")
deadline=$((SECONDS + 5))
while [ "$SECONDS" -lt "$deadline" ]; do
  clients=$(view_tmux list-clients -t "$TARGET" -F '#{client_name}' 2>/dev/null) || clients=""
  if [ -n "$clients" ]; then emit attached 'Terminal client attachment verified.' ''; exit 0; fi
  sleep 0.1
done
emit launch-requested 'Window launch requested; tmux attachment is unconfirmed. Use attach_command if needed.' attachment-unconfirmed
