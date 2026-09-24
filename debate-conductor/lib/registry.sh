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
# How the prompt reaches the CLI — "prompt_via" (#102):
#   "argv" (default)  {prompt} is one argument. Linux refuses a single argument
#                     of 128 KiB or more (MAX_ARG_STRLEN, NUL included) before
#                     the CLI starts; macOS only caps the total. So registry_run
#                     refuses such a prompt itself, on every platform, rc 3.
#                     REGISTRY_ARGV_MAX_BYTES overrides the 131072 limit.
#   "stdin"           the templates carry no {prompt}; the prompt, followed by
#                     a newline, is the CLI's stdin through a bash here-string
#                     (bash writes it in full before the CLI starts and removes
#                     any temp file itself; no writer process outlives the
#                     start). The CLI never sees the caller's stdin. Built-in
#                     claude and codex models use it (`claude -p`,
#                     `codex exec -`); agy has no documented text form and
#                     stays on argv.
# A "stdin" template that contains {prompt}, or any other prompt_via value, is
# a configuration error (rc 3), as `agent-team-models doctor` reports.
#
# Two optional, caller-gated prefixes (built-in agy defines both):
#   "workspace_args": ["--add-dir", "{cwd}"]      # {cwd} = $REGISTRY_WORKSPACE
#   "log_args":       ["--log-file", "{cli_log}"] # {cli_log} = $REGISTRY_CLI_LOG
# registry_run puts log_args, then workspace_args, before the template — each
# only when its variable is non-empty, so a caller that sets neither gets
# exactly the argv it got before. dev-trio's wrappers pass both as prefix
# assignments on the call (empty for other models); like REGISTRY_CMD_OVERRIDE,
# a caller that exports them gets them applied, and the CLI inherits them.
#
# Built-in models: agy, codex, codex-no-memories, claude, claude-write ("claude"
# is read-only in headless -p mode; "claude-write" adds --permission-mode
# acceptEdits so a coder role can actually edit files; "codex-no-memories" turns
# off Codex's memories feature so a review is not primed by earlier Codex
# sessions). User-defined models + role bindings live
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
    "args": ["-p", "{prompt}"],
    "workspace_args": ["--add-dir", "{cwd}"],
    "log_args": ["--log-file", "{cli_log}"]
  },
  "codex": {
    "command": "codex",
    "env_command": "CODEX_CLI",
    "prompt_via": "stdin",
    "args": ["exec", "--skip-git-repo-check", "-"],
    "final_args": ["exec", "--skip-git-repo-check", "--output-last-message", "{final}", "-"]
  },
  "codex-no-memories": {
    "command": "codex",
    "env_command": "CODEX_CLI",
    "prompt_via": "stdin",
    "args": ["exec", "--skip-git-repo-check", "-c", "features.memories=false", "-"],
    "final_args": ["exec", "--skip-git-repo-check", "-c", "features.memories=false", "--output-last-message", "{final}", "-"]
  },
  "claude": {
    "command": "claude",
    "env_command": "CLAUDE_CLI",
    "prompt_via": "stdin",
    "args": ["-p"]
  },
  "claude-write": {
    "command": "claude",
    "env_command": "CLAUDE_CLI",
    "prompt_via": "stdin",
    "args": ["-p", "--permission-mode", "acceptEdits"]
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
  "langgraph-conductor.coder": "claude-write",
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

# Echo each element of a model's array field (args|final_args|workspace_args|
# log_args) on its own line.
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

# rc=0 iff the model defines a non-empty workspace_args template — callers key
# workspace-aware behaviour on this rather than on the binary's name.
registry_has_workspace() {
  local def
  def="$(_registry_model_def "$1")"
  if [ -z "$def" ] || [ "$def" = "null" ]; then return 1; fi
  [ "$(printf '%s' "$def" | jq -r '((.workspace_args // []) | length) > 0')" = "true" ]
}

# rc=0 iff the model defines a non-empty final_args template.
registry_has_final() {
  local def
  def="$(_registry_model_def "$1")"
  if [ -z "$def" ] || [ "$def" = "null" ]; then return 1; fi
  [ "$(printf '%s' "$def" | jq -r '((.final_args // []) | length) > 0')" = "true" ]
}

# registry_prompt_via <model-id> — echo "argv" or "stdin" (#102). rc 3, with the
# reason on stderr, for an unknown model or any other prompt_via value.
registry_prompt_via() {
  local def via
  def="$(_registry_model_def "$1")"
  if [ -z "$def" ] || [ "$def" = "null" ]; then
    echo "registry: unknown model '$1'" >&2
    return 3
  fi
  via="$(printf '%s' "$def" | jq -r '.prompt_via // "argv"')"
  case "$via" in
    argv|stdin) printf '%s\n' "$via" ;;
    *)
      echo "registry: model '$1' has prompt_via '$via'; use \"argv\" or \"stdin\"" >&2
      return 3
      ;;
  esac
}

