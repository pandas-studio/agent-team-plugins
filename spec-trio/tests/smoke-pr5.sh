#!/usr/bin/env bash
# tests/smoke-pr5.sh — smoke driver for RFC 0004 PR 5 (plugin port).
#
# Exercises spec-trio.sh's manifest emission and spec-coverage.sh's
# --manifest-history consumer through 9 cases, with no real LLM calls.
# Stub CLIs match the `claude -p "$2"` and `codex exec "$2"` shapes
# (per the upstream "Smoke-test stub wrappers" convention). Each case runs
# under AGENT_TEAM=smoke-pr5-caseN, and SPEC_TRIO_WORKSPACE is forced to a
# fresh tmpdir for the whole smoke run, so all per-case logs land under
# $SPEC_TRIO_WORKSPACE/log/smoke-pr5-caseN/ regardless of where this script
# is invoked from.
#
# Usage: bash <plugin>/tests/smoke-pr5.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_TRIO="$PLUGIN_ROOT/bin/spec-trio.sh"
SPEC_COVERAGE="$PLUGIN_ROOT/bin/spec-coverage.sh"
MANIFEST_LIB="$PLUGIN_ROOT/lib/manifest.sh"

# Aggregate every per-case log under one fresh tmpdir so the final
# schema-invariants loop can glob across all cases. SPEC_TRIO_WORKSPACE is
# exported into spec-trio.sh's environment, which makes spec_workspace_root
# (lib/common.sh) resolve to this dir instead of the caller's $PWD/.spec-trio.
SPEC_TRIO_WORKSPACE=$(mktemp -d -t spec-pr5-ws-XXXXXX)
export SPEC_TRIO_WORKSPACE
SPEC_LOG_BASE="$SPEC_TRIO_WORKSPACE/log"
mkdir -p "$SPEC_LOG_BASE"

[ -x "$SPEC_TRIO" ]      || { echo "missing: $SPEC_TRIO" >&2; exit 2; }
[ -x "$SPEC_COVERAGE" ]  || { echo "missing: $SPEC_COVERAGE" >&2; exit 2; }
[ -f "$MANIFEST_LIB" ]   || { echo "missing: $MANIFEST_LIB" >&2; exit 2; }

# spec-trio.sh checks PATH for ask-codex.sh / ask-gemini.sh before running any
# non-dry-run / non-autoship case. If we can find a sibling dev-trio plugin
# checkout (the monorepo arrangement), prepend its bin/ to PATH. The cases
# stub the underlying `codex` binary via CODEX_CLI, so ask-codex.sh itself
# still runs end-to-end — only the LLM call inside it is stubbed.
SIBLING_DEV_BIN="$(cd "$PLUGIN_ROOT/../dev-trio/bin" 2>/dev/null && pwd)"
if [ -n "$SIBLING_DEV_BIN" ] && [ -x "$SIBLING_DEV_BIN/ask-codex.sh" ]; then
  case ":$PATH:" in
    *":$SIBLING_DEV_BIN:"*) ;;
    *) export PATH="$SIBLING_DEV_BIN:$PATH" ;;
  esac
fi
command -v ask-codex.sh  >/dev/null 2>&1 || { echo "smoke prereq missing: ask-codex.sh (install dev-trio plugin or run from a sibling-checkout layout)" >&2; exit 2; }
command -v ask-gemini.sh >/dev/null 2>&1 || { echo "smoke prereq missing: ask-gemini.sh (install dev-trio plugin)" >&2; exit 2; }

PASS=0; FAIL=0; ASSERTS=0
assert_cmd() {
  local desc="$1" cmd="$2"
  ASSERTS=$((ASSERTS + 1))
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  [ok]   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  [FAIL] %s\n         cmd: %s\n' "$desc" "$cmd"
  fi
}
assert_eq() {
  local desc="$1" want="$2" got="$3"
  ASSERTS=$((ASSERTS + 1))
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    printf '  [ok]   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  [FAIL] %s\n         want: %q\n         got:  %q\n' "$desc" "$want" "$got"
  fi
}
section() { printf '\n=== %s ===\n' "$*"; }

