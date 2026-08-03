#!/usr/bin/env bash
# registry.sh — model-adapter registry + runner shared by the agent-team plugins.
#
# VENDORED COPY. The canonical source lives in dev-trio/lib/registry.sh and is
# copied byte-for-byte into debate-conductor/lib/registry.sh. The library is
# fully plugin-agnostic (it computes the shared config path itself and embeds
# the built-in model/role defaults below), so the two copies must stay
# identical — edit dev-trio's and re-copy.
#
# A "model" is a named CLI adapter: how to spawn a particular agent CLI and
# feed it a prompt. Definitions are JSON objects:
#   {
#     "command":     "agy",            # default binary on PATH
#     "env_command": "AGY_CLI",        # optional: env var whose value overrides command
#     "args":        ["-p", "{prompt}"],            # argv template (streaming form)
#     "final_args":  ["exec", "--output-last-message", "{final}", "{prompt}"]  # optional
#   }
# {prompt} expands to the full prompt string; {final} expands to a path the CLI
# should write its final/last message to. Templates are expanded into an argv
# ARRAY (no eval, no word-splitting) so a multi-line {prompt} stays one argv.
#
# Built-in models: agy, codex, claude. User-defined models + role bindings live
# in the shared config file (see _registry_config_file). Presets (kimi-code)
# can be stamped into config via `agent-team-models preset add`.
#
# Role resolution precedence (registry_resolve_role):
#   1. CLI flag (caller-supplied)   2. role env var   3. config role binding
#   4. built-in role default
# Binary resolution precedence (registry_resolve_command):
#   1. REGISTRY_CMD_OVERRIDE (legacy per-role *_CLI env, set by the caller)
#   2. model env_command value      3. model command
#
# Dependency: jq (1.6+). Sourced into scripts that run `set -euo pipefail`, so
# every helper is written to be safe under -e (guarded tests, explicit returns).

if ! command -v jq >/dev/null 2>&1; then
  echo "registry.sh: jq not found in PATH — required for the model registry" >&2
  return 1 2>/dev/null || exit 1
fi

# ---- built-in defaults (zero-config baseline) -------------------------------

_registry_builtin_models() {
  cat <<'JSON'
{
  "agy": {
    "command": "agy",
    "env_command": "AGY_CLI",
    "args": ["-p", "{prompt}"]
  },
  "codex": {
    "command": "codex",
    "env_command": "CODEX_CLI",
    "args": ["exec", "--skip-git-repo-check", "{prompt}"],
    "final_args": ["exec", "--skip-git-repo-check", "--output-last-message", "{final}", "{prompt}"]
  },
  "claude": {
    "command": "claude",
    "env_command": "CLAUDE_CLI",
    "args": ["-p", "{prompt}"]
  }
}
JSON
}

_registry_builtin_roles() {
  cat <<'JSON'
{
  "dev-trio.researcher": "agy",
  "dev-trio.reviewer": "codex",
  "debate-conductor.generator": "agy",
  "debate-conductor.critic": "codex",
  "langgraph-conductor.planner": "claude",
  "langgraph-conductor.coder": "claude",
  "langgraph-conductor.researcher": "agy",
  "langgraph-conductor.reviewer": "codex"
}
JSON
}

# Named presets installable via `agent-team-models preset add <name>`.
# Echoes a {model-id: def} object on success; returns 1 for an unknown preset.
_registry_preset_json() {
  case "$1" in
    kimi-code)
      cat <<'JSON'
{
  "kimi-code": {
    "command": "kimi",
    "env_command": "KIMI_CLI",
    "args": ["-p", "{prompt}"]
  }
}
JSON
      ;;
    *) return 1 ;;
  esac
}

registry_preset_names() {
  printf '%s\n' kimi-code
}

# The fixed set of plugin roles the registry knows how to bind.
registry_known_roles() {
  printf '%s\n' \
    dev-trio.researcher \
    dev-trio.reviewer \
    debate-conductor.generator \
    debate-conductor.critic \
    langgraph-conductor.planner \
    langgraph-conductor.coder \
    langgraph-conductor.researcher \
    langgraph-conductor.reviewer
}