# registry_check_model <model-id> — rc 0 when the model's templates agree with
# its prompt_via; otherwise rc 3 with the reason on stderr. A stdin model whose
# args or final_args still contains {prompt} would put the prompt in argv too.
registry_check_model() {
  local id="$1" via n
  via="$(registry_prompt_via "$id")" || return 3
  [ "$via" = stdin ] || return 0
  n="$(_registry_model_def "$id" \
    | jq -r '[((.args // []) + (.final_args // []))[] | select(. == "{prompt}")] | length')"
  if [ "$n" != 0 ]; then
    echo "registry: model '$id' takes its prompt on stdin (prompt_via \"stdin\") but a template still contains {prompt}; remove it" >&2
    return 3
  fi
}

# _registry_prompt_bytes <string> — its length in bytes, not characters.
_registry_prompt_bytes() {
  local LC_ALL=C
  printf '%s\n' "${#1}"
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
#
#   Returns the CLI's own status, or 3 for a configuration error or an argv
#   prompt that one Linux argument cannot hold (nothing was started).
registry_run() {
  local id="$1" prompt="$2" final_file="${3:-}"
  local workspace="${REGISTRY_WORKSPACE:-}" cli_log="${REGISTRY_CLI_LOG:-}"
  local bin field a line via
  bin="$(registry_resolve_command "$id")" || return $?
  via="$(registry_prompt_via "$id")" || return 3
  registry_check_model "$id" || return 3
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
  # Caller-gated prefixes: log_args, then workspace_args, then the template.
  if [ -n "$workspace" ]; then
    local ws=()
    while IFS= read -r line; do
      ws+=("$line")
    done < <(_registry_model_array "$id" workspace_args)
    [ "${#ws[@]}" -eq 0 ] || tmpl=("${ws[@]}" "${tmpl[@]}")
  fi
  if [ -n "$cli_log" ]; then
    local lg=()
    while IFS= read -r line; do
      lg+=("$line")
    done < <(_registry_model_array "$id" log_args)
    [ "${#lg[@]}" -eq 0 ] || tmpl=("${lg[@]}" "${tmpl[@]}")
  fi
  local argv=() in_argv=0
  for a in "${tmpl[@]}"; do
    case "$a" in
      "{prompt}")  argv+=("$prompt"); in_argv=1 ;;
      "{final}")   argv+=("$final_file") ;;
      "{cwd}")     argv+=("$workspace") ;;
      "{cli_log}") argv+=("$cli_log") ;;
      *)           argv+=("$a") ;;
    esac
  done
  if [ "$via" = stdin ]; then
    # A here-string, not `printf | cli`: a pipeline writer would wait on a
    # child the CLI leaves holding stdin, and its SIGPIPE would need handling.
    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL "$bin" "${argv[@]}" <<< "$prompt"
    else
      "$bin" "${argv[@]}" <<< "$prompt"
    fi
    return
  fi
  local limit bytes=0
  limit="${REGISTRY_ARGV_MAX_BYTES:-131072}"
  case "$limit" in ''|*[!0-9]*) limit=131072 ;; esac
  # Only a template that puts {prompt} in argv can hit the limit.
  [ "$in_argv" = 0 ] || bytes="$(_registry_prompt_bytes "$prompt")"
  if [ "$in_argv" = 1 ] && [ "$bytes" -ge "$limit" ]; then
    echo "registry: model '$id' takes its prompt as one argument, and this prompt is $bytes bytes; Linux refuses a single argument of $limit bytes or more. Bind the role to a model with \"prompt_via\": \"stdin\", or pass less context." >&2
    return 3
  fi
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL "$bin" "${argv[@]}"
  else
    "$bin" "${argv[@]}"
  fi
}