# SPEC_LOG_BASE is already fresh (mktemp -d above) — no pre-clean needed.

# Per-case workspace builder. Creates a tmp work dir with git, spec.md,
# BACKLOG.md, and per-case stub CLIs. The wrappers are committed in the
# initial workspace setup so they don't show up as untracked changes that
# would trip the scope-violation gate. Per-case behavior:
#   PLAN_OUT     — raw stdout the planner stub emits (becomes PLAN_LOG body)
#   CODE_FILE    — path the coder stub writes & commits (relative to $wd);
#                  empty string ⇒ coder writes nothing
#   VERDICT_OUT  — body inside the codex stub's `## Verdict` block
#   TASK_LINE    — single BACKLOG line
make_workspace() {
  local plan_out="$1" code_file="$2" verdict_out="$3" task_line="$4"
  local wd
  wd="$(mktemp -d -t spec-pr5-XXXXXX)"
  cd "$wd"
  git init -q
  cat > spec.md <<'EOF'
# Smoke spec
## §1 Goals
foo() returns 42.
## §5 Test criteria
### §5.1 returns 42
### §5.10 decade boundary witness
EOF
  printf '%s\n' "$task_line" > BACKLOG.md

  # wrap-claude.sh — distinguish planner vs worker by role marker in prompt.
  # planner.md leads with "# Role: Spec-driven Planner"; worker.md with
  # "# Role: Spec-driven Worker". Variables interpolated from caller scope.
  cat > wrap-claude.sh <<EOF
#!/usr/bin/env bash
PROMPT="\$2"
if printf '%s' "\$PROMPT" | grep -q 'Spec-driven Planner'; then
  cat <<'PLAN'
${plan_out}
PLAN
elif printf '%s' "\$PROMPT" | grep -q 'Spec-driven Worker'; then
  CODE_FILE='${code_file}'
  if [ -n "\$CODE_FILE" ]; then
    printf 'def foo():\n    return 42\n' > "\$CODE_FILE"
    git add "\$CODE_FILE" >/dev/null 2>&1 || true
    git -c user.email=w@test -c user.name=w commit -qm "spec §5.1: add foo" >/dev/null 2>&1 || true
  fi
  echo "[stub coder] wrote \$CODE_FILE"
fi
EOF

  cat > wrap-codex.sh <<EOF
#!/usr/bin/env bash
cat <<'VERDICT'
## Verdict
${verdict_out}
VERDICT
EOF
  chmod +x wrap-claude.sh wrap-codex.sh

  # Commit fixtures so the scope check sees a clean tree before the coder
  # runs. Without this, untracked wrap-*.sh files trip gate 2 in cases that
  # have a non-empty allowlist.
  git add spec.md BACKLOG.md wrap-claude.sh wrap-codex.sh
  git -c user.email=smoke@test -c user.name=smoke commit -qm "smoke fixtures"
  echo "$wd"
}

run_spec_trio() {
  local team="$1" wd="$2"
  shift 2
  (
    cd "$wd"
    AGENT_TEAM="smoke-pr5-$team" \
    CLAUDE_CLI="$wd/wrap-claude.sh" \
    CODEX_CLI="$wd/wrap-codex.sh" \
      "$SPEC_TRIO" --spec "$wd/spec.md" --backlog "$wd/BACKLOG.md" \
        --no-research "$@" >/dev/null 2>&1
  )
}

case_log_dir() { printf '%s/smoke-pr5-%s' "$SPEC_LOG_BASE" "$1"; }

# Read field from the (single) manifest matching a glob. Echoes the jq result,
# or empty string if the file doesn't exist. Avoids a class of false-positive
# asserts where both sides resolve to "" and compare equal.
manifest_field() {
  local glob="$1" filter="$2"
  local f
  # shellcheck disable=SC2086
  f=$(ls $glob 2>/dev/null | head -1)
  [ -n "$f" ] || { echo ""; return; }
  jq -r "$filter" "$f" 2>/dev/null
}