registry_role_is_known() {
  case "$1" in
    dev-trio.researcher|dev-trio.reviewer|debate-conductor.generator|debate-conductor.critic|langgraph-conductor.planner|langgraph-conductor.coder|langgraph-conductor.researcher|langgraph-conductor.reviewer) return 0 ;;
    *) return 1 ;;
  esac
}

# role key -> documented per-role override env var name ("" if none)
_registry_role_envname() {
  case "$1" in
    dev-trio.researcher)          printf 'DEV_TRIO_RESEARCHER_MODEL' ;;
    dev-trio.reviewer)            printf 'DEV_TRIO_REVIEWER_MODEL' ;;
    debate-conductor.generator)   printf 'DEBATE_GENERATOR_MODEL' ;;
    debate-conductor.critic)      printf 'DEBATE_CRITIC_MODEL' ;;
    langgraph-conductor.planner)  printf 'LANGGRAPH_CONDUCTOR_PLANNER_MODEL' ;;
    langgraph-conductor.coder)    printf 'LANGGRAPH_CONDUCTOR_CODER_MODEL' ;;
    langgraph-conductor.researcher) printf 'LANGGRAPH_CONDUCTOR_RESEARCHER_MODEL' ;;
    langgraph-conductor.reviewer) printf 'LANGGRAPH_CONDUCTOR_REVIEWER_MODEL' ;;
    *)                            printf '' ;;
  esac
}

# ---- config file ------------------------------------------------------------

registry_config_file() {
  if [ -n "${AGENT_TEAM_MODELS_CONFIG:-}" ]; then
    printf '%s\n' "$AGENT_TEAM_MODELS_CONFIG"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/agent-team-plugins/models.json"
  fi
}
# Back-compat internal alias.
_registry_config_file() { registry_config_file; }

# Echo the config as normalized JSON ({version,models,roles}). A missing file
# yields the empty config; a malformed file is ignored with a warning so a
# broken edit never aborts a live research/debate run (the CLI `doctor` flags it).
_registry_config_json() {
  local f
  f="$(registry_config_file)"
  if [ -f "$f" ]; then
    if jq -e . "$f" >/dev/null 2>&1; then
      jq '{ version: (.version // 1), models: (.models // {}), roles: (.roles // {}) }' "$f"
    else
      echo "registry: warning: config is not valid JSON, ignoring: $f" >&2
      printf '%s\n' '{"version":1,"models":{},"roles":{}}'
    fi
  else
    printf '%s\n' '{"version":1,"models":{},"roles":{}}'
  fi
}

# Merge built-in models with config models (config wins per model-id).
_registry_models_merged() {
  jq -n \
    --argjson builtin "$(_registry_builtin_models)" \
    --argjson cfg "$(_registry_config_json)" \
    '$builtin + ($cfg.models // {})'
}

# Echo one model's definition as compact JSON, or the literal "null" if absent.
_registry_model_def() {
  _registry_models_merged | jq -c --arg id "$1" '.[$id] // null'
}

# Echo each element of a model's array field (args|final_args) on its own line.
_registry_model_array() {
  local id="$1" field="$2"
  _registry_model_def "$id" | jq -r --arg f "$field" '(.[$f] // [])[]'
}

# ---- queries ----------------------------------------------------------------

registry_model_exists() {
  local def
  def="$(_registry_model_def "$1")"
  [ -n "$def" ] && [ "$def" != "null" ]
}

# rc=0 iff the model defines a non-empty final_args template.
registry_has_final() {
  local def
  def="$(_registry_model_def "$1")"
  if [ -z "$def" ] || [ "$def" = "null" ]; then return 1; fi
  [ "$(printf '%s' "$def" | jq -r '((.final_args // []) | length) > 0')" = "true" ]
}

registry_list_model_ids() {
  _registry_models_merged | jq -r 'keys[]'
}

# rc=0 iff the model is one of the built-ins (not removable via the CLI).
registry_model_is_builtin() {
  [ "$(_registry_builtin_models | jq -r --arg id "$1" 'has($id)')" = "true" ]
}

# ---- resolution -------------------------------------------------------------