# registry_run_answer ID PROMPT [ANSWER_PATH] — registry_run for a role whose
# output is an answer, streamed unchanged as it arrives (stderr stays on stderr).
#
# With ANSWER_PATH, this function also *captures* the answer there, and judges
# the run by that artifact rather than by stdout:
#
#   native capture   the model defines final_args, so the CLI writes its own
#                    last message to ANSWER_PATH. Its streamed stdout is a
#                    transcript, not the answer, and is not inspected.
#   stdout capture   the model has no final_args, so the copy of stdout this
#                    function already keeps is written to ANSWER_PATH. It is
#                    stdout alone — a caller's `2>&1` merge never reaches it.
#
# Capture belongs here because only here is the CLI's own exit status still in
# hand. A caller sees one number and cannot tell a CLI that chose to exit 5
# from this function judging stdout empty; a caller that tried to settle the
# question from a file on disk would either hide a real failure or, as measured,
# report a CLI that exited 0 and wrote a valid answer without printing anything
# as a failed run and drop its answer.
#
# Returns, in priority order:
#   the model's exit code, when it is nonzero — an artifact never promotes it;
#   6 when the model exited 0 but the answer could not be inspected or captured
#     (the temp file could not be created or written, grep failed, or
#     ANSWER_PATH could not be written);
#   5 when the model exited 0 and produced no answer — with ANSWER_PATH, the
#     artifact is missing or holds nothing but whitespace; without it, stdout
#     was empty. agy's print mode soft-denies a tool it cannot prompt for,
#     prints guidance on stderr only and still exits 0, and that must not pass
#     for an answer;
#   0 otherwise.
#
# Without ANSWER_PATH the behaviour is unchanged: stdout is the answer and is
# inspected as before.
#
# registry_run must report the CLI's status itself, not rely on errexit.
#
# A copy of stdout goes to a private temp file that the subshell removes on
# exit. INT/TERM/HUP exit 130/143/129 (codes, not re-raised signals); bash runs
# those traps only once the pipeline ends, so prompt cancellation is up to
# whoever signals the process group. SIGKILL can leave the file behind.
registry_run_answer() {
  if [ "$#" -lt 2 ]; then
    echo "registry_run_answer: usage: registry_run_answer ID PROMPT [ANSWER_PATH]" >&2
    return 2
  fi
  (
    tmp=""
    trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    set +e
    answer_path="${3:-}"
    tmp="$(umask 077 && mktemp "${TMPDIR:-/tmp}/registry-answer.XXXXXX")" || {
      echo "registry_run_answer: cannot create a temp file to inspect the answer" >&2
      exit 6
    }
    registry_run "$@" | tee "$tmp"
    statuses=("${PIPESTATUS[@]}")
    if [ "${statuses[0]}" -ne 0 ]; then
      [ "${statuses[1]}" -eq 0 ] || echo "registry_run_answer: tee also failed (rc=${statuses[1]})" >&2
      exit "${statuses[0]}"
    fi
    if [ "${statuses[1]}" -ne 0 ]; then
      echo "registry_run_answer: tee failed (rc=${statuses[1]}); the answer could not be inspected" >&2
      exit 6
    fi
    # What the answer is, and where to look for it.
    inspect="$tmp"
    if [ -n "$answer_path" ]; then
      if registry_has_final "$1"; then
        inspect="$answer_path"
      elif ! cat "$tmp" > "$answer_path"; then
        echo "registry_run_answer: could not capture the answer to $answer_path" >&2
        exit 6
      else
        inspect="$answer_path"
      fi
    fi
    if [ -n "$answer_path" ] && { [ ! -f "$inspect" ] || [ ! -r "$inspect" ]; }; then
      echo "registry: model '$1' exited 0 without leaving an answer at $inspect — treating as failure (rc=5)" >&2
      exit 5
    fi
    grep -q '[^[:space:]]' "$inspect"
    case "$?" in
      0) exit 0 ;;
      1)
        echo "registry: model '$1' exited 0 with no answer — treating as failure (rc=5)" >&2
        exit 5
        ;;
      *)
        echo "registry_run_answer: could not inspect the answer (grep failed)" >&2
        exit 6
        ;;
    esac
  )
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
