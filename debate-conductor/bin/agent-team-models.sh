#!/usr/bin/env bash
# agent-team-models — inspect and manage the shared model registry config.
#
# VENDORED COPY. Canonical source: dev-trio/bin/agent-team-models.sh, copied
# byte-for-byte into debate-conductor/bin/. Both operate on the SAME shared
# config file, so it does not matter which plugin's copy you run.
#
# Subcommands:
#   list                          show all models + role bindings
#   show <model-id>               show one model definition (+ resolved binary)
#   doctor                        validate config; report unresolved roles/binaries
#   preset add <name>             install a named preset (e.g. kimi-code)
#   add  <id> --command <cmd> [--env-command VAR] [--arg A ...] [--final-arg A ...]
#   edit <id> [--command ...] [--env-command ...] [--arg ...] [--final-arg ...]
#   remove <id> [--force --fallback <model-id>]
#   set-role <plugin.role> <model-id>
#
# Config file: $AGENT_TEAM_MODELS_CONFIG, else
#              ${XDG_CONFIG_HOME:-$HOME/.config}/agent-team-plugins/models.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REGISTRY_LIB="$SCRIPT_DIR/../lib/registry.sh"
[ -f "$_REGISTRY_LIB" ] || { echo "agent-team-models: registry.sh not found at $_REGISTRY_LIB" >&2; exit 1; }
# shellcheck source=../lib/registry.sh
. "$_REGISTRY_LIB" || { echo "agent-team-models: failed to load registry.sh (jq missing?)" >&2; exit 2; }
unset _REGISTRY_LIB

PROG="agent-team-models"
CONFIG="$(registry_config_file)"

die() { echo "$PROG: $*" >&2; exit 2; }

usage() {
  cat <<EOF
Usage: $PROG <command> [args]

  list                         show all models and role bindings
  show <model-id>              show one model definition + resolved binary
  doctor                       validate the config and report problems
  preset add <name>            install a preset ($(registry_preset_names | tr '\n' ' '))
  add <id> --command <cmd> [--env-command VAR] [--arg A ...] [--final-arg A ...]
  edit <id> [--command ...] [--env-command ...] [--arg ...] [--final-arg ...]
  remove <id> [--force --fallback <model-id>]
  set-role <plugin.role> <model-id>

Config file: $CONFIG
Roles: $(registry_known_roles | tr '\n' ' ')
EOF
}

# Write stdin (full config JSON) to the config file atomically, after validating.
_cfg_save() {
  local json dir tmp
  json="$(cat)"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || die "refusing to write invalid JSON to $CONFIG"
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"
  tmp="$CONFIG.tmp.$$"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$CONFIG"
}

# Echo a JSON array built from the given argv (empty -> []), set -u safe.
# Built element-by-element rather than via `jq --args` because jq still parses
# a positional that looks like an option (e.g. an "--output-last-message" arg)
# as a jq flag, which both corrupts the array and is a security-relevant footgun.
_args_to_json() {
  local out='[]' a
  for a in "$@"; do
    out="$(jq -nc --argjson acc "$out" --arg x "$a" '$acc + [$x]')"
  done
  printf '%s' "$out"
}

_role_source() {
  # Echo a human label for where a role binding currently comes from.
  local key="$1" envname
  envname="$(_registry_role_envname "$key")"
  if [ -n "$envname" ] && [ -n "${!envname:-}" ]; then
    printf 'env %s' "$envname"
  elif [ -n "$(registry_config_role "$key")" ]; then
    printf 'config'
  else
    printf 'built-in default'
  fi
}

cmd_list() {
  if [ -f "$CONFIG" ]; then
    echo "Config: $CONFIG (present)"
  else
    echo "Config: $CONFIG (not created yet — built-in defaults in effect)"
  fi
  echo
  echo "Models:"
  local id origin cmd
  for id in $(registry_list_model_ids); do
    if registry_model_is_builtin "$id"; then origin="built-in"; else origin="user"; fi
    cmd="$(registry_resolve_command "$id" 2>/dev/null || echo '?')"
    if registry_has_final "$id"; then
      printf '  %-16s %-9s binary=%-10s (native final-capture)\n' "$id" "[$origin]" "$cmd"
    else
      printf '  %-16s %-9s binary=%s\n' "$id" "[$origin]" "$cmd"
    fi
  done
  echo
  echo "Roles:"
  local key plugin role resolved src
  while IFS= read -r key; do
    plugin="${key%.*}"
    role="${key#*.}"
    resolved="$(registry_resolve_role "$plugin" "$role" "" 2>/dev/null || echo '?')"
    src="$(_role_source "$key")"
    printf '  %-30s -> %-12s (%s)\n' "$key" "$resolved" "$src"
  done < <(registry_known_roles)
}

cmd_show() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: $PROG show <model-id>"
  registry_model_exists "$id" || die "unknown model '$id' (run: $PROG list)"
  _registry_model_def "$id" | jq .
  echo "resolved binary: $(registry_resolve_command "$id" 2>/dev/null || echo '?')"
}

