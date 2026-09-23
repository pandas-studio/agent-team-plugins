#!/usr/bin/env bash
# Real loop drivers + reviewer wrapper, with only the model CLIs replaced.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The drivers take DEV_TRIO_BIN / DEBATE_CONDUCTOR_BIN over PATH; an exported
# override would route these smokes past their stubs.
unset DEV_TRIO_BIN DEBATE_CONDUCTOR_BIN
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
PASS=0
check() {
  local label="$1"; shift
  if ! "$@"; then
    echo "FAIL: $label" >&2
    cat "$TMP/driver.out" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
}
json_is() { jq -e "$2" "$1" >/dev/null; }
cat > "$TMP/worker" <<'STUB'
#!/usr/bin/env bash
[ -t 0 ] || cat >> "${REVIEW_TEST_STDIN_SEEN:-/dev/null}"
case "$2" in
  '# Role: Ralph Planner'*|'# Role: Spec-driven Planner'*)
    echo '<allowed-paths>file.txt</allowed-paths>'
    [ "${REVIEW_TEST_CASE:-}" != plan-research ] || printf '## NEED RESEARCH\n- planner question\n' ;;
  *)
    [ -z "${REVIEW_TEST_PROMPTS:-}" ] || printf '%s\n' "$2" >> "$REVIEW_TEST_PROMPTS"
    printf 'implemented\n' > file.txt
    git add file.txt
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm 'implement fixture' || true
    echo 'coder done' ;;
esac
STUB
cat > "$TMP/researcher" <<'STUB'
#!/usr/bin/env bash
[ -t 0 ] || cat >> "${REVIEW_TEST_STDIN_SEEN:-/dev/null}"
printf 'research\n' >> "$REVIEW_TEST_RESEARCH"
printf '%s\n' "$2" >> "$REVIEW_TEST_RESEARCH.prompts"
if [ "$REVIEW_TEST_CASE" = research-denied ]; then
  # agy print mode after a soft-denied tool: guidance on stderr, exit 0.
  echo 'no output produced — tool auto-denied' >&2
  exit 0
fi
echo 'fixture research evidence'
STUB
cat > "$TMP/reviewer" <<'STUB'
#!/usr/bin/env bash
set -eu
[ -t 0 ] || cat >> "${REVIEW_TEST_STDIN_SEEN:-/dev/null}"
[ -z "${REVIEW_TEST_REVIEW_PROMPTS:-}" ] || printf '%s\n' "$*" >> "$REVIEW_TEST_REVIEW_PROMPTS"
count=0
[ ! -f "$REVIEW_TEST_COUNTER" ] || count=$(cat "$REVIEW_TEST_COUNTER")
count=$((count + 1))
printf '%s\n' "$count" > "$REVIEW_TEST_COUNTER"
final=""
while [ $# -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then final="$2"; break; fi
  shift
done
case "$REVIEW_TEST_CASE:$count" in
  malformed:*) printf '## Verdict\n\nSHIP — deliberately rejected\n' > "$final" ;;
  # NEED CONTEXT after NEED RESEARCH: the drivers' research extractors must stop
  # at it, so repository commands never reach the researcher as questions.
  retry:1|research-denied:1) printf '## Verdict\nNEEDS-FIX — need evidence\n## NEED RESEARCH\n- verify the API\n## NEED CONTEXT\n- `gh pr view 9 --json headRefOid`\n' > "$final" ;;
  *) printf '## Verdict\nSHIP — canonical result\n## What I checked\nVerdict: NEEDS-FIX\n' > "$final" ;;
esac
if [ "$REVIEW_TEST_CASE" = failed ]; then
  printf '## NEED RESEARCH\n- do not run this failed review request\n' >> "$final"
