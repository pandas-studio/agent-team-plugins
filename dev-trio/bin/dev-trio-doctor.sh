#!/usr/bin/env bash
# dev-trio-doctor.sh — environment probe + stub-CLI smoke for dev-trio.
#
# Usage: dev-trio-doctor.sh [--research | --smoke-only]
# --research is a read-only researcher check: no inference, auth subprocess,
# stub runs, or configuration writes. A pass does not verify research access.
# --smoke-only skips the PM host and role CLI/login probes, which read this
# machine's configuration and auth state, and keeps the rest. It is how
# scripts/check.sh runs the doctor.
#
# Default-mode checks (without --research):
#   1. Helpers and resolved role CLIs; Claude login for Codex PM; optional tmux.
#   2. Plugin layout intact (ask-reviewer.sh / ask-researcher.sh / agent-team-models.sh /
#      dashboard.sh / team-layout.sh / lib/manifest.sh / lib/registry.sh /
#      lib/runstate.sh /
#      lib/roles/*.md / lib/pm.md).
#   3. Stub-CLI smoke: runs ask-researcher.sh against a tmp stub matching
#      `agy [flags] -p PROMPT` shape (with an isolated empty models config so the
#      built-in researcher=agy default applies), then asserts the manifest
#      JSON is well-formed and contains variant=dev-trio-research with
#      role[0].model=agy.
#   4. Registry smoke: agent-team-models list/preset/set-role/doctor/remove
#      against an isolated config (built-ins + kimi-code preset round-trip).
#
# Stub smokes are *necessary but not sufficient* — verdict / dashboard /
# parse-affecting changes need a real-CLI dry-run on top.
set -uo pipefail

RESEARCH_ONLY=false
SMOKE_ONLY=false
case "${1:-}" in
  '') ;;
  --research) RESEARCH_ONLY=true; shift ;;
  --smoke-only) SMOKE_ONLY=true; shift ;;
  --help|-h)
    echo 'usage: dev-trio-doctor.sh [--research | --smoke-only]'
    echo '  --research    Read-only researcher setup checks; no inference or settings changes.'
    echo '  --smoke-only  Skip the PM host and role CLI/login probes; run the rest.'
    exit 0 ;;
  *) echo 'usage: dev-trio-doctor.sh [--research | --smoke-only]' >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo 'usage: dev-trio-doctor.sh [--research | --smoke-only]' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/registry.sh
. "$PLUGIN_ROOT/lib/registry.sh" || exit 2
# shellcheck source=../lib/host.sh
. "$PLUGIN_ROOT/lib/host.sh"
# The smokes pin their own host; only the live probes read the caller's.
if [ "$SMOKE_ONLY" = false ]; then PM_HOST="$(dev_trio_host)" || exit $?; fi

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
DIM=$'\033[2m'
RESET=$'\033[0m'

ok()    { printf '  %s✓%s %s\n'  "$GREEN"  "$RESET" "$1"; }
warn()  { printf '  %s!%s %s\n'  "$YELLOW" "$RESET" "$1"; }
fail()  { printf '  %s✗%s %s\n'  "$RED"    "$RESET" "$1"; FAILED=1; }
note()  { printf '    %s%s%s\n'  "$DIM"    "$1"     "$RESET"; }

FAILED=0

