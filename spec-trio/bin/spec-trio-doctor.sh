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
#        - ask-codex.sh / ask-agy.sh from dev-trio plugin (always required
#          unless --dry-run / --autoship / --no-research; warn-not-fail here).
#   5. Stub smoke: runs spec-trio.sh --dry-run --max-iter 1 in a temp dir and
#      asserts the three stage manifests are well-formed with the spec-* variant
#      strings and verdict=SHIP on the dry-run reviewer manifest.
#   6. Stub-CLI smoke (Stage 3): the reviewer verdict MUST come from ask-codex's
#      --output-last-message (.final.md), not the decoy stdout, and the .final.md
#      MUST land in spec-trio's durable log tree (pinned DEV_TRIO_LOG_DIR).
#   7. Stub-CLI smoke (Stage 1.5): a planner `## NEED RESEARCH` block fetches
#      ask-agy.sh research pre-coding and grafts it into the first coder prompt;
#      failed research is not injected and (under --autoship) routes to NEEDS-FIX.
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
           lib/common.sh lib/manifest.sh lib/spec-helpers.sh lib/pm.md \
           lib/roles/planner.md lib/roles/worker.md lib/roles/reviewer.md \
           prompts/spec.md.template prompts/BACKLOG.md.template prompts/fix_plan.md.template \
           tests/smoke-pr5.sh \
           skills/bootstrap/SKILL.md skills/install-pm/SKILL.md \
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
if command -v ask-agy.sh >/dev/null 2>&1; then
  ok "ask-agy.sh — $(command -v ask-agy.sh) (dev-trio plugin; Antigravity researcher; required for the NEED RESEARCH branches)"
else
  warn "ask-agy.sh — missing (install dev-trio plugin; or pass --no-research)"
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
echo "6. Stub-CLI smoke (spec-trio Stage 3 — verdict from codex .final.md)"
# Real-logic regression guard for the forward-port: the reviewer's verdict MUST
# come from ask-codex.sh's --output-last-message file (codex-<TS>.final.md), NOT
# the streamed stdout the dev-trio contract declares unreliable; and that file
# MUST land in spec-trio's durable log tree (pinned DEV_TRIO_LOG_DIR) so it
# survives worktree teardown. Stub ask-codex.sh emits a clean SHIP in the
# .final.md while streaming a DECOY NEEDS-FIX on stdout — only parsing the
# .final.md yields SHIP. Runs with --no-strict-scope so a bare `true` planner
# (empty plan, no <allowed-paths>) still reaches the reviewer.
if [ "$FAILED" = "1" ]; then
  warn "skipping Stage-3 smoke — prior REQUIRED checks failed"
else
  T2=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE" "$T2"' EXIT

  STUB_BIN="$T2/stubbin"
  mkdir -p "$STUB_BIN"
  # Stub mimics the dev-trio ask-codex.sh output contract: authoritative review
  # in $FINAL, an unreliable/decoy transcript on stdout, the `(... rc=…)` line on
  # stderr. STUB_MODE selects the scenario. Ignores --with-spec et al.
  cat > "$STUB_BIN/ask-codex.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
TEAM="${AGENT_TEAM:-default}"
LOG_DIR="${DEV_TRIO_LOG_DIR:-$PWD/.dev-trio/log}/$TEAM"
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/codex-$TS.log"
FINAL="$LOG_DIR/codex-$TS.final.md"
ln -sfn "codex-$TS.log" "$LOG_DIR/latest-codex.log"
ln -sfn "codex-$TS.final.md" "$LOG_DIR/latest-codex.final.md"
case "${STUB_MODE:-final-ship}" in
  final-ship)
    # Authoritative final = clean SHIP in codex's native `## Verdict` form.
    # Stream = DECOY NEEDS-FIX: if spec-trio parsed the stream instead of the
    # final, the SHIP assert fails.
    printf '## Verdict\nSHIP — stub: looks good\n' > "$FINAL"
    printf '## Review\nstub stream (do not parse me)\n## Verdict\nNEEDS-FIX — decoy\n'
    ;;
  empty-placeholder)
    # No clean final; the stream carries only the role-prompt placeholder
    # (`<one of: ...>`), which the hardened parse must NOT register.
    : > "$FINAL"
    printf '## Verdict\n<one of: SHIP / NEEDS-FIX / DISCUSS / OUT-OF-SCOPE> — <reason>\n'
    ;;
