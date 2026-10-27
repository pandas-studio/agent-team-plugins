#!/usr/bin/env bash
# Claude host-visible viewing notice, not a permission or security boundary.
# Skill hooks persist for the session; ignore everything except debate dispatch.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
input=$(cat) || exit 0
command=$(jq -r '.tool_input.command // ""' <<<"$input") || exit 0
[[ $(jq -r '.tool_name // ""' <<<"$input") == Bash ]] || exit 0
. "$ROOT/lib/view.sh"
# Match an actual runner first token, not grep/cat/echo mentioning the runner.
command="${command#"${command%%[![:space:]]*}"}"
case "$command" in
  run-debate.sh\ *|"$ROOT/bin/run-debate.sh"\ *|"$(view_quote "$ROOT/bin/run-debate.sh")"\ *|\""$ROOT/bin/run-debate.sh"\"\ *) ;;
  *) exit 0 ;;
esac
[[ $command == *--host=* ]] || exit 0
context_ids=$(jq -cn --arg command "$command" \
  '[$command | scan("debate-view-context\\.[A-Za-z0-9]+")] | unique') || exit 0
transcript=$(jq -r '.transcript_path // ""' <<<"$input") || exit 0
if [[ -f $transcript && ! -L $transcript && -r $transcript ]]; then
  if result=$(jq -ncR --argjson ids "$context_ids" -f "$ROOT/lib/view-message.jq" "$transcript") &&
      [[ $(jq -r 'type' <<<"$result") == object ]]; then
    # No permissionDecision: the normal host permission checks still apply.
    jq -n --arg message "$(jq -r '.user_message' <<<"$result")" '{systemMessage:$message}'
    exit 0
  fi
fi
# This is only a redundant host notice. Missing/unreadable/compacted transcript
# must never block inference; the skill still sends its ordinary chat message.
exit 0
