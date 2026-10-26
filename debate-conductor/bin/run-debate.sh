#!/usr/bin/env bash
# Skill dispatch boundary: no environment assignments in the host Bash rule.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/view.sh"
. "$SCRIPT_DIR/../lib/debate-result.sh"

usage() {
  echo 'Usage: run-debate.sh --host=claude|codex --context FILE [--continue-from ABS] -- ENGINE_ARGS...'
  echo '       run-debate.sh --read-receipt --context FILE'
}
HOST=claude CONTEXT="" CONTINUE="" READ=0
seen=" "
while [ "$#" -gt 0 ]; do
  key=${1%%=*}
  case "$key" in
    --context|--host|--continue-from|--read-receipt)
      case "$seen" in *" $key "*) view_error "duplicate $key"; exit 2 ;; esac
      seen="$seen$key " ;;
  esac
  case "$1" in
    --context) CONTEXT="${2:?--context needs a file}"; shift 2 ;;
    --host=*) HOST=${1#*=}; shift ;;
    --continue-from) CONTINUE="${2:?--continue-from needs a directory}"; shift 2 ;;
    --read-receipt) READ=1; shift ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$HOST" in claude|codex) ;; *) view_error 'invalid PM host'; exit 2 ;; esac
DATA=$(view_context_read "$CONTEXT") || exit 2
DIR=${CONTEXT%/*}
RECEIPT="$DIR/receipt.json"
if [ "$READ" = 1 ]; then
  [ "$#" = 0 ] && [ -z "$CONTINUE" ] || { usage >&2; exit 2; }
  [ ! -L "$DIR/dispatch.started" ] && [ -d "$DIR/dispatch.started" ] &&
    view_private_file "$DIR/dispatch-status.json" &&
    jq -e '.exit_code == 0' "$DIR/dispatch-status.json" >/dev/null &&
    view_private_file "$RECEIPT" || { view_error 'incomplete dispatch or missing receipt'; exit 2; }
  RESULT=$(debate_receipt_read "$RECEIPT") || { view_error 'invalid receipt'; exit 2; }
  [ "$(printf '%s' "$RESULT" | jq -r '.debate_dir | split("/") | .[:-1] | join("/")')" = "$(printf '%s' "$DATA" | jq -r .log_dir)" ] || {
    view_error 'receipt does not belong to the prepared log directory'; exit 2; }
  printf '%s\n' "$RESULT"
  exit 0
fi
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
# Intentionally reject reserved tokens even in a value position. Do not turn
# this into position-aware parsing: debate.sh accepts flags at any position.
for arg in "$@"; do
  case "$arg" in --continue-from|--continue-from=*) view_error 'use the runner continuation option, never a forwarded --continue-from'; exit 2 ;; esac
done
KIND=$(printf '%s' "$DATA" | jq -r .kind)
LOG_DIR=$(printf '%s' "$DATA" | jq -r .log_dir)
ARGS=("$@")
if [ -n "$CONTINUE" ]; then
  case "$CONTINUE" in /*) ;; *) view_error 'continuation must be absolute'; exit 2 ;; esac
  CONTINUE=$(cd "$CONTINUE" && pwd -P) || exit 2
  [ "${CONTINUE%/*}" = "$LOG_DIR" ] || { view_error 'continuation is outside the prepared log directory'; exit 2; }
  ARGS=(--continue-from "$CONTINUE" "$@")
elif [ "$KIND" = log-dir ]; then
  view_error 'raw log-directory contexts are continuation-only'; exit 2
fi
umask 077
mkdir "$DIR/dispatch.started" 2>/dev/null || { view_error 'context has already been dispatched; prepare a fresh context for a retry'; exit 2; }
if [ "$KIND" = team ]; then
  AGENT_TEAM=$(printf '%s' "$DATA" | jq -r .team)
  DEBATE_LOG_DIR=$(printf '%s' "$DATA" | jq -r .log_base)
  export AGENT_TEAM DEBATE_LOG_DIR
fi
export DEBATE_RECEIPT="$RECEIPT" DEBATE_CONDUCTOR_PM_HOST="$HOST"
cd "$(printf '%s' "$DATA" | jq -r .cwd)"
child=""
stop_dispatch() {
  local status="$1"
  trap '' INT TERM
  # Asynchronous children can inherit ignored SIGINT. TERM reaches debate.sh's
  # own cleanup path; wait so a cancelled PM tool does not orphan a paid round.
  if [ -n "$child" ]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  exit "$status"
}
trap 'stop_dispatch 143' TERM
trap 'stop_dispatch 130' INT
"$SCRIPT_DIR/debate.sh" "${ARGS[@]}" <&0 &
child=$!
rc=0
wait "$child" || rc=$?
child=""
tmp=$(mktemp "$DIR/dispatch-status.XXXXXX")
jq -cn --argjson rc "$rc" '{exit_code:$rc}' > "$tmp"
mv "$tmp" "$DIR/dispatch-status.json"
exit "$rc"