fi
# Make latest-final misleading for every case. The exact captured final is
# still available and differs from both this decoy and the legacy prose line.
printf '## Verdict\nNEEDS-FIX — unrelated invocation\n## NEED RESEARCH\n- stale request\n' > "$REVIEW_TEST_DECOY"
ln -sfn "$REVIEW_TEST_DECOY" "$(dirname "$final")/latest-codex.final.md"
cat "$final"
[ "$REVIEW_TEST_CASE" != failed ] || exit 7
STUB
chmod +x "$TMP/worker" "$TMP/researcher" "$TMP/reviewer"
# Drivers get research-shaped stdin: a reader that falls back to stdin (e.g. awk
# given an empty path after a failed review) would dispatch it as research.
printf '## NEED RESEARCH\n- leaked from caller stdin\n' > "$TMP/stdin-research.md"
for plugin in ralph-trio spec-trio; do
  for scenario in disagree malformed retarget failed retry research-denied plan-research; do
    case_root="$TMP/$plugin-$scenario"
    repo="$case_root/repo"
    state="$case_root/state"
    mkdir -p "$repo"
    git init -q "$repo"
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name Fixture
    # XDG Git ignore files still apply when GIT_CONFIG_GLOBAL is disabled.
    git -C "$repo" config core.excludesFile /dev/null
    printf 'baseline\n' > "$repo/file.txt"
    printf '# Spec\n## §5 Test criteria\n### §5.1 implement file\n' > "$repo/spec.md"
    printf -- '- [ ] §5.1 implement file\n' > "$repo/BACKLOG.md"
    git -C "$repo" add file.txt spec.md BACKLOG.md
    git -C "$repo" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm baseline
    args=(--backlog "$repo/BACKLOG.md" --max-iter 1)
    [ "$plugin" != spec-trio ] || args+=(--spec "$repo/spec.md" --test-cmd 'git diff --check')
    case "$scenario" in retarget|failed|retry|research-denied|plan-research) ;; *) args+=(--no-research) ;; esac
    driver_rc=0
    (
      cd "$repo"
      env -u REVIEWER_CLI -u REVIEWER_ROLE_FILE -u MANIFEST_PARENT_TMP \
        -u DEV_TRIO_REVIEW_PROFILE -u DEV_TRIO_REVIEW_RECEIPT \
        -u PLANNER_CLI -u CODER_CLI -u RESEARCHER_CLI \
        PATH="$ROOT/dev-trio/bin:$PATH" AGENT_TEAM=caller TMUX='' \
        AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
        DEV_TRIO_REVIEWER_MODEL=codex DEV_TRIO_RESEARCHER_MODEL=agy \
        CLAUDE_CLI="$TMP/worker" CODEX_CLI="$TMP/reviewer" AGY_CLI="$TMP/researcher" \
        RALPH_TRIO_WORKSPACE="$state" SPEC_TRIO_WORKSPACE="$state" \
        REVIEW_TEST_CASE="$scenario" REVIEW_TEST_COUNTER="$case_root/count" \
        REVIEW_TEST_RESEARCH="$case_root/research" REVIEW_TEST_DECOY="$case_root/decoy.md" \
        REVIEW_TEST_PROMPTS="$case_root/coder-prompts" REVIEW_TEST_STDIN_SEEN="$case_root/stdin-seen" \
        "$ROOT/$plugin/bin/$plugin.sh" "${args[@]}"
    ) < "$TMP/stdin-research.md" > "$TMP/driver.out" 2>&1 || driver_rc=$?
    expected_rc=0
    if [ "$plugin" = spec-trio ] && { [ "$scenario" = malformed ] || [ "$scenario" = failed ]; }; then expected_rc=4; fi
    # spec-trio skips the retry coder when research fails and leaves the task pending.
    if [ "$plugin" = spec-trio ] && [ "$scenario" = research-denied ]; then expected_rc=3; fi
    check "$plugin $scenario exit status" test "$driver_rc" -eq "$expected_rc"
    # Issue #24: no model CLI or wrapper may take the driver's stdin as input.
    check "$plugin $scenario model CLIs never read the driver's stdin" \
      sh -c '! grep -qs "leaked from caller stdin" "$1" "$2"' _ "$case_root/stdin-seen" "$case_root/research.prompts"
    expected_calls=1
    [ "$scenario" != retry ] || expected_calls=2
    [ "$scenario" != research-denied ] || [ "$plugin" != ralph-trio ] || expected_calls=2
    check "$plugin $scenario reviewer count" test "$(cat "$case_root/count")" -eq "$expected_calls"
    if [ "$scenario" = research-denied ]; then
      check "$plugin denied research request runs once" test "$(wc -l < "$case_root/research" | tr -d ' ')" -eq 1
      check "$plugin denied research rc recorded" \
        jq -se '[.[].inputs[]?|select(.kind=="research-rc" and (.value|tostring)=="5")]|length==1' \
        "$state/log/caller"/"$plugin"-*-research*.manifest.json >/dev/null
      check "$plugin denied research not given to a coder" \
        sh -c '! grep -q "auto-denied" "$1" 2>/dev/null' _ "$case_root/coder-prompts"
      if [ "$plugin" = ralph-trio ]; then
        check "$plugin retry coder runs without research" test "$(grep -c '^# Role:' "$case_root/coder-prompts")" -eq 2
      else
        check "$plugin retry coder skipped" test "$(grep -c '^# Role:' "$case_root/coder-prompts")" -eq 1
        check "$plugin research-failed skip recorded" \
          json_is "$(ls "$state/log/caller"/"$plugin"-*-code2.manifest.json)" '[.inputs[]|select(.kind=="skip-reason" and .value=="research-failed")]|length==1'
      fi
    elif [ "$scenario" = retry ]; then
      check "$plugin real research request runs once" test "$(wc -l < "$case_root/research" | tr -d ' ')" -eq 1
      check "$plugin research question dispatched" grep -q 'verify the API' "$case_root/research.prompts"
      check "$plugin NEED CONTEXT not sent as research" sh -c '! grep -q "gh pr view" "$1"' _ "$case_root/research.prompts"
    elif [ "$scenario" = plan-research ]; then
      check "$plugin planner research request runs once" test "$(wc -l < "$case_root/research" | tr -d ' ')" -eq 1
      check "$plugin planner research question dispatched" grep -q 'planner question' "$case_root/research.prompts"
    else
      check "$plugin never dispatches stale/failed research" test ! -e "$case_root/research"
    fi
    manifests=( "$state/log/caller"/"$plugin"-*-review*.manifest.json )
    if [ "$plugin" = spec-trio ] && [ "$scenario" = research-denied ]; then
      # After failed research spec-trio synthesizes the retry verdict without
      # running a review: exactly that review2 manifest links no result.
      synthesized=( "$state/log/caller"/"$plugin"-*-review2.manifest.json )
      check "$plugin synthesized retry verdict has no review result" \
        json_is "${synthesized[0]}" '([.inputs[]|select(.kind=="review-result")]|length==0) and ([.inputs[]|select(.kind=="skip-reason")]|length==1)'
      manifests=( "$state/log/caller"/"$plugin"-*-review.manifest.json )
    fi
    check "$plugin review manifest count" test "${#manifests[@]}" -eq "$expected_calls"
    for manifest in "${manifests[@]}"; do
      check "$plugin parent links one exact result" json_is "$manifest" '[.inputs[]|select(.kind=="review-result")]|length==1'
      result=$(jq -r '.inputs[]|select(.kind=="review-result")|.path' "$manifest")
      verdict=$(jq -r '.verdict' "$result")
      check "$plugin parent verdict matches JSON" json_is "$manifest" ".verdict==$([ "$verdict" = null ] && printf null || printf '\"%s\"' "$verdict")"
      case "$scenario" in
        malformed) check "$plugin strict failure recorded" json_is "$result" '.status=="parse-failed" and .exit_code==3' ;;
        failed) check "$plugin invocation failure recorded" json_is "$result" '.status=="invocation-failed" and .exit_code==7' ;;
        *) check "$plugin parsed result used" json_is "$result" '.status=="ok"' ;;
      esac
    done
    if [ "$expected_calls" -eq 2 ]; then
      check "$plugin re-review uses canonical SHIP despite decoys" \
        jq -se '[.[]|select(.verdict=="SHIP")]|length==1' "${manifests[@]}" >/dev/null
    elif [ "$scenario" = research-denied ]; then
      check "$plugin research-requesting review keeps its NEEDS-FIX" json_is "${manifests[0]}" '.verdict=="NEEDS-FIX"'
    elif [ "$scenario" != malformed ] && [ "$scenario" != failed ]; then
      check "$plugin ignores competing legacy verdict" json_is "${manifests[0]}" '.verdict=="SHIP"'
    fi
  done
