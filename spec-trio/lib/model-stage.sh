#!/usr/bin/env bash
# Shared model selection and clean-answer capture for Ralph and spec drivers.
# Source after setting PLUGIN_ROOT.
. "$PLUGIN_ROOT/lib/registry.sh" || return 2

trio_host() {
  local plugin="$1" value
  if [ "$plugin" = spec-trio ]; then value="${SPEC_TRIO_PM_HOST:-claude}"
  else value="${RALPH_TRIO_PM_HOST:-claude}"; fi
  case "$value" in claude|codex) printf '%s\n' "$value" ;;
    *) echo "$plugin: PM host must be claude or codex" >&2; return 2 ;;
  esac
}

trio_resolve_model() {
  local plugin="$1" role="$2" choice="${3:-}" host key envname cfg
  host=$(trio_host "$plugin") || return $?
  key="$plugin.$role"
  if [ -n "$choice" ]; then printf '%s\n' "$choice"; return 0; fi
  envname=$(_registry_role_envname "$key")
  if [ -n "$envname" ] && [ -n "${!envname:-}" ]; then
    printf '%s\n' "${!envname}"; return 0
  fi
  cfg=$(registry_config_role "$key") || return $?
  if [ -n "$cfg" ]; then printf '%s\n' "$cfg"; return 0; fi
  if [ "$host" = codex ]; then
    case "$role" in planner) printf 'codex-plan\n' ;;
      worker|coder) printf 'codex-write\n' ;;
      *) return 2 ;;
    esac
  else
    registry_resolve_role "$plugin" "$role" ''
  fi
}

trio_check_model() {
  local model="$1" binary
  registry_check_model "$model" || return 2
  binary=$(registry_resolve_command "$model") || return 2
  command -v "$binary" >/dev/null 2>&1 || {
    echo "model CLI not found: $binary (model=$model)" >&2; return 2;
  }
}

# Called by stage_run; its stdin is STAGE_PROMPT. Keep a native CLI transcript
# in stderr/the stage log, and send only its final answer to stage stdout.
trio_stage_model() {
  local model="$1" final="$2" prompt rc=0
  prompt=$(cat) || return 6
  if registry_has_final "$model"; then
    rm -f -- "$final" || return 6
    registry_run "$model" "$prompt" "$final" >&2 || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    [ -r "$final" ] || { echo "model left no final answer: $final" >&2; return 5; }
    cat "$final" || return 6
  else
    registry_run "$model" "$prompt"
  fi
}
