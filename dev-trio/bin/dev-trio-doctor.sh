#!/usr/bin/env bash
# dev-trio-doctor.sh — environment probe + stub-CLI smoke for dev-trio.
#
# Usage: dev-trio-doctor.sh
#
# Checks:
#   1. Required tools on PATH: tmux, agy, codex, jq, sha256sum/shasum.
#   2. Plugin layout intact (ask-codex.sh / ask-agy.sh / dashboard.sh /
#      team-layout.sh / lib/manifest.sh / lib/roles/*.md / lib/pm.md).
#   3. Stub-CLI smoke: runs ask-agy.sh against a tmp stub matching
#      `agy -p "$2"` shape, then asserts the manifest JSON is well-formed
#      and contains variant=dev-trio-research with role[0].model=agy.
#
# Stub smokes are *necessary but not sufficient* — verdict / dashboard /
# parse-affecting changes need a real-CLI dry-run on top.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "dev-trio doctor — plugin root: $PLUGIN_ROOT"
echo

echo "1. Required tools"
for t in tmux jq; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else fail "$t — missing (REQUIRED)"; fi
done
for t in agy codex; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else
    # Inline the env-var hint per CLI — portable case beats Bash-4-only ${t^^}.
    case "$t" in
      agy)    env_hint="AGY_CLI or RESEARCHER_CLI" ;;
      codex)  env_hint="CODEX_CLI or REVIEWER_CLI" ;;
      *)      env_hint="(no documented override)" ;;
    esac
    warn "$t — missing (override via $env_hint; stub smoke below does not need it)"
  fi
done
if command -v sha256sum >/dev/null 2>&1; then ok "sha256sum — $(command -v sha256sum)"
elif command -v shasum >/dev/null 2>&1; then ok "shasum — $(command -v shasum) (manifest.sh fallback)"
else fail "neither sha256sum nor shasum found — manifest hashing will fail"; fi

echo
echo "2. Plugin layout"
for rel in bin/ask-codex.sh bin/ask-agy.sh bin/dashboard.sh bin/team-layout.sh \
           lib/manifest.sh lib/pm.md lib/roles/researcher.md lib/roles/reviewer.md; do
  p="$PLUGIN_ROOT/$rel"
  if [ -f "$p" ]; then ok "$rel"
  else fail "$rel — missing at $p"; fi
done

echo
echo "3. Stub-CLI smoke (ask-agy.sh → manifest)"
if [ "$FAILED" = "1" ]; then
  warn "skipping smoke — prior checks failed"
else
  TMPDIR_SMOKE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

  STUB_AGY="$TMPDIR_SMOKE/stub-agy.sh"
  cat > "$STUB_AGY" <<'STUB'
#!/usr/bin/env bash
# Stub matching `agy -p "$2"` shape per smoke-test stub-wrapper rule.
# Echoes a canonical-shaped lead paragraph so dashboard.sh can parse it.
if [ "${1:-}" != "-p" ]; then echo "stub-agy: expected -p as \$1, got: ${1:-}" >&2; exit 2; fi
cat <<'OUT'
LangGraph 0.2 streaming API uses an async iterator returned by graph.astream(input).

See https://langchain-ai.github.io/langgraph/how-tos/streaming/ for details.
OUT
STUB
  chmod +x "$STUB_AGY"

  pushd "$TMPDIR_SMOKE" >/dev/null
  AGENT_TEAM="doctor-smoke" \
  DEV_TRIO_LOG_DIR="$TMPDIR_SMOKE/.dev-trio/log" \
  AGY_CLI="$STUB_AGY" \
  TMUX="" \
    "$PLUGIN_ROOT/bin/ask-agy.sh" "doctor smoke: what is LangGraph 0.2 streaming?" \
    >"$TMPDIR_SMOKE/smoke.out" 2>"$TMPDIR_SMOKE/smoke.err"
  RC=$?
  popd >/dev/null

  if [ "$RC" -ne 0 ]; then
    fail "ask-agy.sh exited with rc=$RC"
    note "stderr: $(head -3 "$TMPDIR_SMOKE/smoke.err" 2>/dev/null)"
  else
    ok "ask-agy.sh stub run completed (rc=0)"
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
if [ "$FAILED" = "1" ]; then
  printf '%sdev-trio doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sdev-trio doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — verdict/dashboard changes still need a real-CLI dry-run)%s\n' "$DIM" "$RESET"
fi