done
# ralph-trio in a repository with no commits yet. The reviewer's range hint must
# cover the coder's first commit (base = empty tree), never `HEAD..HEAD`, and
# must not cite a literal `HEAD` ref when the coder leaves HEAD unborn.
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
cat > "$TMP/coder-no-commit" <<'STUB'
#!/usr/bin/env bash
printf 'implemented\n' > file.txt
echo 'coder done'
STUB
chmod +x "$TMP/coder-no-commit"
for variant in commit no-commit; do
  case_root="$TMP/ralph-trio-unborn-$variant"
  repo="$case_root/repo"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf -- '- [ ] implement file\n' > "$repo/BACKLOG.md"
  coder="$TMP/worker"
  [ "$variant" = commit ] || coder="$TMP/coder-no-commit"
  driver_rc=0
  (
    cd "$repo"
    env -u REVIEWER_CLI -u REVIEWER_ROLE_FILE -u MANIFEST_PARENT_TMP \
      -u DEV_TRIO_REVIEW_PROFILE -u DEV_TRIO_REVIEW_RECEIPT \
      -u PLANNER_CLI -u RESEARCHER_CLI \
      PATH="$ROOT/dev-trio/bin:$PATH" AGENT_TEAM=caller TMUX='' \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      DEV_TRIO_REVIEWER_MODEL=codex DEV_TRIO_RESEARCHER_MODEL=agy \
      CLAUDE_CLI="$TMP/worker" CODER_CLI="$coder" CODEX_CLI="$TMP/reviewer" AGY_CLI="$TMP/researcher" \
      RALPH_TRIO_WORKSPACE="$case_root/state" \
      REVIEW_TEST_CASE=unborn REVIEW_TEST_COUNTER="$case_root/count" \
      REVIEW_TEST_RESEARCH="$case_root/research" REVIEW_TEST_DECOY="$case_root/decoy.md" \
      REVIEW_TEST_REVIEW_PROMPTS="$case_root/review-prompts" \
      "$ROOT/ralph-trio/bin/ralph-trio.sh" --backlog "$repo/BACKLOG.md" --max-iter 1 --no-research
  ) < /dev/null > "$TMP/driver.out" 2>&1 || driver_rc=$?
  check "ralph-trio unborn $variant exit status" test "$driver_rc" -eq 0
  check "ralph-trio unborn $variant reviewer ran once" test "$(cat "$case_root/count")" -eq 1
  check "ralph-trio unborn $variant never cites HEAD..HEAD" \
    sh -c '! grep -q "HEAD\.\.HEAD" "$1"' _ "$case_root/review-prompts"
  check "ralph-trio unborn $variant never cites a literal HEAD ref" \
    sh -c '! grep -qF -e "\`HEAD\`" -e "\`HEAD.." "$1"' _ "$case_root/review-prompts"
  if [ "$variant" = commit ]; then
    check "ralph-trio unborn coder made the first commit" \
      test "$(git -C "$repo" rev-list --count HEAD)" -eq 1
    check "ralph-trio unborn range starts at the empty tree" \
      grep -qF "git diff $EMPTY_TREE..HEAD" "$case_root/review-prompts"
  else
    check "ralph-trio unborn coder left HEAD unborn" \
      sh -c '! git -C "$1" rev-parse --verify -q HEAD >/dev/null' _ "$repo"
    check "ralph-trio unborn no-commit hint says no commits yet" \
      grep -qF 'The repository has no commits yet' "$case_root/review-prompts"
  fi
