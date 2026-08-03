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

agent_team_detect_team() {
  local raw="" source="team name"
  if [ -n "${AGENT_TEAM:-}" ]; then
    raw="$AGENT_TEAM"
    source="AGENT_TEAM"
  elif [ -n "${TMUX:-}" ]; then
    raw=$(tmux show-options -wqv -t "${TMUX_PANE:-}" '@team-name' 2>/dev/null) || raw=""
    if [ -z "$raw" ]; then
      raw=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null) || raw=""
      source="tmux session name"
    else
      source="tmux @team-name"
    fi
  fi
  [ -z "$raw" ] && raw="default"
  agent_team_validate_id "$raw" "$source" 48 || return $?
  printf '%s\n' "$raw"
}