cmd_doctor() {
  local failed=0
  echo "$PROG doctor"
  echo

  echo "1. Config file"
  if [ -f "$CONFIG" ]; then
    if jq -e . "$CONFIG" >/dev/null 2>&1; then
      echo "  [ok]   $CONFIG (valid JSON)"
    else
      echo "  [FAIL] $CONFIG exists but is not valid JSON"
      failed=1
    fi
  else
    echo "  [ok]   $CONFIG not present — built-in defaults in effect"
  fi

  echo
  echo "2. Models"
  local id cmd
  for id in $(registry_list_model_ids); do
    cmd="$(registry_resolve_command "$id" 2>/dev/null || echo '')"
    if [ -z "$cmd" ]; then
      echo "  [FAIL] $id has no resolvable command"; failed=1; continue
    fi
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  [ok]   $id -> $cmd ($(command -v "$cmd"))"
    else
      echo "  [warn] $id -> $cmd (not on PATH; set its env override or install it)"
    fi
  done

  echo
  echo "3. Roles"
  local key plugin role resolved src
  while IFS= read -r key; do
    plugin="${key%.*}"
    role="${key#*.}"
    resolved="$(registry_resolve_role "$plugin" "$role" "" 2>/dev/null || echo '')"
    src="$(_role_source "$key")"
    if [ -z "$resolved" ]; then
      echo "  [FAIL] $key does not resolve to any model"; failed=1; continue
    fi
    if registry_model_exists "$resolved"; then
      echo "  [ok]   $key -> $resolved ($src)"
    else
      echo "  [FAIL] $key -> $resolved ($src) — no such model"; failed=1
    fi
  done < <(registry_known_roles)

  echo
  if [ "$failed" = "1" ]; then
    echo "$PROG doctor: FAILED"
    return 1
  fi
  echo "$PROG doctor: OK"
}

cmd_preset() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      local name="${1:-}"
      [ -n "$name" ] || die "usage: $PROG preset add <name>  (available: $(registry_preset_names | tr '\n' ' '))"
      local preset
      preset="$(_registry_preset_json "$name")" || die "unknown preset '$name' (available: $(registry_preset_names | tr '\n' ' '))"
      _registry_config_json | jq --argjson p "$preset" '.models = (.models + $p)' | _cfg_save
      echo "preset '$name' added -> models: $(printf '%s' "$preset" | jq -r 'keys | join(", ")')"
      echo "config: $CONFIG"
      ;;
    *) die "usage: $PROG preset add <name>" ;;
  esac
}

cmd_add() {
  local id="${1:-}"; shift || true
  [ -n "$id" ] || die "usage: $PROG add <id> --command <cmd> [--env-command VAR] [--arg A ...] [--final-arg A ...]"
  if registry_model_is_builtin "$id"; then
    die "'$id' is a built-in model; pick a different id (built-ins cannot be redefined via add)"
  fi
  local command="" envcmd="" args=() finals=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command)      command="${2?--command requires a value}"; shift 2 ;;
      --command=*)    command="${1#--command=}"; shift ;;
      --env-command)  envcmd="${2?--env-command requires a value}"; shift 2 ;;
      --env-command=*) envcmd="${1#--env-command=}"; shift ;;
      --arg)          args+=("${2?--arg requires a value}"); shift 2 ;;
      --final-arg)    finals+=("${2?--final-arg requires a value}"); shift 2 ;;
      *) die "add: unexpected argument: $1" ;;
    esac
  done
  [ -n "$command" ] || die "add: --command is required"
  if [ "${#args[@]}" -eq 0 ]; then
    args=(-p "{prompt}")
    echo "$PROG: note: no --arg given; defaulting args to: -p {prompt}" >&2
  fi
  local args_json finals_json def
  args_json="$(_args_to_json "${args[@]}")"
  if [ "${#finals[@]}" -gt 0 ]; then finals_json="$(_args_to_json "${finals[@]}")"; else finals_json='[]'; fi
  def="$(jq -n \
    --arg cmd "$command" \
    --arg env "$envcmd" \
    --argjson args "$args_json" \
    --argjson finals "$finals_json" \
    '{ command: $cmd }
     + ( if $env != "" then { env_command: $env } else {} end )
     + { args: $args }
     + ( if ($finals | length) > 0 then { final_args: $finals } else {} end )')"
  _registry_config_json | jq --arg id "$id" --argjson def "$def" '.models[$id] = $def' | _cfg_save
  echo "model '$id' added"
  echo "config: $CONFIG"
}

