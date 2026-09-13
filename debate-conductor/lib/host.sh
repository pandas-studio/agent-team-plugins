#!/usr/bin/env bash
# Host defaults are local to debate-conductor; the shared registry remains unchanged.
# Source registry.sh before calling these functions.

debate_conductor_host() {
  case "${DEBATE_CONDUCTOR_PM_HOST:-claude}" in
    claude|codex) printf '%s\n' "${DEBATE_CONDUCTOR_PM_HOST:-claude}" ;;
    *) echo 'debate-conductor: DEBATE_CONDUCTOR_PM_HOST must be claude or codex' >&2; return 2 ;;
  esac
}

debate_conductor_default_role() {
  local role="$1" gen="${2:-}" host
  host="$(debate_conductor_host)" || return $?
  case "$role:$host" in
    generator:*) printf 'agy\n' ;;
    critic:claude)
      if [ "$gen" = "codex" ]; then printf 'agy\n'
      else printf 'codex\n'; fi
      ;;
    critic:codex)
      if [ "$gen" = "claude" ] || [ "$gen" = "claude-write" ]; then printf 'agy\n'
      else printf 'claude\n'; fi
      ;;
    *) echo "debate-conductor: unknown role '$role'" >&2; return 2 ;;
  esac
}

debate_conductor_resolve_role() {
  local role="$1" cli="${2:-}" gen="${3:-}"
  local key="debate-conductor.$role" cfg
  if [ -n "$cli" ]; then printf '%s\n' "$cli"; return 0; fi
  case "$role" in
    generator)
      if [ -n "${DEBATE_GENERATOR_MODEL:-}" ]; then printf '%s\n' "$DEBATE_GENERATOR_MODEL"; return 0; fi
      if [ -n "${DEBATE_PRIMARY_GEN:-}" ]; then printf '%s\n' "$DEBATE_PRIMARY_GEN"; return 0; fi
      ;;
    critic)
      if [ -n "${DEBATE_CRITIC_MODEL:-}" ]; then printf '%s\n' "$DEBATE_CRITIC_MODEL"; return 0; fi
      ;;
    *) echo "debate-conductor: unknown role '$role'" >&2; return 2 ;;
  esac
  cfg="$(registry_config_role "$key")"
  if [ -n "$cfg" ]; then printf '%s\n' "$cfg"; return 0; fi
  debate_conductor_default_role "$role" "$gen"
}

# Check availability and, for Claude under Codex PM, login. Authentication and
# billing stay under Claude Code's own configuration.
debate_conductor_check_cli() {
  local model="$1" bin auth host
  host="$(debate_conductor_host)" || return $?
  bin="$(registry_resolve_command "$model")" || return $?
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "debate-conductor: CLI not found: $bin (model=$model)" >&2
    return 2
  fi
  [ "$host" = codex ] || return 0
  case "$model:${bin##*/}" in
    claude:*|claude-write:*|*:claude|*:claude.exe) ;;
    *) return 0 ;;
  esac
  if ! auth="$("$bin" auth status --json 2>/dev/null)"; then
    echo 'debate-conductor: could not check Claude login; no invocation started' >&2
    return 2
  fi
  if ! printf '%s' "$auth" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    echo 'debate-conductor: Claude login not confirmed; check claude auth status in a terminal' >&2
    return 2
  fi
}