# --------------------------------------------------------------------------
section "Case 1: happy path → 3 manifests, reviewer SHIP"
WD1="$(make_workspace \
  '<allowed-paths>foo.py</allowed-paths>' \
  'foo.py' \
  'SHIP — looks good' \
  '- [ ] §5.1 add foo()')"
run_spec_trio case1 "$WD1" --max-iter 1
LD1="$(case_log_dir case1)"
P1="$LD1/spec-trio-*-iter-1-plan.manifest.json"
C1="$LD1/spec-trio-*-iter-1-code.manifest.json"
R1="$LD1/spec-trio-*-iter-1-review.manifest.json"
assert_cmd "plan manifest exists"     "ls $P1"
assert_cmd "code manifest exists"     "ls $C1"
assert_cmd "review manifest exists"   "ls $R1"
assert_eq  "plan variant=spec-plan"     "spec-plan"     "$(manifest_field "$P1" '.variant')"
assert_eq  "plan parent=null"           "null"          "$(manifest_field "$P1" '.parent_run_id')"
assert_eq  "code variant=spec-code"     "spec-code"     "$(manifest_field "$C1" '.variant')"
assert_eq  "code parent=plan run_id"    "$(manifest_field "$P1" '.run_id')" "$(manifest_field "$C1" '.parent_run_id')"
assert_eq  "review variant=spec-review" "spec-review"   "$(manifest_field "$R1" '.variant')"
assert_eq  "review parent=code run_id"  "$(manifest_field "$C1" '.run_id')" "$(manifest_field "$R1" '.parent_run_id')"
assert_eq  "review verdict=SHIP"        "SHIP"          "$(manifest_field "$R1" '.verdict')"
assert_eq  "plan has kind=spec"   "1" "$(manifest_field "$P1" '[.inputs[]?|select(.kind=="spec")] | length')"
assert_eq  "code has kind=spec"   "1" "$(manifest_field "$C1" '[.inputs[]?|select(.kind=="spec")] | length')"
assert_eq  "review has kind=spec" "1" "$(manifest_field "$R1" '[.inputs[]?|select(.kind=="spec")] | length')"
assert_cmd "no .tmp leaks (case1)"      "[ -z \"\$(ls $LD1/*.tmp 2>/dev/null)\" ]"

# --------------------------------------------------------------------------
section "Case 2: gate 1 round-trip (planner emits no allowlist)"
WD2="$(make_workspace \
  'a plan with no allowlist block' \
  '' \
  'unused' \
  '- [ ] §5.1 add foo() (no-allowlist)')"
run_spec_trio case2 "$WD2" --max-iter 1
LD2="$(case_log_dir case2)"
P2="$LD2/spec-trio-*-iter-1-plan.manifest.json"
S2="$LD2/spec-trio-*-iter-1-scope.manifest.json"
assert_cmd "plan manifest exists"           "ls $P2"
assert_cmd "no code manifest"               "[ -z \"\$(ls $LD2/spec-trio-*-iter-1-code.manifest.json 2>/dev/null)\" ]"
assert_cmd "scope manifest exists (gate 1)" "ls $S2"
assert_eq  "scope variant=spec-review"      "spec-review"     "$(manifest_field "$S2" '.variant')"
assert_eq  "scope verdict=OUT-OF-SCOPE"     "OUT-OF-SCOPE"    "$(manifest_field "$S2" '.verdict')"
assert_eq  "scope parent=plan run_id"       "$(manifest_field "$P2" '.run_id')" "$(manifest_field "$S2" '.parent_run_id')"
assert_eq  "scope-fail=plan-invalid"        "plan-invalid"    "$(manifest_field "$S2" '[.inputs[]?|select(.kind=="scope-fail")|.value][0]')"
assert_eq  "skip-reason=scope-gate"         "scope-gate"      "$(manifest_field "$S2" '[.inputs[]?|select(.kind=="skip-reason")|.value][0]')"
assert_cmd "fix_plan has OUT-OF-SCOPE entry" "grep -q 'OUT-OF-SCOPE (human attention' $WD2/fix_plan.md"