done
# Issue #34: use real drivers, replace only model CLIs. Harness logs live inside
# the fixture repository so their growth cannot accidentally qualify as code.
cat > "$TMP/stage-worker" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$2" in
  '# Role: Ralph Planner'*|'# Role: Spec-driven Planner'*)
    case "$STAGE_CASE" in
      planner-stderr) printf '<allowed-paths>file.txt</allowed-paths>\n## NEED RESEARCH\n- stderr-decoy\n' >&2 ;;
      planner-blank) printf ' \n\t'; echo guidance >&2 ;;
      planner-missing-paths) echo 'real plan without paths'; echo '<allowed-paths>file.txt</allowed-paths>' >&2 ;;
      *)
        echo '<allowed-paths>file.txt,new.txt</allowed-paths>'
        if [ "$STAGE_CASE" = planner-mixed ]; then
          printf 'STDERR-ONLY-DECOY\n<allowed-paths>secret.txt</allowed-paths>\n## NEED RESEARCH\n- stderr-decoy\n' >&2
        fi ;;
    esac
    exit 0 ;;
esac
n=0
[ ! -f "$STAGE_CODER_COUNT" ] || n=$(cat "$STAGE_CODER_COUNT")
n=$((n + 1))
echo "$n" > "$STAGE_CODER_COUNT"
printf '%s\n' "$2" >> "$STAGE_CODER_PROMPTS"
if [ "$STAGE_MODE" = retry ] && [ "$n" -eq 1 ]; then
  echo first-attempt > file.txt
  echo first-attempt-summary
  exit 0
