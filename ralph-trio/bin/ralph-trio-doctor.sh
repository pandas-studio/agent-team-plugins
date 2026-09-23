#!/usr/bin/env bash
# ralph-trio-doctor.sh — environment probe + stub-CLI smoke for ralph-trio.
#
# Usage: ralph-trio-doctor.sh
#
# Checks:
#   1. Required tools on PATH: bash, git, jq, sha256sum/shasum, python3.
#   2. Optional tools: tmux (dashboard.sh), claude (real runs).
#   3. Plugin layout intact (bin/ralph-{solo,trio,debate,meta}.sh, dashboard.sh,
#      stop-hook.sh, lib/common.sh, lib/manifest.sh, lib/roles/{planner,worker}.md,
#      prompts/*.template, hooks/settings.snippet.json).
#   4. Cross-plugin dependencies, found as the drivers find them (DEV_TRIO_BIN /
#      DEBATE_CONDUCTOR_BIN, then PATH, then `claude plugin list`; the source is shown):
#        - ask-reviewer.sh / ask-researcher.sh from dev-trio plugin (needed for trio/meta)
#        - debate.sh from debate-conductor plugin (needed for debate)
#      Missing cross-plugin deps WARN (not fail) — solo doesn't need them. An
#      override that names no such script FAILs (the drivers refuse to start).
#   5. Stub-CLI smoke: runs ralph-solo.sh --max-iter 1 --dry-run in a temp dir
#      and asserts the manifest JSON is well-formed with variant=ralph-solo.
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
if [ -f "$PLUGIN_ROOT/lib/plugin-deps.sh" ]; then
  # shellcheck source=SCRIPTDIR/../lib/plugin-deps.sh
  . "$PLUGIN_ROOT/lib/plugin-deps.sh"
fi

# report_dep VAR PLUGIN SCRIPT NEEDED-FOR MISSING-HINT — resolve SCRIPT the way the
# drivers do (lib/plugin-deps.sh) and report where it came from. Sets DEP_FOUND.
report_dep() {
  local rc=0
  DEP_FOUND=""
  if ! command -v resolve_plugin_script >/dev/null 2>&1; then
    fail "$3 — cannot check: lib/plugin-deps.sh did not load"
    return 1
  fi
  resolve_plugin_script "$1" "$2@pandas-studio" "$3" || rc=$?
  case "$rc" in
    0) DEP_FOUND="$RESOLVED_SCRIPT"
       ok "$3 — $RESOLVED_SCRIPT (via $RESOLVED_SOURCE; $2 plugin; $4)" ;;
    2) fail "$3 — $RESOLVED_WHY (it must name the $2 plugin's bin/ directory)" ;;
    *) warn "$3 — missing: $RESOLVED_WHY ($5)" ;;
  esac
}

echo "ralph-trio doctor — plugin root: $PLUGIN_ROOT"
echo

echo "1. Required tools"
for t in bash git jq python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else fail "$t — missing (REQUIRED)"; fi
done
if command -v sha256sum >/dev/null 2>&1; then ok "sha256sum — $(command -v sha256sum)"
elif command -v shasum >/dev/null 2>&1; then ok "shasum — $(command -v shasum) (manifest.sh + sha256_file fallback)"
else fail "neither sha256sum nor shasum found — manifest hashing + prompt tamper detection will fail"; fi

echo
echo "2. Optional tools"
for t in tmux claude; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else
    case "$t" in
      tmux)   warn "tmux — missing (dashboard.sh and team-name detection will fall back)" ;;
      claude) warn "claude — missing (override via CLAUDE_CLI / WORKER_CLI / PLANNER_CLI / CODER_CLI; doctor's stub smoke uses --dry-run so does not need it)" ;;
    esac
  fi
done

echo
echo "3. Plugin layout"
for rel in bin/ralph-solo.sh bin/ralph-trio.sh bin/ralph-debate.sh bin/ralph-meta.sh \
           bin/dashboard.sh bin/stop-hook.sh \
           lib/common.sh lib/manifest.sh lib/plugin-deps.sh lib/pm.md lib/roles/planner.md lib/roles/worker.md \
           prompts/PROMPT.md.template prompts/BACKLOG.md.template prompts/fix_plan.md.template \
           hooks/settings.snippet.json \
           templates/launchd/com.user.ralph.plist.template \
           skills/bootstrap/SKILL.md skills/install-pm/SKILL.md skills/install-stop-hook/SKILL.md \
           .claude-plugin/plugin.json; do
  p="$PLUGIN_ROOT/$rel"
  if [ -f "$p" ]; then ok "$rel"
  else fail "$rel — missing at $p"; fi