# --------------------------------------------------------------------------
section "Case 3: gate 2 round-trip (allowlist=foo.py, coder writes bar.py)"
WD3="$(make_workspace \
  '<allowed-paths>foo.py</allowed-paths>' \
  'bar.py' \
  'unused' \
  '- [ ] §5.1 add foo() (gate-2)')"
run_spec_trio case3 "$WD3" --max-iter 1
LD3="$(case_log_dir case3)"
P3="$LD3/spec-trio-*-iter-1-plan.manifest.json"
C3="$LD3/spec-trio-*-iter-1-code.manifest.json"
S3="$LD3/spec-trio-*-iter-1-scope.manifest.json"
assert_cmd "plan manifest exists"           "ls $P3"
assert_cmd "code manifest exists"           "ls $C3"
assert_cmd "scope manifest exists (gate 2)" "ls $S3"
assert_eq  "scope verdict=OUT-OF-SCOPE"     "OUT-OF-SCOPE"     "$(manifest_field "$S3" '.verdict')"
assert_eq  "scope parent=code run_id"       "$(manifest_field "$C3" '.run_id')" "$(manifest_field "$S3" '.parent_run_id')"
assert_eq  "scope-fail=scope-violation"     "scope-violation"  "$(manifest_field "$S3" '[.inputs[]?|select(.kind=="scope-fail")|.value][0]')"
assert_cmd "no real-reviewer manifest"      "[ \"\$(ls $LD3/spec-trio-*-iter-1-review.manifest.json 2>/dev/null | wc -l | tr -d ' ')\" = '0' ]"

# --------------------------------------------------------------------------
section "Case 4: spec-coverage --manifest-history rolls up SHIP for §5.1"
COV1_OUT="$(cd "$WD1" && "$SPEC_COVERAGE" --spec "$WD1/spec.md" \
  --since-ref HEAD~1 --repo "$WD1" --manifest-history "$LD1" --quiet --no-partial 2>/dev/null)"
assert_cmd "coverage row §5.1 reports 1 SHIP" \
  "printf '%s' \"\$COV1_OUT\" | grep -q '§5.1 .* 1 SHIP, 0 NEEDS-FIX, 0 DISCUSS, 0 OUT-OF-SCOPE'"

# --------------------------------------------------------------------------
section "Case 5: spec-coverage rolls up OUT-OF-SCOPE for §5.1 from gate"
COV2_OUT="$(cd "$WD2" && "$SPEC_COVERAGE" --spec "$WD2/spec.md" \
  --since-ref HEAD --repo "$WD2" --manifest-history "$LD2" --quiet --no-partial 2>/dev/null)"
assert_cmd "coverage row §5.1 reports 1 OUT-OF-SCOPE" \
  "printf '%s' \"\$COV2_OUT\" | grep -q '§5.1 .* 0 SHIP, 0 NEEDS-FIX, 0 DISCUSS, 1 OUT-OF-SCOPE'"
# Anchor regression: §5.10 row must NOT count §5.1 manifests.
assert_cmd "coverage row §5.10 reports 0 OUT-OF-SCOPE (anchor)" \
  "printf '%s' \"\$COV2_OUT\" | grep -q '§5.10 .* 0 SHIP, 0 NEEDS-FIX, 0 DISCUSS, 0 OUT-OF-SCOPE'"

# --------------------------------------------------------------------------
section "Case 6: dry-run + autoship"
WD6="$(make_workspace 'unused' '' 'unused' '- [ ] §5.1 dry')"
run_spec_trio case6 "$WD6" --max-iter 1 --dry-run
LD6="$(case_log_dir case6)"
P6="$LD6/spec-trio-*-iter-1-plan.manifest.json"
C6="$LD6/spec-trio-*-iter-1-code.manifest.json"
R6="$LD6/spec-trio-*-iter-1-review.manifest.json"
assert_cmd "dry-run: plan manifest"   "ls $P6"
assert_cmd "dry-run: code manifest"   "ls $C6"
assert_cmd "dry-run: review manifest" "ls $R6"
# Backlog-preservation regression: --dry-run must not destructively pop tasks.
assert_cmd "dry-run preserves BACKLOG.md unchecked entry" \
  "grep -qE '^- \\[ \\] §5.1 dry\$' $WD6/BACKLOG.md"
