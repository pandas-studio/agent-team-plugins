#!/usr/bin/env bash
# namespace.sh — filesystem-safe team/project identifiers shared by agent-team plugins.

agent_team_validate_id() {
  local value="${1:-}" label="${2:-identifier}" max_len="${3:-48}"
  if [ -z "$value" ]; then
    printf 'ERROR: %s must not be empty\n' "$label" >&2
    return 2
  fi
  if [ "${#value}" -gt "$max_len" ]; then
    printf 'ERROR: %s must be at most %s characters: %s\n' "$label" "$max_len" "$value" >&2
    return 2
  fi
  if ! printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    printf 'ERROR: %s must match [A-Za-z0-9][A-Za-z0-9._-]*: %s\n' "$label" "$value" >&2
    return 2
  fi
}

# agent_team_sanitize_id VALUE — drop everything outside [A-Za-z0-9._-] and any
# leading run of characters the leading-alnum rule forbids. Echoes "default"
# when nothing usable survives.
agent_team_sanitize_id() {
  local clean="${1//[^A-Za-z0-9._-]/}"
  while [ -n "$clean" ]; do
    case "$clean" in
      [A-Za-z0-9]*) break ;;
      *) clean="${clean#?}" ;;
    esac
  done
  printf '%s' "${clean:0:48}"
}

# agent_team_detect_team — resolve the team namespace that scopes log/state
# paths: $AGENT_TEAM > tmux @team-name > tmux session name > "default".
#
# An explicit AGENT_TEAM is a deliberate identifier, so an unusable value is a
# hard error the operator should see and fix. A tmux window or session name is
# *derived* — the user never chose it as a path component and names like
# "my project" or "feat/x" are ordinary — so those are sanitized with a loud
# warning instead, preserving the pre-namespace.sh behaviour.
agent_team_detect_team() {
  local raw="" source="team name" clean
  if [ -n "${AGENT_TEAM:-}" ]; then
    agent_team_validate_id "$AGENT_TEAM" "AGENT_TEAM" 48 || return $?
    printf '%s\n' "$AGENT_TEAM"
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    raw=$(tmux show-options -wqv -t "${TMUX_PANE:-}" '@team-name' 2>/dev/null) || raw=""
    if [ -z "$raw" ]; then
      raw=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null) || raw=""
      source="tmux session name"
    else
      source="tmux @team-name"
    fi
  fi
  [ -z "$raw" ] && { printf 'default\n'; return 0; }
  clean=$(agent_team_sanitize_id "$raw")
  [ -z "$clean" ] && clean="default"
  if [ "$clean" != "$raw" ]; then
    printf 'WARNING: %s "%s" sanitized to "%s" (allowed: [A-Za-z0-9][A-Za-z0-9._-]*, max 48)\n' \
      "$source" "$raw" "$clean" >&2
  fi
  printf '%s\n' "$clean"
}