esac
echo "(log: $LOG, final: $FINAL, rc=0)" >&2
exit 0
STUB
  chmod +x "$STUB_BIN/ask-codex.sh"

  # run_spec_case MODE CWD — single-iter spec-trio loop in a fresh git repo with
  # the stub on PATH and claude stubbed to `true` (no real model). --no-strict-
  # scope + --no-research isolates the Stage-3 verdict path.
  run_spec_case() {
    local mode="$1" cwd="$2"
    mkdir -p "$cwd"
    git -C "$cwd" init -q
    git -C "$cwd" config user.email doctor@example.invalid
    git -C "$cwd" config user.name doctor
    printf '# Spec\n## §1 Goals\nstub\n## §5 Test criteria\n### §5.1 marker\n' > "$cwd/spec.md"
    echo seed > "$cwd/seed.txt"
    git -C "$cwd" add -A >/dev/null 2>&1
    git -C "$cwd" commit -qm seed >/dev/null 2>&1
    printf -- '- [ ] (§5.1) stub smoke task\n' > "$cwd/BACKLOG.md"
    (
      cd "$cwd" && \
      AGENT_TEAM="doctor-spec" \
      SPEC_TRIO_WORKSPACE="$cwd/.spec-trio" \
      STUB_MODE="$mode" \
      PLANNER_CLI=true CODER_CLI=true \
      TMUX="" \
      PATH="$STUB_BIN:$PATH" \
      "$PLUGIN_ROOT/bin/spec-trio.sh" --spec "$cwd/spec.md" --backlog "$cwd/BACKLOG.md" \
        --max-iter 1 --no-strict-scope --no-research \
      >"$cwd/spec.out" 2>"$cwd/spec.err"
    )
  }

  review_verdict() {
    local cwd="$1" m
    m=$(ls "$cwd/.spec-trio/log/doctor-spec"/spec-trio-*-iter-1-review.manifest.json 2>/dev/null | tail -1)
    [ -n "$m" ] && jq -r '.verdict' "$m" 2>/dev/null
  }

  # --- Case A: final-ship — verdict comes from .final.md, not the decoy stream.
  CASE_A="$T2/case-final-ship"
  if run_spec_case final-ship "$CASE_A"; then
    ok "spec-trio loop (final-ship) completed (rc=0)"
  else
    fail "spec-trio loop (final-ship) exited non-zero — see $CASE_A/spec.err"
    note "stderr: $(tail -3 "$CASE_A/spec.err" 2>/dev/null)"
  fi
  VA=$(review_verdict "$CASE_A")
  if [ "$VA" = "SHIP" ]; then
    ok "verdict=SHIP parsed from codex .final.md (decoy stdout NEEDS-FIX ignored)"
  else
    fail "expected verdict=SHIP from .final.md, got: ${VA:-<no manifest>} (regression: parsing streamed stdout?)"
  fi
  # Durability: the .final.md must land under spec-trio's pinned workspace dir
  # (CODEX_FINAL_ROOT=$LOG_DIR/codex; ask-codex appends /$TEAM), NOT in a stray
  # .dev-trio under the run cwd (which a worktree would tear down).
  if [ -e "$CASE_A/.spec-trio/log/doctor-spec/codex/doctor-spec/latest-codex.final.md" ]; then
    ok "codex .final.md pinned under spec-trio workspace (survives worktree teardown)"
  else
    fail "codex .final.md not found under spec-trio workspace — DEV_TRIO_LOG_DIR not pinned?"
  fi
  if [ -e "$CASE_A/.dev-trio" ]; then
    fail "stray .dev-trio created in run cwd — DEV_TRIO_LOG_DIR redirect leaked"
  else
    ok "no stray .dev-trio in run cwd"
  fi

  # --- Case B: empty-placeholder — the placeholder must NOT register as a verdict.
  CASE_B="$T2/case-empty-placeholder"
  run_spec_case empty-placeholder "$CASE_B" || true
  VB=$(review_verdict "$CASE_B")
  if [ "$VB" = "null" ]; then
    ok "empty final + placeholder stream → verdict=null (hardened parse rejects placeholder)"
  else
    fail "expected verdict=null for placeholder-only stream, got: ${VB:-<no manifest>}"
  fi
fi

echo
echo "7. Stub-CLI smoke (spec-trio Stage 1.5 — planner-driven pre-coding research)"
# Regression guard for the planner NEED RESEARCH path: when the PLANNER emits a
# `## NEED RESEARCH` block, spec-trio must fetch research via ask-agy.sh BEFORE
# Stage 2 and graft it into the FIRST coder prompt. Runs under --autoship (Stage
# 3 skipped → no codex stub needed) and --no-strict-scope with an empty allowlist
# so the orthogonal scope gates (exercised by tests/smoke-pr5.sh) don't interfere
# — the temp repo has no .gitignore, so the .spec-trio/ workspace churn would
# otherwise trip scope-gate-2. This section isolates the Stage 1.5 wiring.
if [ "$FAILED" = "1" ]; then
  warn "skipping Stage-1.5 smoke — prior REQUIRED checks failed"
else
  T7=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE" "$T2" "$T7"' EXIT
  S7="$T7/stubbin"
  mkdir -p "$S7"
  cat > "$S7/stub-planner.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'PLAN'
## Plan
1. implement the helper in foo (spec §5.1)
## Verify
- grep helper foo.txt
## NEED RESEARCH
- What is the correct signature of the helper?
PLAN
STUB
  cat > "$S7/ask-agy.sh" <<'STUB'