assert_cmd "dry-run does NOT mark BACKLOG.md task done" \
  "! grep -qE '^- \\[x\\] §5.1 dry\$' $WD6/BACKLOG.md"
assert_eq  "dry-run plan skip-reason=dry-run"  "dry-run" "$(manifest_field "$P6" '[.inputs[]?|select(.kind=="skip-reason")|.value][0]')"
assert_eq  "dry-run review verdict=SHIP"       "SHIP"    "$(manifest_field "$R6" '.verdict')"
assert_eq  "dry-run plan still has kind=spec"  "1"       "$(manifest_field "$P6" '[.inputs[]?|select(.kind=="spec")] | length')"

WD7="$(make_workspace \
  '<allowed-paths>foo.py</allowed-paths>' 'foo.py' 'unused' '- [ ] §5.1 auto')"
run_spec_trio case7 "$WD7" --max-iter 1 --autoship
LD7="$(case_log_dir case7)"
R7="$LD7/spec-trio-*-iter-1-review.manifest.json"
assert_eq  "autoship review verdict=SHIP"          "SHIP"     "$(manifest_field "$R7" '.verdict')"
assert_eq  "autoship review skip-reason=autoship"  "autoship" "$(manifest_field "$R7" '[.inputs[]?|select(.kind=="skip-reason")|.value][0]')"

# --------------------------------------------------------------------------
section "Case 7: --no-strict-scope downgrade (absence asserts)"
WD8="$(make_workspace 'no allowlist' '' 'SHIP — fine' '- [ ] §5.1 lax')"
run_spec_trio case8 "$WD8" --max-iter 1 --no-strict-scope
LD8="$(case_log_dir case8)"
P8="$LD8/spec-trio-*-iter-1-plan.manifest.json"
C8="$LD8/spec-trio-*-iter-1-code.manifest.json"
R8="$LD8/spec-trio-*-iter-1-review.manifest.json"
assert_cmd "plan manifest exists"            "ls $P8"
assert_cmd "code manifest exists"            "ls $C8"
assert_cmd "review manifest exists"          "ls $R8"
assert_cmd "no scope manifest emitted"       "[ \"\$(ls $LD8/spec-trio-*-iter-1-scope.manifest.json 2>/dev/null | wc -l | tr -d ' ')\" = '0' ]"
assert_eq  "review verdict=SHIP (real reviewer)" "SHIP" "$(manifest_field "$R8" '.verdict')"
# Absence baseline for PR 6 contract diff: no manifest carries scope-fail/scope-warning.
assert_cmd "no kind=scope-fail anywhere"     "! jq -se 'map(.inputs[]?|select(.kind==\"scope-fail\"))|flatten|length>0' $LD8/*.manifest.json"
assert_cmd "no kind=scope-warning anywhere"  "! jq -se 'map(.inputs[]?|select(.kind==\"scope-warning\"))|flatten|length>0' $LD8/*.manifest.json"

# --------------------------------------------------------------------------
section "Case 8b: --dry-run --max-iter 0 terminates at synthetic backlog drain"
# Regression: the synthetic-task path under --dry-run removed the natural
# "backlog drained" stop, so combined with --max-iter 0 (unlimited) the loop
# could run forever. Should now stop after N iters where N = unchecked count.
WD8b="$(make_workspace 'unused' '' 'unused' '- [ ] §5.1 dry one')"
# Add a second unchecked entry so we can assert "stops at N, not 1".
printf -- '- [ ] §5.1 dry two\n' >> "$WD8b/BACKLOG.md"
run_spec_trio case8b "$WD8b" --max-iter 0 --dry-run
LD8b="$(case_log_dir case8b)"
# Two iters fired, three didn't — exactly N=2 iter manifests.
assert_eq "dry-run unlimited terminates after N=2 iters" \
  "2" "$(ls $LD8b/spec-trio-*-iter-*-plan.manifest.json 2>/dev/null | wc -l | tr -d ' ')"
