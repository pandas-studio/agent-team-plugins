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

debate_conductor_normalize_model() {
  local m="${1:-}"
  [ -n "$m" ] || return 0
  if registry_model_exists "$m" 2>/dev/null; then
    printf '%s\n' "$m"
    return 0
  fi
  case "$m" in
    antigravity)
      printf 'agy\n'; return 0 ;;
    kimi)
      if registry_model_exists "kimi-code" 2>/dev/null; then
        printf 'kimi-code\n'; return 0
      fi
      ;;
  esac
  printf '%s\n' "$m"
}

debate_conductor_unknown_model_hint() {
  case "${1:-}" in
    kimi|kimi-code)
      printf 'run: agent-team-models preset add kimi-code, or agent-team-models list' ;;
    *)
      printf 'run: agent-team-models list' ;;
  esac
}

debate_conductor_resolve_role() {
  local role="$1" cli="${2:-}" gen="${3:-}"
  local key="debate-conductor.$role" cfg
  if [ -n "$cli" ]; then debate_conductor_normalize_model "$cli"; return 0; fi
  case "$role" in
    generator)
      if [ -n "${DEBATE_GENERATOR_MODEL:-}" ]; then debate_conductor_normalize_model "$DEBATE_GENERATOR_MODEL"; return 0; fi
      if [ -n "${DEBATE_PRIMARY_GEN:-}" ]; then debate_conductor_normalize_model "$DEBATE_PRIMARY_GEN"; return 0; fi
      ;;
    critic)
      if [ -n "${DEBATE_CRITIC_MODEL:-}" ]; then debate_conductor_normalize_model "$DEBATE_CRITIC_MODEL"; return 0; fi
      ;;
    *) echo "debate-conductor: unknown role '$role'" >&2; return 2 ;;
  esac
  # A malformed config is rc 3 here, not "no binding" (#133).
  cfg="$(registry_config_role "$key")" || return 3
  if [ -n "$cfg" ]; then debate_conductor_normalize_model "$cfg"; return 0; fi
  debate_conductor_default_role "$role" "$gen"
}

# Check availability and, for Claude under Codex PM, login. Authentication and
# billing stay under Claude Code's own configuration.
debate_conductor_check_cli() {
  local model="$1" bin host out rc=0 seen
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
  out="$("$bin" auth status --json 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" |
       jq -se 'length == 1 and (.[0] | type) == "object" and .[0].loggedIn == true' >/dev/null 2>&1; then
    return 0
  fi
  # A sandbox that hides Keychain makes a logged-in Claude report exactly what a
  # logged-out one does (loggedIn: false, rc 1), so report what was observed and
  # leave the verdict to whoever knows whether this ran with host approval (#127).
  # CODEX_SANDBOX is printed as a fact, never branched on: it is a hint, not proof.
  seen="$(printf '%s' "$out" | jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0] | has("loggedIn"))
    then "loggedIn=\(.[0].loggedIn | tojson)" else "no login status" end' 2>/dev/null)" || seen=""
  [ -n "$seen" ] || seen="no login status"
  printf 'debate-conductor: Claude login unverified in this environment (auth status: %s, rc=%s%s); no invocation started\n' \
    "$seen" "$rc" "${CODEX_SANDBOX:+, CODEX_SANDBOX=$CODEX_SANDBOX}" >&2
  echo 'debate-conductor: a sandbox can hide the login (for example macOS Keychain); rerun this same command once with host approval, or choose a non-Claude model for this role. If an approved run still fails, check claude auth status in your own terminal.' >&2
  return 2
}

# Prompt note for workspace-aware models (agy) explaining headless execution
# constraints so the model does not trigger an auto-denied shell command (#213).
debate_conductor_agy_exec_note() {
  cat <<'EOF'
# Execution environment
You are running in non-interactive headless print mode (`--input-format text --output-format text`). Interactive permission prompts are impossible and any unapproved `run_command` call is **auto-denied**, which aborts the round immediately.
- Answer directly from `<user_question>` / `<user_context>` (or `<review_target>` / `<research_context>`).
- Do **not** call `run_command` (`rg`, `grep`, `find`, `ls`, `cat`, `head`, `tail`, pipes `|`, `&&`, `||`, `;`, `2>/dev/null`, `$()`, backticks).
- If you need to check a file in the current workspace, use `read_file` on a workspace-relative path (at most a few targeted files) and never access paths outside the current workspace.
EOF
}