#!/usr/bin/env bash
echo "DOCTOR-RESEARCH-ANSWER: helper(x) -> y (agy stub)"
STUB
  cat > "$S7/stub-coder.sh" <<'STUB'
#!/usr/bin/env bash
# Capture the coder prompt (arg after -p) so the harness can assert the graft.
printf '%s' "$2" > "$CODER_CAPTURE"
echo "coder ran (stub)"
STUB
  chmod +x "$S7"/*.sh

  run_research_case() {
    # run_research_case CWD TEAM — single-iter --autoship spec-trio loop.
    local cwd="$1" team="$2"
    mkdir -p "$cwd"
    git -C "$cwd" init -q
    git -C "$cwd" config user.email doctor@example.invalid
    git -C "$cwd" config user.name doctor
    printf '# Spec\n## §1 Goals\nstub\n## §5 Test criteria\n### §5.1 marker\n' > "$cwd/spec.md"
    git -C "$cwd" add -A >/dev/null 2>&1
    git -C "$cwd" commit -qm seed >/dev/null 2>&1
    printf -- '- [ ] (§5.1) task that needs research\n' > "$cwd/BACKLOG.md"
    (
      cd "$cwd" && \
      AGENT_TEAM="$team" \
      SPEC_TRIO_WORKSPACE="$cwd/.spec-trio" \
      PLANNER_CLI="$S7/stub-planner.sh" \
      CODER_CLI="$S7/stub-coder.sh" \
      CODER_CAPTURE="$cwd/coder-prompt.txt" \
      TMUX="" \
      PATH="$S7:$PATH" \
      "$PLUGIN_ROOT/bin/spec-trio.sh" --spec "$cwd/spec.md" --backlog "$cwd/BACKLOG.md" \
        --max-iter 1 --autoship --no-strict-scope \
      >"$cwd/spec.out" 2>"$cwd/spec.err"
    )
  }

  # --- Case A: research succeeds → fetched pre-coding + grafted into coder prompt.
  CWD7="$T7/run"
  run_research_case "$CWD7" "doctor-research" || { fail "Stage-1.5 smoke run exited non-zero — see $CWD7/spec.err"; note "stderr: $(tail -3 "$CWD7/spec.err" 2>/dev/null)"; }
  RP7=$(ls "$CWD7/.spec-trio/log/doctor-research"/spec-trio-*-iter-1-research-plan.log 2>/dev/null | tail -1)
  if [ -n "$RP7" ] && grep -q "DOCTOR-RESEARCH-ANSWER" "$RP7"; then
    ok "planner NEED RESEARCH → Stage 1.5 fetched agy research pre-coding"
  else
    fail "Stage 1.5 did not run — no research-plan log with the agy answer (planner NEED RESEARCH ignored?)"
  fi
  if grep -q "DOCTOR-RESEARCH-ANSWER" "$CWD7/coder-prompt.txt" 2>/dev/null \
     && grep -q "<research>" "$CWD7/coder-prompt.txt" 2>/dev/null; then
    ok "pre-coding research grafted into the first coder prompt (<research> block)"
  else
    fail "research not grafted into coder prompt — Stage 1.5 → Stage 2 wiring broken"
  fi

  # --- Case B: research FAILS — must NOT inject the error output, and under
  # --autoship must NOT ship (the planner declared the task depends on it).
  cat > "$S7/ask-agy.sh" <<'STUB'
#!/usr/bin/env bash
echo "FATAL: agy stub failure" >&2
exit 1
STUB
  chmod +x "$S7/ask-agy.sh"
  CWD7B="$T7/run-fail"
  run_research_case "$CWD7B" "doctor-research-fail" || true
  # Grep for the error OUTPUT, not the `<research>` tag name (the coder role's
  # trust-boundary preamble mentions `<research>` literally).
  if grep -q "FATAL: agy stub failure" "$CWD7B/coder-prompt.txt" 2>/dev/null; then
    fail "failed research (error output) was injected into the coder prompt (should be suppressed)"
  else
    ok "failed research output not injected into coder prompt"
  fi
  MVB=$(ls "$CWD7B/.spec-trio/log/doctor-research-fail"/spec-trio-*-iter-1-review.manifest.json 2>/dev/null | tail -1)
  if [ -n "$MVB" ] && [ "$(jq -r '.verdict' "$MVB" 2>/dev/null)" = "NEEDS-FIX" ]; then
    ok "research-failed under --autoship → NEEDS-FIX (refused to ship research-dependent work)"
  else
    fail "research-failed under --autoship did not route to NEEDS-FIX (verdict: $([ -n "$MVB" ] && jq -r '.verdict' "$MVB" 2>/dev/null || echo '<no manifest>'))"
  fi
fi

echo
if [ "$FAILED" = "1" ]; then
  printf '%sspec-trio doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sspec-trio doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — verdict / scope-gate changes still need real-CLI dry-run + tests/smoke-pr5.sh)%s\n' "$DIM" "$RESET"
fi