# registry_resolve_command <model-id>
#   Echo the binary to exec. Honors REGISTRY_CMD_OVERRIDE (caller's legacy
#   per-role *_CLI override), then the model's env_command, then command.
registry_resolve_command() {
  local id="$1" def envvar val cmd
  if [ -n "${REGISTRY_CMD_OVERRIDE:-}" ]; then
    printf '%s\n' "$REGISTRY_CMD_OVERRIDE"
    return 0
  fi
  def="$(_registry_model_def "$id")"
  if [ -z "$def" ] || [ "$def" = "null" ]; then
    echo "registry: unknown model '$id'" >&2
    return 3
  fi
  envvar="$(printf '%s' "$def" | jq -r '.env_command // ""')"
  if [ -n "$envvar" ]; then
    val="${!envvar:-}"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  cmd="$(printf '%s' "$def" | jq -r '.command // ""')"
  if [ -z "$cmd" ]; then
    echo "registry: model '$id' has no command" >&2
    return 3
  fi
  printf '%s\n' "$cmd"
}

# registry_resolve_role <plugin> <role> [cli-flag-value]
#   Echo the resolved model-id for a role using the documented precedence.
registry_resolve_role() {
  local plugin="$1" role="$2" cli="${3:-}"
  local key="$plugin.$role"
  if [ -n "$cli" ]; then printf '%s\n' "$cli"; return 0; fi
  local envname val cfg def
  envname="$(_registry_role_envname "$key")"
  if [ -n "$envname" ]; then
    val="${!envname:-}"
    if [ -n "$val" ]; then printf '%s\n' "$val"; return 0; fi
  fi
  cfg="$(_registry_config_json | jq -r --arg k "$key" '.roles[$k] // ""')"
  if [ -n "$cfg" ]; then printf '%s\n' "$cfg"; return 0; fi
  def="$(_registry_builtin_roles | jq -r --arg k "$key" '.[$k] // ""')"
  if [ -n "$def" ]; then printf '%s\n' "$def"; return 0; fi
  echo "registry: no model resolvable for role '$key'" >&2
  return 3
}

# Echo the config-bound model-id for a role key (empty if none) — lets callers
# distinguish an explicit user binding from a built-in default.
registry_config_role() {
  _registry_config_json | jq -r --arg k "$1" '.roles[$k] // ""'
}

# ---- run --------------------------------------------------------------------

# registry_run <model-id> <prompt> [final-file]
#   Expand the model's argv template and exec the CLI, streaming stdout/stderr
#   to the caller (who is expected to wrap the call in `2>&1 | tee`). When a
#   final-file is given AND the model defines final_args, the final-capture
#   template is used (the CLI writes its last message to that path); otherwise
#   the plain args template runs and the caller may synthesize the final file
#   from the streamed log (see registry_extract_response).
registry_run() {
  local id="$1" prompt="$2" final_file="${3:-}"
  local bin field a line
  bin="$(registry_resolve_command "$id")" || return $?
  field="args"
  if [ -n "$final_file" ] && registry_has_final "$id"; then
    field="final_args"
  fi
  local tmpl=()
  while IFS= read -r line; do
    tmpl+=("$line")
  done < <(_registry_model_array "$id" "$field")
  if [ "${#tmpl[@]}" -eq 0 ]; then
    echo "registry: model '$id' has no '$field' template" >&2
    return 3
  fi
  local argv=()
  for a in "${tmpl[@]}"; do
    case "$a" in
      "{prompt}") argv+=("$prompt") ;;
      "{final}")  argv+=("$final_file") ;;
      *)          argv+=("$a") ;;
    esac
  done
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL "$bin" "${argv[@]}"
  else
    "$bin" "${argv[@]}"
  fi
}

# registry_extract_response <log-file>
#   Echo the model output a wrapper logs between its '=== RESPONSE ===' header
#   and trailing '=== END (rc=...) ===' marker. Used to synthesize a *.final.md
#   for models lacking native final-message capture.
registry_extract_response() {
  local log="$1"
  [ -f "$log" ] || return 1
  awk '
    /^=== RESPONSE ===$/   { inblk=1; buf=""; next }
    /^=== END \(rc=/       { if (inblk) { printf "%s", buf }; inblk=0; buf=""; next }
    inblk                  { buf = buf $0 "\n" }
    END                    { if (inblk) printf "%s", buf }
  ' "$log"
}
