#!/usr/bin/env bash
# Real loop drivers + reviewer wrapper, with only the model CLIs replaced.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
case "$2" in
  '# Role: Ralph Planner'*|'# Role: Spec-driven Planner'*)
    echo '<allowed-paths>file.txt</allowed-paths>' ;;
  *)
    printf 'implemented\n' > file.txt
    git add file.txt
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm 'implement fixture' || true
    echo 'coder done' ;;
esac
STUB
cat > "$TMP/researcher" <<'STUB'
#!/usr/bin/env bash
printf 'research\n' >> "$REVIEW_TEST_RESEARCH"
echo 'fixture research evidence'
STUB
cat > "$TMP/reviewer" <<'STUB'
#!/usr/bin/env bash
set -eu
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
  retry:1) printf '## Verdict\nNEEDS-FIX — need evidence\n## NEED RESEARCH\n- verify the API\n' > "$final" ;;
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
for plugin in ralph-trio spec-trio; do
  for scenario in disagree malformed retarget failed retry; do
    case_root="$TMP/$plugin-$scenario"
    repo="$case_root/repo"
    state="$case_root/state"
    mkdir -p "$repo"
    git init -q "$repo"
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name Fixture
    printf 'baseline\n' > "$repo/file.txt"
    printf '# Spec\n## §5 Test criteria\n### §5.1 implement file\n' > "$repo/spec.md"
    printf -- '- [ ] §5.1 implement file\n' > "$repo/BACKLOG.md"
    git -C "$repo" add file.txt spec.md BACKLOG.md
    git -C "$repo" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm baseline
    args=(--backlog "$repo/BACKLOG.md" --max-iter 1)
    [ "$plugin" != spec-trio ] || args+=(--spec "$repo/spec.md" --test-cmd 'git diff --check')
    case "$scenario" in retarget|failed|retry) ;; *) args+=(--no-research) ;; esac
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
        "$ROOT/$plugin/bin/$plugin.sh" "${args[@]}"
    ) > "$TMP/driver.out" 2>&1 || driver_rc=$?
    expected_rc=0
    if [ "$plugin" = spec-trio ] && { [ "$scenario" = malformed ] || [ "$scenario" = failed ]; }; then expected_rc=4; fi
    check "$plugin $scenario exit status" test "$driver_rc" -eq "$expected_rc"
    expected_calls=1
    [ "$scenario" != retry ] || expected_calls=2
    check "$plugin $scenario reviewer count" test "$(cat "$case_root/count")" -eq "$expected_calls"
    if [ "$scenario" = retry ]; then
      check "$plugin real research request runs once" test "$(wc -l < "$case_root/research" | tr -d ' ')" -eq 1
    else
      check "$plugin never dispatches stale/failed research" test ! -e "$case_root/research"
    fi
    manifests=( "$state/log/caller"/"$plugin"-*-review*.manifest.json )
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
    if [ "$scenario" = retry ]; then
      check "$plugin re-review uses canonical SHIP despite decoys" \
        jq -se '[.[]|select(.verdict=="SHIP")]|length==1' "${manifests[@]}" >/dev/null
    elif [ "$scenario" != malformed ] && [ "$scenario" != failed ]; then
      check "$plugin ignores competing legacy verdict" json_is "${manifests[0]}" '.verdict=="SHIP"'
    fi
  done
done
printf 'review-caller smoke: %s assertions passed\n' "$PASS"