assert_cmd "no iter-3 manifest emitted" \
  "[ -z \"\$(ls $LD8b/spec-trio-*-iter-3-plan.manifest.json 2>/dev/null)\" ]"
assert_cmd "BACKLOG.md preserved (both entries unchecked)" \
  "[ \"\$(grep -c '^- \\[ \\]' $WD8b/BACKLOG.md)\" = '2' ]"

# --------------------------------------------------------------------------
section "Case 9a: gate 2 catches an earlier commit in a multi-commit iter"
# Regression for check_scope's diff range: the legacy HEAD~1..HEAD walk only
# saw the iter's LAST commit, so a coder that staged an out-of-scope path in
# commit #1 and an in-scope path in commit #2 would slip past gate 2. The
# iter-base SHA (ITER_BASE_SHA) recorded at iter start now feeds a full
# base..HEAD walk so every commit is inspected.
WD9a="$(mktemp -d -t spec-pr5-9a-XXXXXX)"
( cd "$WD9a"
  git init -q
  cat > spec.md <<'EOF'
# Smoke spec
## §1 Goals
foo() returns 42.
## §5 Test criteria
### §5.1 returns 42
EOF
  printf -- '- [ ] §5.1 add foo() (multi-commit)\n' > BACKLOG.md
  cat > wrap-claude.sh <<'CLAUDE_EOF'
#!/usr/bin/env bash
PROMPT="$2"
if printf '%s' "$PROMPT" | grep -q 'Spec-driven Planner'; then
  cat <<'PLAN'
<allowed-paths>foo.py</allowed-paths>
PLAN
elif printf '%s' "$PROMPT" | grep -q 'Spec-driven Worker'; then
  # Commit 1: bar.py (OUT-OF-SCOPE — not in allowlist). Commit 2: foo.py
  # (in allowlist). HEAD~1..HEAD only shows foo.py; iter-base..HEAD shows both.
  printf 'bar = 1\n' > bar.py
  git add bar.py >/dev/null 2>&1
  git -c user.email=w@test -c user.name=w commit -qm "spec §5.1: stage bar.py first" >/dev/null 2>&1
  printf 'def foo():\n    return 42\n' > foo.py
  git add foo.py >/dev/null 2>&1
  git -c user.email=w@test -c user.name=w commit -qm "spec §5.1: add foo.py" >/dev/null 2>&1
fi
CLAUDE_EOF
  cat > wrap-codex.sh <<'CODEX_EOF'
#!/usr/bin/env bash
echo "## Verdict"
echo "SHIP — fine"
CODEX_EOF
  chmod +x wrap-claude.sh wrap-codex.sh
  git add spec.md BACKLOG.md wrap-claude.sh wrap-codex.sh
  git -c user.email=smoke@test -c user.name=smoke commit -qm "smoke fixtures"
)
run_spec_trio case9a "$WD9a" --max-iter 1
LD9a="$(case_log_dir case9a)"
S9a="$LD9a/spec-trio-*-iter-1-scope.manifest.json"
assert_cmd "scope manifest emitted (gate 2 caught earlier commit)" "ls $S9a"
assert_eq  "scope verdict=OUT-OF-SCOPE" "OUT-OF-SCOPE" "$(manifest_field "$S9a" '.verdict')"
assert_eq  "scope-fail=scope-violation" "scope-violation" "$(manifest_field "$S9a" '[.inputs[]?|select(.kind=="scope-fail")|.value][0]')"
# Confirm the scope log specifically called out bar.py as the offending path.
assert_cmd "scope log lists bar.py as offending" \
  "grep -qE '^bar\\.py\$' $LD9a/spec-trio-*-iter-1-scope.log"