done

echo
echo "4. Cross-plugin dependencies"
report_dep DEV_TRIO_BIN dev-trio ask-reviewer.sh "needed for ralph-trio, ralph-meta" \
  "install dev-trio plugin to use ralph-trio.sh / ralph-meta.sh; ralph-solo.sh works without it"
REVIEWER_FOUND="$DEP_FOUND"
report_dep DEV_TRIO_BIN dev-trio ask-researcher.sh "needed for ralph-trio NEED RESEARCH branch" \
  "install dev-trio plugin; or pass --no-research to ralph-trio.sh"
report_dep DEBATE_CONDUCTOR_BIN debate-conductor debate.sh "needed for ralph-debate" \
  "install debate-conductor plugin to use ralph-debate.sh"
# The stub smokes below put their stubs first on PATH. An exported override
# would win over them and route a smoke to the real scripts, so drop it here.
unset DEV_TRIO_BIN DEBATE_CONDUCTOR_BIN

echo
echo "5. Stub-CLI smoke (ralph-solo --max-iter 1 --dry-run → manifest)"
if [ "$FAILED" = "1" ]; then
  warn "skipping smoke — prior REQUIRED checks failed"
else
  TMPDIR_SMOKE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

  # Seed PROMPT.md from the plugin template so the loop has something to read.
  cp "$PLUGIN_ROOT/prompts/PROMPT.md.template" "$TMPDIR_SMOKE/PROMPT.md"

  pushd "$TMPDIR_SMOKE" >/dev/null
  AGENT_TEAM="doctor-smoke" \
  RALPH_TRIO_WORKSPACE="$TMPDIR_SMOKE/.ralph-trio" \
  TMUX="" \
    "$PLUGIN_ROOT/bin/ralph-solo.sh" --max-iter 1 --dry-run --prompt "$TMPDIR_SMOKE/PROMPT.md" \
    >"$TMPDIR_SMOKE/smoke.out" 2>"$TMPDIR_SMOKE/smoke.err"
  RC=$?
  popd >/dev/null

  if [ "$RC" -ne 0 ]; then
    fail "ralph-solo.sh dry-run exited with rc=$RC"
    note "stderr: $(head -5 "$TMPDIR_SMOKE/smoke.err" 2>/dev/null)"
  else
    ok "ralph-solo.sh --dry-run completed (rc=0)"
  fi

  LOG_DIR_SMOKE="$TMPDIR_SMOKE/.ralph-trio/log/doctor-smoke"
  if [ ! -L "$LOG_DIR_SMOKE/latest-ralph-solo.log" ]; then
    fail "latest-ralph-solo.log symlink not created at $LOG_DIR_SMOKE"
  else
    ok "latest-ralph-solo.log symlink created"
  fi
  if [ ! -L "$LOG_DIR_SMOKE/latest-ralph.log" ]; then
    fail "latest-ralph.log symlink not created"
  else
    ok "latest-ralph.log symlink created"
  fi

  MANIFEST=$(ls "$LOG_DIR_SMOKE"/ralph-solo-*-iter-*.manifest.json 2>/dev/null | tail -1)
  if [ -z "$MANIFEST" ]; then
    fail "no manifest emitted under $LOG_DIR_SMOKE"
  elif ! jq . "$MANIFEST" >/dev/null 2>&1; then
    fail "manifest is not well-formed JSON: $MANIFEST"
  else
    ok "manifest well-formed: $(basename "$MANIFEST")"
    VARIANT=$(jq -r '.variant' "$MANIFEST")
    if [ "$VARIANT" = "ralph-solo" ]; then
      ok "variant=ralph-solo"
    else
      fail "variant mismatch: expected ralph-solo, got: $VARIANT"
    fi
    SCHEMA=$(jq -r '.schema_version' "$MANIFEST")
    if [ "$SCHEMA" = "1" ]; then
      ok "schema_version=1"
    else
      fail "schema_version mismatch: expected 1, got: $SCHEMA"
    fi
    SKIP=$(jq -r '.inputs[] | select(.kind=="skip-reason") | .value' "$MANIFEST")
    if [ "$SKIP" = "dry-run" ]; then
      ok "inputs include skip-reason=dry-run"
    else
      fail "expected inputs.skip-reason=dry-run, got: $SKIP"
    fi
  fi

  # Confirm workspace-scoped paths actually landed under TMPDIR_SMOKE (not the plugin root).
  case "$LOG_DIR_SMOKE" in
    "$TMPDIR_SMOKE"/*) ok "logs landed under workspace (not plugin install dir)" ;;
    *) fail "logs landed outside workspace: $LOG_DIR_SMOKE" ;;
  esac
fi

echo
echo "6. Stub-CLI smoke (ralph-trio Stage 3 — verdict from codex .final.md)"
# This is the real-logic regression guard for the forward-port: the trio
# reviewer's verdict MUST come from ask-reviewer.sh's --output-last-message file
# (codex-<TS>.final.md), NOT the streamed stdout the dev-trio contract declares
# unreliable; and that file MUST land in ralph's durable log tree (pinned
# DEV_TRIO_LOG_DIR) so it survives worktree teardown. We stub ask-reviewer.sh to
# emit a clean SHIP in the .final.md while streaming a DECOY NEEDS-FIX on stdout
# — only parsing the .final.md yields SHIP.
if [ "$FAILED" = "1" ]; then
  warn "skipping Stage-3 smoke — prior REQUIRED checks failed"
else
  T2=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE" "$T2"' EXIT

  STUB_BIN="$T2/stubbin"
  mkdir -p "$STUB_BIN"
  # Install the shared result reader alongside the fixture dispatcher, just
  # like the dev-trio plugin layout. The model-free driver smoke above/below
  # must exercise the same receipt contract as production.
  REVIEW_RESULT_LIB="$PLUGIN_ROOT/../dev-trio/lib/review-result.sh"
  if [ ! -f "$REVIEW_RESULT_LIB" ]; then
    REVIEW_RESULT_LIB="$(dirname "${REVIEWER_FOUND:-.}")/../lib/review-result.sh"
  fi
  if [ ! -f "$REVIEW_RESULT_LIB" ]; then
    fail "dev-trio review-result.sh missing; update/install dev-trio for reviewer smoke"
    exit 1
  fi
  REVIEW_RESULT_LIB="$(cd "$(dirname "$REVIEW_RESULT_LIB")" && pwd -P)/review-result.sh"
  mkdir -p "$T2/lib"
  ln -s "$REVIEW_RESULT_LIB" "$T2/lib/review-result.sh"
  # Stub mimics the dev-trio ask-reviewer.sh output contract: authoritative review
  # in $FINAL, an unreliable/decoy transcript on stdout, and the
  # `(log:…, final:…, rc=…)` line on stderr. STUB_MODE selects the scenario.
  cat > "$STUB_BIN/ask-reviewer.sh" <<'STUB'
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
    # Authoritative final = clean SHIP in codex's native `## Verdict` format
    # (`<TOKEN> — reason`, per dev-trio reviewer.md). Stream = DECOY NEEDS-FIX:
    # if ralph parsed the stream instead of the final, the SHIP assert fails.
    printf '## Verdict\nSHIP — stub: looks good\n' > "$FINAL"
    printf '## Review\nstub stream (do not parse me)\n## Verdict\nNEEDS-FIX — decoy\n'
    ;;
  empty-placeholder)
    # codex emitted no clean final; the stream carries only the role-prompt
    # placeholder (reviewer.md's `<one of: ...>` template), which must NOT
    # register as a real verdict.
    : > "$FINAL"
    printf '## Verdict\n<one of: SHIP / NEEDS-FIX / DISCUSS> — <reason>\n'
    ;;
esac
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/review-result.sh"
RESULT="${FINAL%.final.md}.review.json"
review_result_parse "$FINAL" 0 "${DEV_TRIO_REVIEW_PROFILE:-default}" > "$RESULT"
review_receipt_write "$DEV_TRIO_REVIEW_RECEIPT" "$RESULT" "$FINAL"
RC=$(jq -r '.exit_code' "$RESULT")
echo "(log: $LOG, final: $FINAL, result: $RESULT, rc=$RC)" >&2
exit "$RC"
STUB
  chmod +x "$STUB_BIN/ask-reviewer.sh"

  # run_trio_case MODE CWD — runs a single-iter trio loop in a fresh git repo
  # under $CWD with the stub on PATH and claude stubbed to `true` (no real model).
  run_trio_case() {
    local mode="$1" cwd="$2"
    mkdir -p "$cwd"
    git -C "$cwd" init -q
    git -C "$cwd" config user.email doctor@example.invalid
    git -C "$cwd" config user.name doctor
    echo seed > "$cwd/seed.txt"
    git -C "$cwd" add -A >/dev/null 2>&1
    git -C "$cwd" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm seed >/dev/null 2>&1 \
      || { fail "fixture seed commit failed in $cwd"; return 1; }
    printf -- '- [ ] stub smoke task\n' > "$cwd/BACKLOG.md"
    (
      cd "$cwd" && \
      AGENT_TEAM="doctor-trio" \
      RALPH_TRIO_WORKSPACE="$cwd/.ralph-trio" \
      STUB_MODE="$mode" \
      PLANNER_CLI=true CODER_CLI=true \
      TMUX="" \
      PATH="$STUB_BIN:$PATH" \
      "$PLUGIN_ROOT/bin/ralph-trio.sh" --max-iter 1 --no-research --backlog "$cwd/BACKLOG.md" \
      >"$cwd/trio.out" 2>"$cwd/trio.err"
    )
  }

  review_verdict() {
    # Echo the .verdict of the iter-1 review manifest under $1's workspace.
    local cwd="$1" m
    m=$(ls "$cwd/.ralph-trio/log/doctor-trio"/ralph-trio-*-iter-1-review.manifest.json 2>/dev/null | tail -1)
    [ -n "$m" ] && jq -r '.verdict' "$m" 2>/dev/null
  }

  # --- Case A: final-ship — verdict comes from .final.md, not the decoy stream.
  CASE_A="$T2/case-final-ship"
  if run_trio_case final-ship "$CASE_A"; then
    ok "trio loop (final-ship) completed (rc=0)"
  else
    fail "trio loop (final-ship) exited non-zero — see $CASE_A/trio.err"
    note "stderr: $(tail -3 "$CASE_A/trio.err" 2>/dev/null)"
  fi
  VA=$(review_verdict "$CASE_A")
  if [ "$VA" = "SHIP" ]; then
    ok "verdict=SHIP parsed from codex .final.md (decoy stdout NEEDS-FIX ignored)"
  else
    fail "expected verdict=SHIP from .final.md, got: ${VA:-<no manifest>} (regression: parsing streamed stdout?)"
  fi
  # Durability: the .final.md must land under ralph's pinned workspace dir, and
  # NOT in a stray .dev-trio under the run cwd (which a worktree would tear down).
  if [ -e "$CASE_A/.ralph-trio/log/doctor-trio/codex/doctor-trio/latest-codex.final.md" ]; then
    ok "codex .final.md pinned under ralph workspace (survives worktree teardown)"
  else
    fail "codex .final.md not found under ralph workspace — DEV_TRIO_LOG_DIR not pinned?"
  fi
  if [ -e "$CASE_A/.dev-trio" ]; then
    fail "stray .dev-trio created in run cwd — DEV_TRIO_LOG_DIR redirect leaked"
  else
    ok "no stray .dev-trio in run cwd"
  fi

  # --- Case B: empty-placeholder — the placeholder must NOT register as a verdict.
  CASE_B="$T2/case-empty-placeholder"
  run_trio_case empty-placeholder "$CASE_B" || true
  VB=$(review_verdict "$CASE_B")
  if [ "$VB" = "null" ]; then
    ok "empty final + placeholder stream → verdict=null (no bogus verdict leaked)"
  else
    fail "expected verdict=null for placeholder-only stream, got: ${VB:-<no manifest>}"
  fi
fi

echo
echo "7. Stub-CLI smoke (ralph-trio Stage 1.5 — planner-driven pre-coding research)"
# Regression guard for the planner NEED RESEARCH path: when the PLANNER emits a
# `## NEED RESEARCH` block, ralph must fetch research via ask-researcher.sh BEFORE Stage
# 2 and graft it into the FIRST coder prompt (planner.md promises exactly this).
# Runs under --autoship (Stage 3 skipped → no codex stub needed). PLANNER_CLI
# emits a research-requesting plan; ask-researcher.sh is stubbed to a known answer;
# CODER_CLI captures the prompt it receives so we can assert the <research> graft.
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
1. implement the helper in foo
## Files
- foo.txt — modified
## Verify
- grep helper foo.txt
## NEED RESEARCH
- What is the correct signature of the helper?
PLAN
STUB
  cat > "$S7/ask-researcher.sh" <<'STUB'
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
  CWD7="$T7/run"
  mkdir -p "$CWD7"
  git -C "$CWD7" init -q
  git -C "$CWD7" config user.email doctor@example.invalid
  git -C "$CWD7" config user.name doctor
  git -C "$CWD7" commit -q --allow-empty -m seed >/dev/null 2>&1
  printf -- '- [ ] task that needs research\n' > "$CWD7/BACKLOG.md"
  (
    cd "$CWD7" && \
    AGENT_TEAM="doctor-research" \
    RALPH_TRIO_WORKSPACE="$CWD7/.ralph-trio" \
    PLANNER_CLI="$S7/stub-planner.sh" \
    CODER_CLI="$S7/stub-coder.sh" \
    CODER_CAPTURE="$CWD7/coder-prompt.txt" \
    TMUX="" \
    PATH="$S7:$PATH" \
    "$PLUGIN_ROOT/bin/ralph-trio.sh" --max-iter 1 --autoship --backlog "$CWD7/BACKLOG.md" \
    >"$CWD7/trio.out" 2>"$CWD7/trio.err"
  ) || { fail "Stage-1.5 smoke run exited non-zero — see $CWD7/trio.err"; note "stderr: $(tail -3 "$CWD7/trio.err" 2>/dev/null)"; }
  RP7=$(ls "$CWD7/.ralph-trio/log/doctor-research"/ralph-trio-*-iter-1-research-plan.log 2>/dev/null | tail -1)
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
  # Re-point ask-researcher.sh at a failing stub; reuse the research-requesting planner.
  cat > "$S7/ask-researcher.sh" <<'STUB'
#!/usr/bin/env bash
echo "FATAL: agy stub failure" >&2
exit 1
STUB
  chmod +x "$S7/ask-researcher.sh"
  CWD7B="$T7/run-fail"
  mkdir -p "$CWD7B"
  git -C "$CWD7B" init -q
  git -C "$CWD7B" config user.email doctor@example.invalid
  git -C "$CWD7B" config user.name doctor
  git -C "$CWD7B" commit -q --allow-empty -m seed >/dev/null 2>&1
  printf -- '- [ ] task that needs research\n' > "$CWD7B/BACKLOG.md"
  (
    cd "$CWD7B" && \
    AGENT_TEAM="doctor-research-fail" \
    RALPH_TRIO_WORKSPACE="$CWD7B/.ralph-trio" \
    PLANNER_CLI="$S7/stub-planner.sh" \
    CODER_CLI="$S7/stub-coder.sh" \
    CODER_CAPTURE="$CWD7B/coder-prompt.txt" \
    TMUX="" \
    PATH="$S7:$PATH" \
    "$PLUGIN_ROOT/bin/ralph-trio.sh" --max-iter 1 --autoship --backlog "$CWD7B/BACKLOG.md" \
    >"$CWD7B/trio.out" 2>"$CWD7B/trio.err"
  ) || true
  # Check for the actual error OUTPUT, not the `<research>` tag name (the coder
  # role's trust-boundary preamble mentions `<research>` literally, so a tag-name
  # grep would false-positive). The failing agy stub emits "FATAL: agy stub
  # failure"; that string must NOT have been grafted in as research.
  if grep -q "FATAL: agy stub failure" "$CWD7B/coder-prompt.txt" 2>/dev/null; then
    fail "failed research (error output) was injected into the coder prompt (should be suppressed)"
  else
    ok "failed research output not injected into coder prompt"
  fi
  MVB=$(ls "$CWD7B/.ralph-trio/log/doctor-research-fail"/ralph-trio-*-iter-1-review.manifest.json 2>/dev/null | tail -1)
  if [ -n "$MVB" ] && [ "$(jq -r '.verdict' "$MVB" 2>/dev/null)" = "NEEDS-FIX" ]; then
    ok "research-failed under --autoship → NEEDS-FIX (refused to ship research-dependent work)"
  else
    fail "research-failed under --autoship did not route to NEEDS-FIX (verdict: $([ -n "$MVB" ] && jq -r '.verdict' "$MVB" 2>/dev/null || echo '<no manifest>'))"
  fi
fi

echo
if [ "$FAILED" = "1" ]; then
  printf '%sralph-trio doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sralph-trio doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — verdict/dashboard changes still need a real-CLI dry-run)%s\n' "$DIM" "$RESET"
fi
