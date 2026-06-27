#!/usr/bin/env bash
# debate-conductor-doctor.sh — environment probe + stub-CLI convergence smoke.
#
# Usage: debate-conductor-doctor.sh
#
# Checks:
#   1. Required tools on PATH: tmux, agy, codex (agy/codex warn-only — the smoke
#      injects stub CLIs via CRITIC_CLI / GENERATOR_CLI and does not need them).
#   2. Plugin layout intact (debate.sh / tail-role.sh / team-3pane.sh /
#      lib/ask-{generator,critic}.sh / lib/roles/*.md / lib/pm.md).
#   3. Convergence stub smoke for `debate.sh --until-converged` (RFC: Phase 1):
#      a. STRENGTHEN  → breaks at first Critic round (round 2), cleans up the
#         pre-touched round files past the convergence point.
#      b. RECONSIDER  → never converges, runs to the round cap.
#      c. placeholder → an errored Critic round that only echoes the role-prompt
#         placeholders (`Verdict: <STRENGTHEN | ...>`) must NOT be read as a
#         STRENGTHEN — guards the canonical-tail anchor against false positives.
#
# Stub smokes are *necessary but not sufficient* — anything touching the live
# panes (tail-role.sh) or real verdict text needs a real-CLI dry-run on top.
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

echo "debate-conductor doctor — plugin root: $PLUGIN_ROOT"
echo

echo "1. Required tools"
if command -v tmux >/dev/null 2>&1; then ok "tmux — $(command -v tmux)"
else fail "tmux — missing (REQUIRED for the live panes)"; fi
for t in agy codex; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t — $(command -v "$t")"
  else
    case "$t" in
      agy)   env_hint="GENERATOR_CLI or AGY_CLI" ;;
      codex) env_hint="CRITIC_CLI or CODEX_CLI" ;;
      *)     env_hint="(no documented override)" ;;
    esac
    warn "$t — missing (override via $env_hint; convergence smoke below does not need it)"
  fi
done

echo
echo "2. Plugin layout"
for rel in bin/debate.sh bin/tail-role.sh bin/team-3pane.sh \
           lib/ask-generator.sh lib/ask-critic.sh lib/pm.md \
           lib/roles/generator.md lib/roles/critic.md; do
  p="$PLUGIN_ROOT/$rel"
  if [ -f "$p" ]; then ok "$rel"
  else fail "$rel — missing at $p"; fi
done

echo
echo "3. Convergence stub smoke (debate.sh --until-converged)"
if [ "$FAILED" = "1" ]; then
  warn "skipping smoke — prior checks failed"
else
  TMPDIR_SMOKE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

  # Generator stub: matches `agy -p "$PROMPT"`. Emits a short draft regardless
  # of args so every gen round produces non-empty content.
  STUB_GEN="$TMPDIR_SMOKE/stub-gen.sh"
  cat > "$STUB_GEN" <<'STUB'
#!/usr/bin/env bash
echo "## Position"
echo "Stub generator draft for the convergence smoke."
STUB
  chmod +x "$STUB_GEN"

  # Critic stub: invoked as `codex exec --skip-git-repo-check "$PROMPT"`. Args
  # are ignored; the verdict it emits is driven by $STUB_VERDICT so one stub
  # drives all three smoke cases.
  STUB_CRIT="$TMPDIR_SMOKE/stub-crit.sh"
  cat > "$STUB_CRIT" <<'STUB'
#!/usr/bin/env bash
echo "## Verdict"
case "${STUB_VERDICT:-STRENGTHEN}" in
  STRENGTHEN)
    echo "STRENGTHEN — position is sound."
    echo
    echo "Verdict: STRENGTHEN"
    ;;
  RECONSIDER)
    echo "RECONSIDER — a key claim is flawed."
    echo
    echo "Verdict: RECONSIDER"
    ;;
  PLACEHOLDER)
    # Mimics an errored Critic round that only echoes the role prompt: the
    # placeholder forms must NOT be parsed as a real STRENGTHEN verdict.
    echo "<one of: STRENGTHEN / RECONSIDER / OVERTURN> — <one-line reason>"
    echo "Verdict: <STRENGTHEN | RECONSIDER | OVERTURN>"
    ;;
