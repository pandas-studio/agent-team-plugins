#!/usr/bin/env bash
# spec-trio-doctor.sh — environment probe + stub smoke for spec-trio.
#
# Usage: spec-trio-doctor.sh
#
# Checks:
#   1. Required tools on PATH: bash, git, jq, sha256sum/shasum.
#   2. Optional tools: tmux (team-name detection), claude (real runs).
#   3. Plugin layout intact (bin/, lib/, lib/roles/, prompts/).
#   4. Cross-plugin dependencies on PATH:
#        - ask-codex.sh / ask-gemini.sh from dev-trio plugin (always required
#          unless --dry-run / --autoship / --no-research; warn-not-fail here).
#   5. Stub smoke: runs spec-trio.sh --dry-run --max-iter 1 in a temp dir and
#      asserts the three stage manifests are well-formed with the spec-* variant
#      strings and verdict=SHIP on the dry-run reviewer manifest.
#
# Stub smokes are *necessary but not sufficient* — verdict / scope-gate /
# parse-affecting changes need a real-CLI dry-run on top (and the comprehensive
# tests/smoke-pr5.sh which exercises both scope gates plus coverage rollup).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
DIM=$'\033[2m'
RESET=$'\033[0m'

ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED"    "$RESET" "$1"; FAILED=1; }
note() { printf '    %s%s%s\n' "$DIM"    "$1"     "$RESET"; }

FAILED=0

echo "spec-trio doctor — plugin root: $PLUGIN_ROOT"
echo

echo "1. Required tools"
for t in bash git jq; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else fail "$t — missing (REQUIRED)"; fi
done
if command -v sha256sum >/dev/null 2>&1; then ok "sha256sum — $(command -v sha256sum)"
elif command -v shasum >/dev/null 2>&1; then ok "shasum — $(command -v shasum) (manifest.sh fallback)"
else fail "neither sha256sum nor shasum found — manifest prompt-hashing will fail"; fi

echo
echo "2. Optional tools"
for t in tmux claude; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else
    case "$t" in
      tmux)   warn "tmux — missing (team-name detection falls back to AGENT_TEAM env / 'default')" ;;
      claude) warn "claude — missing (override via CLAUDE_CLI / PLANNER_CLI / CODER_CLI; doctor's stub smoke uses --dry-run so does not need it)" ;;
    esac
  fi
done

echo
echo "3. Plugin layout"
for rel in bin/spec-trio.sh bin/spec-coverage.sh bin/spec-trio-doctor.sh \
           lib/common.sh lib/manifest.sh lib/spec-helpers.sh \
           lib/roles/planner.md lib/roles/worker.md lib/roles/reviewer.md \
           prompts/spec.md.template prompts/BACKLOG.md.template prompts/fix_plan.md.template \
           tests/smoke-pr5.sh \
           skills/bootstrap/SKILL.md \
           .claude-plugin/plugin.json; do
  p="$PLUGIN_ROOT/$rel"
  if [ -f "$p" ]; then ok "$rel"
  else fail "$rel — missing at $p"; fi
done

echo
echo "4. Cross-plugin dependencies (PATH)"
if command -v ask-codex.sh >/dev/null 2>&1; then
  ok "ask-codex.sh — $(command -v ask-codex.sh) (dev-trio plugin; required for the reviewer stage)"
else
  warn "ask-codex.sh — missing (install dev-trio plugin: /plugin install dev-trio@pandas-studio; only --dry-run / --autoship can run without it)"
fi
if command -v ask-gemini.sh >/dev/null 2>&1; then
  ok "ask-gemini.sh — $(command -v ask-gemini.sh) (dev-trio plugin; required for the NEED RESEARCH branch)"
else
  warn "ask-gemini.sh — missing (install dev-trio plugin; or pass --no-research)"
fi

echo
echo "5. Stub smoke (spec-trio --dry-run --max-iter 1 → 3 manifests)"
if [ "$FAILED" = "1" ]; then
  warn "skipping smoke — prior REQUIRED checks failed"