fi
case "$STAGE_CASE" in
  noop|dirty-noop) echo 'tool soft-denied' >&2 ;;
  whitespace) printf ' \t\n'; echo 'tool soft-denied' >&2 ;;
  silent-change) echo "changed-$n" > file.txt ;;
  silent-new) echo new > new.txt ;;
  silent-commit)
    echo changed > file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm implement ;;
  empty-commit) git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm empty --allow-empty ;;
  failed) echo partial > file.txt; echo summary; exit 17 ;;
  cli-config|cli-config-commit)
    echo changed > file.txt
    mkdir -p .claude; echo changed > .claude/settings.json
    if [ "$STAGE_CASE" = cli-config-commit ]; then
      git add file.txt .claude/settings.json
      git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm config
    fi
    echo summary ;;
  cli-state) mkdir -p .claude; echo local-state > .claude/settings.local.json ;;
  harness-only) echo bookkeeping >> "$STAGE_FIX"; mkdir -p "$STAGE_WORKSPACE/state"; echo artifact > "$STAGE_WORKSPACE/state/extra"; echo guidance >&2 ;;
  *) echo 'already satisfied, checked implementation' ;;
esac
STUB
chmod +x "$TMP/stage-worker"
for plugin in ralph-trio spec-trio; do
  for entry in \
    planner-stderr:reviewed planner-stderr:autoship planner-blank:reviewed \
    planner-mixed:reviewed planner-missing-paths:reviewed \
    noop:reviewed noop:autoship noop:retry noop:worktree \
    whitespace:reviewed whitespace:retry dirty-noop:reviewed \
    silent-change:reviewed silent-change:retry silent-change:worktree \
    silent-new:autoship silent-commit:autoship summary:reviewed summary:retry \
    empty-commit:reviewed failed:reviewed failed:autoship failed:retry harness-only:autoship \
    cli-config:autoship cli-config-commit:reviewed cli-config-commit:retry \
    cli-state:autoship cli-state:retry silent-change:workspace-root harness-only:workspace-root; do
    scenario=${entry%:*}; mode=${entry#*:}
    case_root="$TMP/stage-$plugin-$scenario-$mode"
    repo="$case_root/repo"
    mkdir -p "$repo"
    git init -q "$repo"
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name Fixture
    # XDG Git ignore files still apply when GIT_CONFIG_GLOBAL is disabled.
    git -C "$repo" config core.excludesFile /dev/null
    printf baseline > "$repo/file.txt"
    printf '# Spec\n## §5 Test criteria\n### §5.1 implement file\n' > "$repo/spec.md"
    printf -- '- [ ] §5.1 implement file\n' > "$repo/BACKLOG.md"
    if [ "$scenario" = cli-config-commit ]; then
      mkdir -p "$repo/.claude"; echo baseline > "$repo/.claude/settings.json"
    fi
    git -C "$repo" add .
    git -C "$repo" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm baseline
    baseline=$(git -C "$repo" rev-parse HEAD)
    [ "$scenario" != dirty-noop ] || echo preexisting-dirty > "$repo/file.txt"
    state="$repo/.driver-state"
    [ "$mode" != workspace-root ] || state="$repo"
    args=(--backlog "$repo/BACKLOG.md" --max-iter 1)
    [ "$plugin" != spec-trio ] || args+=(--spec "$repo/spec.md" --test-cmd 'echo tested >> "$STAGE_TEST_TESTS"')
    [ "$mode" != autoship ] || args+=(--autoship)
    [ "$mode" != worktree ] || args+=(--worktree)
    review_case=stage
    [ "$mode" != retry ] || review_case=retry
    driver_rc=0
    (
      cd "$repo"
      env -u REVIEWER_CLI -u REVIEWER_ROLE_FILE -u MANIFEST_PARENT_TMP \
        -u DEV_TRIO_REVIEW_PROFILE -u DEV_TRIO_REVIEW_RECEIPT -u RESEARCHER_CLI \
        PATH="$ROOT/dev-trio/bin:$PATH" AGENT_TEAM=stage TMUX='' \
        AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
        DEV_TRIO_REVIEWER_MODEL=codex DEV_TRIO_RESEARCHER_MODEL=agy \
        PLANNER_CLI="$TMP/stage-worker" CODER_CLI="$TMP/stage-worker" \
        CODEX_CLI="$TMP/reviewer" AGY_CLI="$TMP/researcher" \
        RALPH_TRIO_WORKSPACE="$state" SPEC_TRIO_WORKSPACE="$state" \
        STAGE_CASE="$scenario" STAGE_MODE="$mode" STAGE_WORKSPACE="$state" \
        STAGE_FIX="$repo/fix_plan.md" STAGE_CODER_COUNT="$case_root/coder.count" \
        STAGE_CODER_PROMPTS="$case_root/coder.prompts" STAGE_TEST_TESTS="$case_root/tests" \
        REVIEW_TEST_CASE="$review_case" REVIEW_TEST_COUNTER="$case_root/reviewer.count" \
        REVIEW_TEST_RESEARCH="$case_root/research" REVIEW_TEST_DECOY="$case_root/decoy.md" \
        "$ROOT/$plugin/bin/$plugin.sh" "${args[@]}"
    ) < /dev/null > "$TMP/driver.out" 2>&1 || driver_rc=$?
    failed=0; plan_failed=0; scope_failed=0
    case "$scenario" in
      planner-stderr|planner-blank) failed=1; plan_failed=1 ;;
      noop|whitespace|dirty-noop|empty-commit|failed|harness-only|cli-state) failed=1 ;;
      planner-missing-paths) if [ "$plugin" = spec-trio ]; then failed=1; scope_failed=1; fi ;;
    esac
    if [ "$plugin" = spec-trio ]; then
      case "$scenario" in cli-state|cli-config|cli-config-commit) failed=1; scope_failed=1 ;; esac
    fi
    expected_rc=0
    if [ "$plugin" = spec-trio ] && [ "$failed" = 1 ]; then expected_rc=3; fi
    if [ "$scope_failed" = 1 ]; then expected_rc=4; fi
    check "$plugin $entry driver status" test "$driver_rc" -eq "$expected_rc"
    coder_calls=1; reviewer_calls=1
    if [ "$failed" = 1 ] || [ "$mode" = autoship ]; then reviewer_calls=0; fi
    if [ "$plan_failed" = 1 ] || { [ "$scope_failed" = 1 ] && [ "$scenario" = planner-missing-paths ]; }; then coder_calls=0; fi
    if [ "$mode" = retry ]; then coder_calls=2; reviewer_calls=$((reviewer_calls + 1)); fi
    actual_coder=0; actual_reviewer=0
    [ ! -f "$case_root/coder.count" ] || actual_coder=$(cat "$case_root/coder.count")
    [ ! -f "$case_root/reviewer.count" ] || actual_reviewer=$(cat "$case_root/reviewer.count")
    check "$plugin $entry coder calls" test "$actual_coder" -eq "$coder_calls"
    check "$plugin $entry reviewer calls" test "$actual_reviewer" -eq "$reviewer_calls"
    if [ "$failed" = 1 ]; then
      check "$plugin $entry pending task" grep -q -- '- \[ \]' "$repo/BACKLOG.md"
    else
      check "$plugin $entry completed task" sh -c '! grep -q -- "- \[ \]" "$1"' _ "$repo/BACKLOG.md"
    fi
    if [ "$mode" = worktree ] && [ "$failed" = 1 ]; then
      check "$plugin failed coder did not merge" test "$(git -C "$repo" rev-parse HEAD)" = "$baseline"
    fi
    if [ "$mode" = worktree ] && [ "$failed" = 0 ]; then
      check "$plugin silent coder change merged" grep -q changed "$repo/file.txt"
    fi
    if [ "$scenario" = planner-mixed ]; then
      check "$plugin stderr not injected into coder prompt" sh -c '! grep -q STDERR-ONLY-DECOY "$1"' _ "$case_root/coder.prompts"
      check "$plugin stderr does not request research" test ! -e "$case_root/research"
    fi
    if [ "$failed" = 1 ] && [ "$scope_failed" = 0 ]; then
      stage=code
      [ "$mode" != retry ] || stage=code2
      [ "$plan_failed" != 1 ] || stage=plan
      result=("$state/log/stage/"*-"$stage.manifest.json")
      stage_rc=5; cli_rc=0
      if [ "$scenario" = failed ]; then stage_rc=17; cli_rc=17; fi
      check "$plugin $entry manifest stage rc" json_is "${result[0]}" \
        "any(.inputs[]; .kind==\"stage-rc\" and .value==\"$stage_rc\")"
      check "$plugin $entry manifest actual CLI rc" json_is "${result[0]}" \
        "any(.inputs[]; .kind==\"cli-rc\" and .value==\"$cli_rc\")"
    fi
    if [ "$plugin" = spec-trio ]; then
      test_calls=0
      [ ! -f "$case_root/tests" ] || test_calls=$(wc -l < "$case_root/tests" | tr -d ' ')
      expected_tests=$coder_calls
      [ "$failed" != 1 ] || expected_tests=$((coder_calls > 0 ? coder_calls - 1 : 0))
      check "$plugin $entry tests require coder success and valid scope" test "$test_calls" -eq "$expected_tests"
    fi
  done
done

printf 'review-caller smoke: %s assertions passed\n' "$PASS"