cmd_edit() {
  local id="${1:-}"; shift || true
  [ -n "$id" ] || die "usage: $PROG edit <id> [--command ...] [--env-command ...] [--arg ...] [--final-arg ...]"
  local existing
  existing="$(_registry_config_json | jq -c --arg id "$id" '.models[$id] // null')"
  [ "$existing" != "null" ] || die "'$id' is not a user-defined model (use '$PROG add' to create it; built-ins cannot be edited)"
  local set_command=0 set_env=0 command="" envcmd="" args=() finals=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command)       command="${2?--command requires a value}"; set_command=1; shift 2 ;;
      --command=*)     command="${1#--command=}"; set_command=1; shift ;;
      --env-command)   envcmd="${2?--env-command requires a value}"; set_env=1; shift 2 ;;
      --env-command=*) envcmd="${1#--env-command=}"; set_env=1; shift ;;
      --arg)           args+=("${2?--arg requires a value}"); shift 2 ;;
      --final-arg)     finals+=("${2?--final-arg requires a value}"); shift 2 ;;
      *) die "edit: unexpected argument: $1" ;;
    esac
  done
  local def="$existing"
  if [ "$set_command" = "1" ]; then
    def="$(printf '%s' "$def" | jq --arg c "$command" '.command = $c')"
  fi
  if [ "$set_env" = "1" ]; then
    if [ -n "$envcmd" ]; then
      def="$(printf '%s' "$def" | jq --arg e "$envcmd" '.env_command = $e')"
    else
      def="$(printf '%s' "$def" | jq 'del(.env_command)')"
    fi
  fi
  if [ "${#args[@]}" -gt 0 ]; then
    def="$(printf '%s' "$def" | jq --argjson a "$(_args_to_json "${args[@]}")" '.args = $a')"
  fi
  if [ "${#finals[@]}" -gt 0 ]; then
    def="$(printf '%s' "$def" | jq --argjson f "$(_args_to_json "${finals[@]}")" '.final_args = $f')"
  fi
  _registry_config_json | jq --arg id "$id" --argjson def "$def" '.models[$id] = $def' | _cfg_save
  echo "model '$id' updated"
  echo "config: $CONFIG"
}

cmd_remove() {
  local id="${1:-}"; shift || true
  [ -n "$id" ] || die "usage: $PROG remove <id> [--force --fallback <model-id>]"
  local force=0 fallback=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)       force=1; shift ;;
      --fallback)    fallback="${2?--fallback requires a model-id}"; shift 2 ;;
      --fallback=*)  fallback="${1#--fallback=}"; shift ;;
      *) die "remove: unexpected argument: $1" ;;
    esac
  done
  local existing
  existing="$(_registry_config_json | jq -c --arg id "$id" '.models[$id] // null')"
  [ "$existing" != "null" ] || die "'$id' is not a user-defined model (built-ins cannot be removed; nothing to do)"
  # Roles in config that currently point at this model.
  local refs
  refs="$(_registry_config_json | jq -r --arg id "$id" '.roles | to_entries[] | select(.value == $id) | .key')"
  if [ -n "$refs" ]; then
    if [ "$force" != "1" ]; then
      echo "$PROG: '$id' is in use by role(s):" >&2
      printf '  %s\n' $refs >&2
      die "refusing to remove a model in use — re-run with: $PROG remove $id --force --fallback <model-id>"
    fi
    [ -n "$fallback" ] || die "remove --force requires --fallback <model-id> to reassign role(s): $(printf '%s ' $refs)"
    registry_model_exists "$fallback" || die "fallback model '$fallback' does not exist"
    [ "$fallback" != "$id" ] || die "fallback cannot be the model being removed"
    # Reassign each referencing role to the fallback, then drop the model.
    _registry_config_json \
      | jq --arg id "$id" --arg fb "$fallback" \
          '.roles |= with_entries(if .value == $id then .value = $fb else . end)
           | del(.models[$id])' \
      | _cfg_save
    echo "model '$id' removed; reassigned role(s) to '$fallback':"
    printf '  %s\n' $refs
  else
    _registry_config_json | jq --arg id "$id" 'del(.models[$id])' | _cfg_save
    echo "model '$id' removed"
  fi
  echo "config: $CONFIG"
}

cmd_set_role() {
  local key="${1:-}" model="${2:-}"
  [ -n "$key" ] && [ -n "$model" ] || die "usage: $PROG set-role <plugin.role> <model-id>  (roles: $(registry_known_roles | tr '\n' ' '))"
  registry_role_is_known "$key" || die "unknown role '$key' (known: $(registry_known_roles | tr '\n' ' '))"
  registry_model_exists "$model" || die "unknown model '$model' (run: $PROG list)"
  _registry_config_json | jq --arg k "$key" --arg m "$model" '.roles[$k] = $m' | _cfg_save
  echo "role '$key' -> '$model'"
  echo "config: $CONFIG"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list)      cmd_list "$@" ;;
    show)      cmd_show "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    preset)    cmd_preset "$@" ;;
    add)       cmd_add "$@" ;;
    edit)      cmd_edit "$@" ;;
    remove)    cmd_remove "$@" ;;
    set-role)  cmd_set_role "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "$PROG: unknown command '$cmd'" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