else
  TMPDIR_SMOKE=$(mktemp -d -t spec-trio-doctor-XXXXXX)
  trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

  # Seed a minimal spec + single-task backlog.
  cat > "$TMPDIR_SMOKE/spec.md" <<'EOF'
# Spec — doctor smoke
## §1 Goals
Trivial smoke target — produce a §5.1 plan manifest.
## §5 Test criteria
### §5.1 doctor smoke marker
EOF
  printf -- '- [ ] (§5.1) doctor smoke task\n' > "$TMPDIR_SMOKE/BACKLOG.md"

  pushd "$TMPDIR_SMOKE" >/dev/null
  ( cd "$TMPDIR_SMOKE" && git init -q && git -c user.email=d@test -c user.name=doctor commit --allow-empty -qm seed )
  AGENT_TEAM="doctor-smoke" \
  SPEC_TRIO_WORKSPACE="$TMPDIR_SMOKE/.spec-trio" \
  TMUX="" \
    "$PLUGIN_ROOT/bin/spec-trio.sh" \
      --spec "$TMPDIR_SMOKE/spec.md" \
      --backlog "$TMPDIR_SMOKE/BACKLOG.md" \
      --max-iter 1 --dry-run \
      >"$TMPDIR_SMOKE/smoke.out" 2>"$TMPDIR_SMOKE/smoke.err"
  RC=$?
  popd >/dev/null

  if [ "$RC" -ne 0 ]; then
    fail "spec-trio.sh --dry-run exited rc=$RC"
    note "stderr: $(head -5 "$TMPDIR_SMOKE/smoke.err" 2>/dev/null)"
  else
    ok "spec-trio.sh --dry-run completed (rc=0)"
  fi

  LOG_DIR_SMOKE="$TMPDIR_SMOKE/.spec-trio/log/doctor-smoke"
  if [ ! -L "$LOG_DIR_SMOKE/latest-spec-trio.log" ]; then
    fail "latest-spec-trio.log symlink not created at $LOG_DIR_SMOKE"
  else
    ok "latest-spec-trio.log symlink created"
  fi

  for stage in plan code review; do
    MANIFEST=$(ls "$LOG_DIR_SMOKE"/spec-trio-*-iter-1-${stage}.manifest.json 2>/dev/null | tail -1)
    if [ -z "$MANIFEST" ]; then
      fail "no $stage manifest emitted under $LOG_DIR_SMOKE"
      continue
    fi
    if ! jq . "$MANIFEST" >/dev/null 2>&1; then
      fail "$stage manifest not well-formed JSON: $MANIFEST"
      continue
    fi
    ok "$stage manifest well-formed: $(basename "$MANIFEST")"
    VARIANT=$(jq -r '.variant' "$MANIFEST")
    if [ "$VARIANT" = "spec-$stage" ]; then
      ok "  variant=spec-$stage"
    else
      fail "  variant mismatch: expected spec-$stage, got: $VARIANT"
    fi
  done

  REVIEW_MAN=$(ls "$LOG_DIR_SMOKE"/spec-trio-*-iter-1-review.manifest.json 2>/dev/null | tail -1)
  if [ -n "$REVIEW_MAN" ]; then
    V=$(jq -r '.verdict' "$REVIEW_MAN")
    if [ "$V" = "SHIP" ]; then
      ok "dry-run review verdict=SHIP"
    else
      fail "dry-run review verdict mismatch: expected SHIP, got: $V"
    fi
  fi

  # Confirm workspace-scoped paths landed under TMPDIR_SMOKE (not the plugin root).
  case "$LOG_DIR_SMOKE" in
    "$TMPDIR_SMOKE"/*) ok "logs landed under workspace (not plugin install dir)" ;;
    *) fail "logs landed outside workspace: $LOG_DIR_SMOKE" ;;
  esac
fi

echo
if [ "$FAILED" = "1" ]; then
  printf '%sspec-trio doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sspec-trio doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — verdict / scope-gate changes still need real-CLI dry-run + tests/smoke-pr5.sh)%s\n' "$DIM" "$RESET"
fi
