#!/usr/bin/env bash
# Host defaults are local to dev-trio; the shared registry remains unchanged.
# Source registry.sh before calling these functions.

dev_trio_host() {
  case "${DEV_TRIO_PM_HOST:-claude}" in
    claude|codex) printf '%s\n' "${DEV_TRIO_PM_HOST:-claude}" ;;
    *) echo 'dev-trio: DEV_TRIO_PM_HOST must be claude or codex' >&2; return 2 ;;
  esac
}

dev_trio_resolve_role() {
  local host
  host="$(dev_trio_host)" || return $?
  if [ "$host" = codex ] && [ "$1" = reviewer ] &&
     [ -z "${DEV_TRIO_REVIEWER_MODEL:-}" ] &&
     [ -z "$(registry_config_role dev-trio.reviewer)" ]; then
    printf 'claude\n'
  else
    registry_resolve_role dev-trio "$1" ""
  fi
}

# Check availability and, for Claude, login. Authentication and billing stay
# under Claude Code's own configuration; both subscription and API auth work.
dev_trio_check_cli() {
  local model="$1" bin auth host
  host="$(dev_trio_host)" || return $?
  [ "$host" = codex ] || return 0
  bin="$(registry_resolve_command "$model")" || return $?
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "dev-trio: CLI not found: $bin (model=$model)" >&2
    return 2
  fi
  case "$model:${bin##*/}" in
    claude:*|claude-write:*|*:claude|*:claude.exe) ;;
    *) return 0 ;;
  esac
  if ! auth="$("$bin" auth status --json 2>/dev/null)"; then
    echo 'dev-trio: could not check Claude login; no invocation started' >&2
    return 2
  fi
  if ! printf '%s' "$auth" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    echo 'dev-trio: Claude login not confirmed; check claude auth status in a terminal (sandbox keychain access may be restricted)' >&2
    return 2
  fi
}
