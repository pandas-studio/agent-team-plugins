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
      terminal_handle:$handle,tail_commands:$context.tail_commands,
      user_message:(if $status == "attached" then "Live view is attached. " + $reason
        elif $status == "launch-requested" then $reason
        elif $context.status == "ready-detached" then
          "Automatic window opening was not completed: " + $reason +
          "\nThe background view remains ready. In another terminal on the same machine/user, run:\n" + $context.attach_command
        else $context.user_message end)}'
}
fail() { emit "${3:-open-failed}" "$1" "$2"; exit 2; }
[ "$(printf '%s' "$DATA" | jq -r .status)" = ready-detached ] || fail 'No detached view was prepared; prepare --view-only first.' no-view manual
VIEW_TMUX=$(printf '%s' "$DATA" | jq -r .tmux_bin)
VIEW_SOCKET=$(printf '%s' "$DATA" | jq -r .socket)
SESSION=$(printf '%s' "$DATA" | jq -r .session)
TARGET="=$SESSION"
record=$(view_record "$TARGET:") || fail 'Cannot reach the prepared tmux view.' setup-failed
view_record_matches "$record" "$(printf '%s' "$DATA" | jq -r .team)" "$(printf '%s' "$DATA" | jq -r .log_dir)" &&
  [ "$(printf '%s' "$record" | jq -r .type)" = detached ] &&
  view_complete "$TARGET:" "$record" &&
  view_geometry_matches "$TARGET:" "$record" || fail 'View identity or geometry changed; prepare it again.' changed-view
owner=$(view_tmux show-options -qv -t "$TARGET:" @debate-view-owner) || fail 'Cannot verify ownership.' changed-view
case "$owner" in debate-conductor-v1:*) ;; *) fail 'Unmanaged session.' changed-view ;; esac
view_wait_ready "$record" || fail 'Viewers are not ready; prepare the view again.' not-ready
clients=$(view_tmux list-clients -t "$TARGET" -F '#{client_name}') || fail 'Cannot inspect attached clients.' setup-failed
if [ -n "$clients" ]; then emit attached 'A client is already attached; no duplicate window opened.' ''; exit 0; fi
[ "$(uname -s)" = Darwin ] && [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || fail 'Open a terminal on the same machine/user and use attach_command.' unsupported-host

chosen=$(view_select_terminal "$TERMINAL") || fail 'Ghostty >=1.3 with AppleScript support is required.' unsupported-terminal
TERMINAL=$chosen
if [ "$TERMINAL" = ghostty ]; then
  SCRIPT="$SCRIPT_DIR/../lib/open-ghostty.applescript"
else
  [ -d /System/Applications/Utilities/Terminal.app ] || fail 'Terminal.app is unavailable.' unsupported-terminal
  SCRIPT="$SCRIPT_DIR/../lib/open-terminal.applescript"
fi
command -v osascript >/dev/null || fail 'osascript is unavailable.' unsupported-host
CMD="/usr/bin/env -u TMUX -u TMUX_PANE $(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") attach-session -t $(view_quote "$TARGET")"
# Ghostty's macOS .shell launcher already prepends `exec -l` (v1.3.1
# src/termio/Exec.zig). It needs an executable, not another exec builtin.
[ "$TERMINAL" = ghostty ] || CMD="exec $CMD"
umask 077
ERR=$(mktemp "${CONTEXT%/*}/open-error.XXXXXX")
OUT=$(mktemp "${CONTEXT%/*}/open-output.XXXXXX")
pid=""
trap '[ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; rm -f "$ERR" "$OUT"' EXIT
osascript "$SCRIPT" "$CMD" "$(printf '%s' "$DATA" | jq -r .cwd)" >"$OUT" 2>"$ERR" &
pid=$!
# First Automation consent/cold start may take time. The host tool bounds this
# call; only the AFTER-launch attachment poll is five seconds. Never kill an
# in-flight Apple Event after five seconds and misreport a queued window.
rc=0
wait "$pid" || rc=$?
pid=""
HANDLE=$(cat "$OUT")
code="" reason=""
if [ "$rc" != 0 ]; then
  reason=$(cat "$ERR")
  code=open-failed
  case "$reason" in *-1743*|*'not authorized to send Apple events'*) code=automation-denied ;;
    *'Operation not permitted'*|*'Permission denied'*|*'hiservices-xpcservice'*) code=sandbox-denied ;;
    *-1712*|*'AppleEvent timed out'*) code=automation-timeout ;;
  esac
  # Activation may fail after a client already attached: inspect before
  # reporting failure. A native Apple Event timeout may still complete later.
  clients=$(view_tmux list-clients -t "$TARGET" -F '#{client_name}' 2>/dev/null) || clients=""
  if [ -n "$clients" ]; then emit attached 'Terminal client attachment verified.' ''; exit 0; fi
  [ "$code" = automation-timeout ] || fail "$reason" "$code"
fi
deadline=$((SECONDS + 5))
while [ "$SECONDS" -lt "$deadline" ]; do
  clients=$(view_tmux list-clients -t "$TARGET" -F '#{client_name}' 2>/dev/null) || clients=""
  if [ -n "$clients" ]; then emit attached 'Terminal client attachment verified.' ''; exit 0; fi
  sleep 0.1
done
if [ "$code" = automation-timeout ]; then
  emit launch-requested 'Automation consent may still be pending; the window may appear later. Check the new window/client before attempting another attachment.' automation-timeout
else
  emit launch-requested 'Window launch requested; tmux attachment is unconfirmed. Check the new window before attempting another attachment.' attachment-unconfirmed
fi