# --------------------------------------------------------------------------
section "Case 9b: --coverage-requeue handles workspace paths with spaces"
# Regression for unquoted REQUEUE_ARGS / MANIFEST_HISTORY_ARGS expansion in
# spec-trio.sh: if either the workspace or backlog path contained a space,
# the old string-built form split on whitespace and spec-coverage.sh got the
# wrong arguments (silently dropping --requeue or pointing --manifest-history
# at half a path). The fix builds an argv array.
WD9b_BASE="$(mktemp -d -t spec-pr5-9b-XXXXXX)"
WD9b="$WD9b_BASE/work dir with spaces"
mkdir -p "$WD9b"
( cd "$WD9b"
  git init -q
  cat > spec.md <<'EOF'
# Smoke spec
## §1 Goals
trivial
## §5 Test criteria
### §5.99 deliberately-not-covered criterion
EOF
  printf -- '- [ ] §5.99 placeholder\n' > BACKLOG.md
  cat > wrap-claude.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > wrap-codex.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x wrap-claude.sh wrap-codex.sh
  git add spec.md BACKLOG.md wrap-claude.sh wrap-codex.sh
  git -c user.email=smoke@test -c user.name=smoke commit -qm "fixtures"
)
# Also put SPEC_TRIO_WORKSPACE under a path with spaces so $LOG_DIR (passed
# to --manifest-history) contains a space too.
(
  cd "$WD9b"
  SPEC_TRIO_WORKSPACE="$WD9b_BASE/spec ws with spaces" \
  AGENT_TEAM="smoke-pr5-case9b" \
  CLAUDE_CLI="$WD9b/wrap-claude.sh" CODEX_CLI="$WD9b/wrap-codex.sh" \
    "$SPEC_TRIO" --spec "$WD9b/spec.md" --backlog "$WD9b/BACKLOG.md" \
      --no-research --max-iter 1 --dry-run --coverage-check --coverage-requeue \
      >/dev/null 2>&1
)
# §5.99 was never cited in any commit; --coverage-requeue should append it.
# If the args had been split on space, --requeue would point at a partial
# path or be silently dropped, and the line wouldn't appear.
assert_cmd "spaces-in-path: BACKLOG appended with §5.99 coverage gap" \
  "grep -q 'spec coverage gap §5.99' '$WD9b/BACKLOG.md'"

# --------------------------------------------------------------------------
section "Case 8: re-init guard (unit-style, direct source)"
T9="$(mktemp -d -t spec-pr5-guard-XXXXXX)"
GUARD_OUT="$(
  cd "$T9"
  bash -c "
    set +e
    . '$MANIFEST_LIB'
    manifest_init x '$T9/x.log' >/dev/null 2>&1
    manifest_init x '$T9/x.log' 2>&1
    echo \"rc=\$?\"
  "
)"
assert_cmd "guard fires on double init" \
  "printf '%s' \"\$GUARD_OUT\" | grep -q 'prior manifest still open'"

# --------------------------------------------------------------------------
section "Schema invariants across all manifests"
for ld in "$SPEC_LOG_BASE"/smoke-pr5-*; do
  [ -d "$ld" ] || continue
  for m in "$ld"/*.manifest.json; do
    [ -f "$m" ] || continue
    base="$(basename "$m")"
    assert_cmd "schema_version=1 ($base)" "jq -e '.schema_version == 1' '$m'"
    assert_cmd "run_id non-empty ($base)" "jq -e '(.run_id // \"\") != \"\"' '$m'"
    assert_cmd "ended_at non-null ($base)" "jq -e '.ended_at != null' '$m'"
    assert_cmd "verdict in vocab ($base)" \
      "jq -e '.verdict | (. == null or . == \"SHIP\" or . == \"NEEDS-FIX\" or . == \"DISCUSS\" or . == \"OUT-OF-SCOPE\")' '$m'"
    assert_cmd "variant in spec-* ($base)" \
      "jq -e '.variant | test(\"^spec-(plan|code|review|research)\$\")' '$m'"
  done
done

# --------------------------------------------------------------------------
echo
printf '=== smoke summary: %d/%d asserts passed, %d failed ===\n' "$PASS" "$ASSERTS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