if [ "$RESEARCH_ONLY" = true ]; then
  command -v python3 >/dev/null 2>&1 || { fail 'python3 is required'; exit 1; }
  config="$(registry_config_file)"
  if [ -e "$config" ] && ! jq -e '
    type == "object" and
    ((.models // {}) | type == "object") and
    ((.roles // {}) | type == "object")
  ' "$config" >/dev/null 2>&1; then
    fail "model registry is unreadable or malformed: $config"
    note 'Fix the registry JSON before checking research. No invocation started.'
    exit 1
  fi
  model="$(dev_trio_resolve_role researcher)" || { fail 'researcher model resolution failed'; exit 1; }
  registry_model_exists "$model" || { fail "unregistered researcher: $model"; exit 1; }
  binary="$(REGISTRY_CMD_OVERRIDE="${RESEARCHER_CLI:-}" registry_resolve_command "$model")" || {
    fail "researcher binary resolution failed for model: $model"
    note 'Check the selected model definition and CLI overrides. No invocation started.'
    exit 1
  }
  # Only known, unmodified built-ins promise a non-inference --version flag.
  # A custom wrapper may interpret any argument as a prompt, so never probe it.
  standard=false
  definition="$(_registry_model_def "$model")"
  builtin="$(_registry_builtin_models | jq -c --arg id "$model" '.[$id] // null')"
  env_command="$(printf '%s' "$definition" | jq -r '.env_command // ""')"
  if [ "$builtin" != null ] && [ "$definition" = "$builtin" ] &&
     [ -z "${RESEARCHER_CLI:-}" ] && [ "$binary" = "$(printf '%s' "$definition" | jq -r '.command')" ]; then
    # Even an override with the same spelling has an explicitly custom contract.
    if [ -z "$env_command" ] || [ -z "${!env_command:-}" ]; then standard=true; fi
  fi
  exec python3 "$PLUGIN_ROOT/lib/research_doctor.py" "$model" "$binary" "$standard" \
    "$HOME/.gemini/antigravity-cli/settings.json"
fi

echo "dev-trio doctor — plugin root: $PLUGIN_ROOT"
echo

echo "1. Required tools"
for t in jq python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else fail "$t — missing (REQUIRED)"; fi
done
if command -v tmux >/dev/null 2>&1; then ok "tmux — optional dashboards available"
else warn "tmux missing — research and review still work"; fi
if [ "$SMOKE_ONLY" = true ]; then
  note "role CLI/login checks skipped (--smoke-only)"
else
  for role in researcher reviewer; do
    model="$(dev_trio_resolve_role "$role")" || { fail "$role resolution failed"; continue; }
    case "$role" in
      researcher) override="${RESEARCHER_CLI:-}" ;;
      reviewer) override="${REVIEWER_CLI:-}" ;;
    esac
    binary="$(REGISTRY_CMD_OVERRIDE="$override" registry_resolve_command "$model")" || {
      fail "$role binary resolution failed"; continue;
    }
    if command -v "$binary" >/dev/null 2>&1; then
      ok "$role -> $model ($binary); PM=$PM_HOST"
      if ! REGISTRY_CMD_OVERRIDE="$override" dev_trio_check_cli "$model"; then
        fail "$role CLI/login check failed"
      fi
    else
      warn "$role -> $model: $binary missing; live invocation unavailable"
    fi
  done
fi
if command -v sha256sum >/dev/null 2>&1; then ok "sha256sum — $(command -v sha256sum)"
elif command -v shasum >/dev/null 2>&1; then ok "shasum — $(command -v shasum) (manifest.sh fallback)"
else fail "neither sha256sum nor shasum found — manifest hashing will fail"; fi

echo
echo "2. Plugin layout"
for rel in bin/ask-reviewer.sh bin/ask-researcher.sh bin/agent-team-models.sh \
           bin/dashboard.sh bin/team-layout.sh \
           lib/manifest.sh lib/registry.sh lib/runstate.sh lib/host.sh \
           lib/research_doctor.py lib/workspace_snapshot.py \
           lib/pm.md lib/pm-codex.md \
           lib/roles/researcher.md lib/roles/reviewer.md; do
  p="$PLUGIN_ROOT/$rel"
  if [ -f "$p" ]; then ok "$rel"
  else fail "$rel — missing at $p"; fi
done

echo
echo "3. Stub-CLI smoke (ask-researcher.sh → manifest)"
if [ "$FAILED" = "1" ]; then
  warn "skipping smoke — prior checks failed"
else
  TMPDIR_SMOKE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

  STUB_AGY="$TMPDIR_SMOKE/stub-agy.sh"
  cat > "$STUB_AGY" <<'STUB'
#!/usr/bin/env bash
# Stub matching `agy [--log-file F] [--add-dir D] -p PROMPT` per smoke-test
# stub-wrapper rule: the prompt stays last, flags may precede -p (#103).
# Echoes a canonical-shaped lead paragraph so dashboard.sh can parse it.
if [ "$#" -lt 2 ] || [ "${@: -2:1}" != "-p" ]; then echo "stub-agy: expected -p PROMPT last, got: $*" >&2; exit 2; fi
cat <<'OUT'
LangGraph streaming can use the async iterator returned by graph.astream(input).

See https://docs.langchain.com/oss/python/langgraph/streaming for details.
OUT
STUB
  chmod +x "$STUB_AGY"

  # agy home inside the smoke dir: the wrapper pins a --log-file under
  # $DEV_TRIO_AGY_HOME/log when writable, and the real one must not collect
  # a stub run's log on every check.
  mkdir -p "$TMPDIR_SMOKE/agy-home/log"
  pushd "$TMPDIR_SMOKE" >/dev/null
  # Isolate from the user's shared config + role/CLI envs so the built-in
  # researcher=agy default (and the AGY_CLI stub) deterministically apply.
  DEV_TRIO_PM_HOST=claude \
  AGENT_TEAM="doctor-smoke" \
  DEV_TRIO_LOG_DIR="$TMPDIR_SMOKE/.dev-trio/log" \
  AGENT_TEAM_MODELS_CONFIG="$TMPDIR_SMOKE/models.json" \
  DEV_TRIO_RESEARCHER_MODEL="" \
  RESEARCHER_CLI="" \
  AGY_CLI="$STUB_AGY" \
  DEV_TRIO_AGY_HOME="$TMPDIR_SMOKE/agy-home" \
  TMUX="" \
    "$PLUGIN_ROOT/bin/ask-researcher.sh" "doctor smoke: what is LangGraph streaming?" \
    </dev/null >"$TMPDIR_SMOKE/smoke.out" 2>"$TMPDIR_SMOKE/smoke.err"
  RC=$?
  popd >/dev/null

  if [ "$RC" -ne 0 ]; then
    fail "ask-researcher.sh exited with rc=$RC"
    note "stderr: $(head -3 "$TMPDIR_SMOKE/smoke.err" 2>/dev/null)"
  else
    ok "ask-researcher.sh stub run completed (rc=0)"
  fi

  LOG_DIR_SMOKE="$TMPDIR_SMOKE/.dev-trio/log/doctor-smoke"
  if [ ! -L "$LOG_DIR_SMOKE/latest-agy.log" ]; then
    fail "latest-agy.log symlink not created at $LOG_DIR_SMOKE"
  else
    ok "latest-agy.log symlink created"
  fi

  MANIFEST=$(ls "$LOG_DIR_SMOKE"/agy-*.manifest.json 2>/dev/null | tail -1)
  if [ -z "$MANIFEST" ]; then
    fail "no manifest emitted under $LOG_DIR_SMOKE"
  elif ! jq . "$MANIFEST" >/dev/null 2>&1; then
    fail "manifest is not well-formed JSON: $MANIFEST"
  else
    ok "manifest well-formed: $(basename "$MANIFEST")"
    VARIANT=$(jq -r '.variant' "$MANIFEST")
    if [ "$VARIANT" = "dev-trio-research" ]; then
      ok "variant=dev-trio-research"
    else
      fail "variant mismatch: expected dev-trio-research, got: $VARIANT"
    fi
    MODEL=$(jq -r '.roles[0].model // ""' "$MANIFEST")
    if [ "$MODEL" = "agy" ]; then
      ok "roles[0].model=agy"
    else
      fail "roles[0].model mismatch: expected agy, got: $MODEL"
    fi
    RESOLVED=$(jq -r '.roles[0].prompt_resolved_sha256 // ""' "$MANIFEST")
    if [[ "$RESOLVED" =~ ^[0-9a-f]{64}$ ]]; then
      ok "roles[0].prompt_resolved_sha256 = 64-hex (RFC 0004 PR 10)"
    else
      fail "prompt_resolved_sha256 not a 64-hex string: '$RESOLVED'"
    fi
  fi
fi

echo
echo "4. Registry smoke (agent-team-models)"
if [ "$FAILED" = "1" ]; then
  warn "skipping registry smoke — prior checks failed"
else
  # Neutralize ambient role overrides so config-binding resolution is observable.
  # Every name in registry.sh's _registry_role_envname: its doctor checks all roles.
  unset DEV_TRIO_RESEARCHER_MODEL DEV_TRIO_REVIEWER_MODEL \
        DEBATE_GENERATOR_MODEL DEBATE_CRITIC_MODEL \
        LANGGRAPH_CONDUCTOR_PLANNER_MODEL LANGGRAPH_CONDUCTOR_CODER_MODEL \
        LANGGRAPH_CONDUCTOR_RESEARCHER_MODEL LANGGRAPH_CONDUCTOR_REVIEWER_MODEL 2>/dev/null || true
  ATM="$PLUGIN_ROOT/bin/agent-team-models.sh"
  REG_TMP=$(mktemp -d)
  REG_CFG="$REG_TMP/models.json"
  if [ ! -f "$ATM" ]; then
    fail "agent-team-models.sh not found at $ATM"
  else
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" list >"$REG_TMP/list.out" 2>"$REG_TMP/list.err"; then
      ok "agent-team-models list ran (built-in defaults, empty config)"
    else
      fail "agent-team-models list failed"
      note "stderr: $(head -3 "$REG_TMP/list.err" 2>/dev/null)"
    fi
    if grep -q 'dev-trio.researcher' "$REG_TMP/list.out" 2>/dev/null \
       && grep -q 'agy' "$REG_TMP/list.out" 2>/dev/null; then
      ok "list shows built-in role binding (dev-trio.researcher -> agy)"
    else
      fail "list output missing expected built-in role binding"
    fi
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" preset add kimi-code >/dev/null 2>"$REG_TMP/preset.err"; then
      ok "preset add kimi-code"
    else
      fail "preset add kimi-code failed"
      note "stderr: $(head -3 "$REG_TMP/preset.err" 2>/dev/null)"
    fi
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" set-role dev-trio.reviewer kimi-code >/dev/null 2>"$REG_TMP/setrole.err"; then
      ok "set-role dev-trio.reviewer kimi-code"
    else
      fail "set-role failed"
      note "stderr: $(head -3 "$REG_TMP/setrole.err" 2>/dev/null)"
    fi
    REG_REVIEWER=$(AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" list 2>/dev/null \
      | awk '/^  dev-trio.reviewer/{print $3}')
    if [ "$REG_REVIEWER" = "kimi-code" ]; then
      ok "reviewer role resolves to config binding (kimi-code)"
    else
      fail "reviewer role did not pick up config binding (got: ${REG_REVIEWER:-<empty>})"
    fi
    # kimi binary is absent on PATH → doctor must warn, not hard-fail.
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" doctor >"$REG_TMP/doctor.out" 2>&1; then
      ok "agent-team-models doctor passed (absent binaries warn, not fail)"
    else
      fail "agent-team-models doctor reported a hard failure"
      note "$(grep -i 'FAIL' "$REG_TMP/doctor.out" 2>/dev/null | head -2)"
    fi
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" remove kimi-code >/dev/null 2>"$REG_TMP/rm.err"; then
      fail "remove of in-use model unexpectedly succeeded"
    else
      ok "remove refuses an in-use model without --force"
    fi
    if AGENT_TEAM_MODELS_CONFIG="$REG_CFG" "$ATM" remove kimi-code --force --fallback codex >/dev/null 2>"$REG_TMP/rmf.err"; then
      ok "remove --force --fallback codex reassigns role then deletes"
    else
      fail "remove --force --fallback failed"
      note "stderr: $(head -3 "$REG_TMP/rmf.err" 2>/dev/null)"
    fi
  fi
  rm -rf "$REG_TMP"
fi

echo
if [ "$FAILED" = "1" ]; then
  printf '%sdev-trio doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sdev-trio doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — verdict/dashboard changes still need a real-CLI dry-run)%s\n' "$DIM" "$RESET"
fi