esac
STUB
  chmod +x "$STUB_CRIT"

  # Run a converge-mode debate with stubbed CLIs in an isolated log dir/team.
  # Echoes the resolved debate dir on the last stdout line for the caller.
  run_smoke() {
    verdict="$1"; cap="$2"; team="$3"
    out="$TMPDIR_SMOKE/$team.out"
    AGENT_TEAM="$team" \
    DEBATE_LOG_DIR="$TMPDIR_SMOKE/.debate-conductor/log" \
    GENERATOR_CLI="$STUB_GEN" \
    CRITIC_CLI="$STUB_CRIT" \
    STUB_VERDICT="$verdict" \
    TMUX="" \
      "$PLUGIN_ROOT/bin/debate.sh" --until-converged -n "$cap" "smoke: $team" \
      >"$out" 2>"$TMPDIR_SMOKE/$team.err" </dev/null
    rc=$?
    echo "rc=$rc"
    [ "$rc" -eq 0 ] || note "stderr: $(head -3 "$TMPDIR_SMOKE/$team.err" 2>/dev/null)"
  }

  # Highest completed round = max N across .round-N-*.done sidecars.
  last_done_round() {
    { ls "$1"/.round-*.done 2>/dev/null || true; } \
      | sed -E 's@.*/\.round-([0-9]+)-.*@\1@' | sort -n | tail -1
  }

  # --- 3a. STRENGTHEN converges at the first Critic round (round 2) ---
  run_smoke STRENGTHEN 6 conv-strengthen >/dev/null
  DIR_A="$TMPDIR_SMOKE/.debate-conductor/log/conv-strengthen/latest-debate"
  LAST_A=$(last_done_round "$DIR_A")
  if [ "$LAST_A" = "2" ]; then ok "STRENGTHEN → stops at round 2 (cap was 6)"
  else fail "STRENGTHEN → expected to stop at round 2, last completed round = '${LAST_A:-none}'"; fi
  if grep -q "Converged at round 2" "$TMPDIR_SMOKE/conv-strengthen.out"; then
    ok "convergence notice printed"
  else fail "missing 'Converged at round 2' notice"; fi
  if [ -e "$DIR_A/round-3-gen.md" ]; then
    fail "leftover pre-touched round-3-gen.md not cleaned up"
  else ok "post-convergence empty round files cleaned up"; fi

  # --- 3b. RECONSIDER never converges → runs to the cap ---
  run_smoke RECONSIDER 4 conv-reconsider >/dev/null
  DIR_B="$TMPDIR_SMOKE/.debate-conductor/log/conv-reconsider/latest-debate"
  LAST_B=$(last_done_round "$DIR_B")
  if [ "$LAST_B" = "4" ]; then ok "RECONSIDER → runs all 4 rounds (no early stop)"
  else fail "RECONSIDER → expected 4 completed rounds, got '${LAST_B:-none}'"; fi
  if grep -q "without a STRENGTHEN verdict" "$TMPDIR_SMOKE/conv-reconsider.out"; then
    ok "non-convergence alert printed"
  else fail "missing non-convergence alert"; fi

  # --- 3c. Placeholder-only Critic must NOT be read as STRENGTHEN ---
  run_smoke PLACEHOLDER 4 conv-placeholder >/dev/null
  DIR_C="$TMPDIR_SMOKE/.debate-conductor/log/conv-placeholder/latest-debate"
  LAST_C=$(last_done_round "$DIR_C")
  if [ "$LAST_C" = "4" ]; then ok "placeholder verdict → not a false convergence (ran to cap)"
  else fail "placeholder leaked as convergence: stopped at round '${LAST_C:-none}' (expected 4)"; fi
fi

echo
if [ "$FAILED" = "1" ]; then
  printf '%sdebate-conductor doctor: FAILED%s — see above\n' "$RED" "$RESET"
  exit 1
else
  printf '%sdebate-conductor doctor: OK%s\n' "$GREEN" "$RESET"
  printf '%s(stub smoke is necessary but not sufficient — live-pane / real-verdict changes still need a real-CLI dry-run)%s\n' "$DIM" "$RESET"
fi
