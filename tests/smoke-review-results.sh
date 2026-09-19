#!/usr/bin/env bash
# Model-free regressions for dev-trio #19 and #21, including real wrapper and
# dashboard consumers. No tmux, login, model CLI, or user's registry is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../dev-trio/lib/review-result.sh
. "$ROOT/dev-trio/lib/review-result.sh"
TMP=$(mktemp -d)
trap 'wait; rm -rf "$TMP"' EXIT
PASS=0
check() {
  local label="$1"; shift
  if ! "$@"; then
    echo "FAIL: $label" >&2
    for diagnostic in "$TMP"/parallel-*.err; do
      [ ! -f "$diagnostic" ] || cat "$diagnostic" >&2
    done
    exit 1
  fi
  PASS=$((PASS + 1))
}
json_is() { jq -e "$2" "$1" >/dev/null; }
no_receipt_result() { ! review_result_from_receipt "$1" "$2" >/dev/null; }
no_match() { ! grep -q "$1" "$2"; }
fixture() {
  printf '## Verdict\n%s\n\n## Findings\n\n### Blocker\n- 없음.\n\n### Major\n- None.\n\n### Minor / Nit\n- 없음\n' "$1" > "$TMP/review.md"
}
parse() { review_result_parse "$TMP/review.md" "${1:-0}" "${2:-default}" > "$TMP/parsed.json"; }
for token in SHIP NEEDS-FIX DISCUSS; do
  for separator in ' — ' '. '; do
    fixture "$token${separator}reason"
    parse
    check "$token punctuation parsed" json_is "$TMP/parsed.json" ".verdict == \"$token\" and .exit_code == 0 and .status == \"ok\""
    check 'empty placeholders count zero' json_is "$TMP/parsed.json" '.findings == {blocker:[],major:[],minor:[]}'
    check 'result reader agrees' review_result_read "$TMP/parsed.json" >/dev/null
  done
done
fixture 'NEEDS-FIX — findings'
cat >> "$TMP/review.md" <<'REVIEW'
### Blocker
- None of the writes are atomic.
- 없음. 이 문장은 실제 finding입니다.
- x
- `a.py:2` — preserve "quotes" and backslashes \.
### Major
- none found
### Minor / Nit
- NONE
- nOnE.
- 없음!
## What I checked
- not a finding
REVIEW
parse
check 'only exact placeholders excluded' json_is "$TMP/parsed.json" '(.findings.blocker|length)==4 and (.findings.major|length)==1 and (.findings.minor|length)==1'
check 'finding text remains intact' json_is "$TMP/parsed.json" '.findings.blocker[3] == "- `a.py:2` — preserve \"quotes\" and backslashes \\."'
# CRLF is normalized only for parsing; the raw final must stay byte-identical.
awk '{ printf "%s\r\n", $0 }' "$TMP/review.md" > "$TMP/crlf.md"
cp "$TMP/crlf.md" "$TMP/review.md"
parse
check 'CRLF matches findings' json_is "$TMP/parsed.json" '(.findings.blocker|length)==4'
check 'CRLF source preserved' cmp -s "$TMP/crlf.md" "$TMP/review.md"
printf '## Verdict\nSHIP — reason\n' > "$TMP/review.md"
parse
check 'missing findings are unknown' json_is "$TMP/parsed.json" '.verdict == "SHIP" and .findings == {blocker:null,major:null,minor:null}'
for invalid in \
  'SHIP — only prose' \
  '## Verdict\nMAYBE — unknown' \
  '## Verdict\nSHIPPER — prefix' \
  '## Verdict\nSHIP' \
  '## Verdict\nSHIP — ' \
  '## Verdict\n\nSHIP — separated' \
  '## Verdict' \
  '## Verdict\nSHIP — one\n## Verdict\nSHIP — duplicate' \
  '## Verdict\nSHIP — one\n## Verdict\nNEEDS-FIX — conflict' \
  '## Verdict\nSHIP — one\n## Verdict \nNEEDS-FIX — conflict' \
  '## Verdict\nSHIP — one\n## Verdict ##\nNEEDS-FIX — conflict' \
  '## Verdict\nSHIP — one\n  ## Verdict\nNEEDS-FIX — conflict' \
  '```markdown\n## Verdict\nSHIP — example\n```' \
  '~~~\n## Verdict\nSHIP — example\n~~~' \
  '> ## Verdict\n> SHIP — quoted' \
  '    ## Verdict\n    SHIP — indented'; do
  printf '%b\n' "$invalid" > "$TMP/review.md"
  parse
  check 'invalid review fails closed' json_is "$TMP/parsed.json" '.status=="parse-failed" and .exit_code==3 and .verdict==null and (.error|length)>0'
done
# Every permitted fence indentation is excluded; four-space closing markers
# are content inside an existing fence and must not expose later examples.
for indent in '' ' ' '  ' '   '; do
  printf '%s```markdown\n## Verdict\nSHIP — role example\n%s```\n' "$indent" "$indent" > "$TMP/review.md"
  parse
  check 'indented fence never supplies a verdict' json_is "$TMP/parsed.json" '.status=="parse-failed" and .verdict==null'
done
printf '```\n## Verdict\nSHIP — example\n    ```\n## Verdict\nNEEDS-FIX — still fenced\n' > "$TMP/review.md"
parse
check 'four-space closing fence stays open' json_is "$TMP/parsed.json" '.status=="parse-failed" and .verdict==null'
# Unsupported/unclosed examples must never hide a later conflicting verdict.
for tail in \
  '```x` y\n## Verdict\nNEEDS-FIX — hidden' \
  '```x` y\n## Verdict\nNEEDS-FIX — hidden\n```' \
  '- example\n  ```\n  snippet\n     ```\n## Verdict\nNEEDS-FIX — hidden'; do
  printf '## Verdict\nSHIP — first\n%b\n' "$tail" > "$TMP/review.md"
  parse
  check 'unsupported fences cannot hide competing verdict' json_is "$TMP/parsed.json" '.status=="parse-failed" and .verdict==null'
done
cp "$ROOT/dev-trio/lib/roles/reviewer.md" "$TMP/review.md"
parse
check 'echoed role template is not a review' json_is "$TMP/parsed.json" '.status=="parse-failed" and .verdict==null'
cat > "$TMP/review.md" <<'REVIEW'
   ````markdown
## Verdict
SHIP — example
```
## Verdict
SHIP — still fenced
   ````
## Verdict
DISCUSS. actual verdict
> ## Verdict
> SHIP — quoted
REVIEW
parse
check 'only real unfenced verdict used' json_is "$TMP/parsed.json" '.verdict=="DISCUSS"'
fixture 'OUT-OF-SCOPE — contract violation'
parse
check 'default vocabulary stays closed' json_is "$TMP/parsed.json" '.exit_code==3 and .verdict==null'
parse 0 spec
check 'explicit spec profile permits contract verdict' json_is "$TMP/parsed.json" '.verdict=="OUT-OF-SCOPE" and .exit_code==0'
fixture 'SHIP — apparently valid'
parse 7
check 'failed invocation overrides valid text' json_is "$TMP/parsed.json" '.status=="invocation-failed" and .exit_code==7 and .invocation_rc==7 and .verdict==null'
: > "$TMP/review.md"
parse
check 'empty final rejected' json_is "$TMP/parsed.json" '.exit_code==3'
rm "$TMP/review.md"
parse
check 'missing final rejected' json_is "$TMP/parsed.json" '.exit_code==3'

cat > "$TMP/reviewer" <<'STUB'
#!/usr/bin/env bash
set -eu
final=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) final="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$final" ] && [ "${TEST_MISSING_FINAL:-0}" != 1 ]; then cp "$TEST_REVIEW_FILE" "$final"; fi
cat "${TEST_STDOUT_FILE:-$TEST_REVIEW_FILE}"
exit "${TEST_REVIEW_RC:-0}"
STUB
chmod +x "$TMP/reviewer"
# Pin all model selection, role, namespace and output controls for fixtures.
invoke() {
  env -u REVIEWER_CLI -u CODEX_CLI -u CLAUDE_CLI -u REVIEWER_ROLE_FILE \
    -u DEV_TRIO_REVIEW_PROFILE -u DEV_TRIO_REVIEW_RECEIPT -u MANIFEST_PARENT_TMP \
    -u TEST_MISSING_FINAL -u TEST_STDOUT_FILE -u TEST_REVIEW_RC \
    AGENT_TEAM=review-test TMUX='' AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
    DEV_TRIO_LOG_DIR="$TMP/log" DEV_TRIO_REVIEWER_MODEL=codex \
    CODEX_CLI="$TMP/reviewer" CLAUDE_CLI="$TMP/reviewer" \
    TEST_REVIEW_FILE="$TMP/review.md" "$@" \
    "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review'
}
run_review() {
  local expected="$1" rc=0; shift
  invoke "$@" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || rc=$?
  check "wrapper rc=$expected (actual $rc)" test "$rc" -eq "$expected"
  LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
  RESULT="${LOG%.log}.review.json"
  MANIFEST="${LOG%.log}.manifest.json"
  FINAL="${LOG%.log}.final.md"
  check 'wrapper publishes a readable result' review_result_read "$RESULT" >/dev/null
  check 'result matches wrapper rc' json_is "$RESULT" ".exit_code==$expected"
  check 'stderr names exact result' grep -Fq "result: $RESULT" "$TMP/wrapper.err"
}
dashboard() {
  printf q | env AGENT_TEAM=review-test TMUX='' TERM=dumb DEV_TRIO_LOG_DIR="$TMP/log" \
    "$@" bash "$ROOT/dev-trio/bin/dashboard.sh" codex > "$TMP/dashboard.out"
}
for token in SHIP NEEDS-FIX DISCUSS; do
  for separator in ' — ' '. '; do
    for model in codex claude; do
      fixture "$token${separator}wrapper reason"
      run_review 0 DEV_TRIO_REVIEWER_MODEL="$model"
      check 'manifest stores parsed verdict' json_is "$MANIFEST" ".verdict==\"$token\" and .ended_at!=null"
      check 'manifest points to this result' json_is "$MANIFEST" ".inputs | any(.kind==\"review-result\" and .path==\"$RESULT\" and (.sha256|length)==64)"
      check 'raw final preserved' cmp -s "$TMP/review.md" "$FINAL"
      dashboard
      check 'dashboard uses same verdict line' grep -Fq "$token${separator}wrapper reason" "$TMP/dashboard.out"
      check 'dashboard counts localized empties correctly' grep -q '0 blocker' "$TMP/dashboard.out"
      check 'dashboard suppresses placeholder text' no_match '없음' "$TMP/dashboard.out"
    done
  done
done
fixture 'SHIP — native authoritative'
printf '## Verdict\nNEEDS-FIX — decoy stdout\n' > "$TMP/decoy.md"
run_review 0 TEST_STDOUT_FILE="$TMP/decoy.md"
dashboard
check 'native final beats decoy stream' grep -q 'SHIP — native authoritative' "$TMP/dashboard.out"
check 'decoy is not a verdict' no_match 'decoy stdout' "$TMP/dashboard.out"
printf '## Verdict\nSHIP — no findings\n' > "$TMP/review.md"
run_review 0
dashboard
check 'missing sections are displayed unknown' grep -q '? blocker' "$TMP/dashboard.out"
fixture 'SHIP — failed invocation decoy'
run_review 9 TEST_REVIEW_RC=9
check 'failed invocation leaves manifest null' json_is "$MANIFEST" '.verdict==null and .ended_at!=null'
dashboard
check 'dashboard reports invocation failure' grep -q 'Review failed: reviewer invocation failed' "$TMP/dashboard.out"
check 'failed output is not displayed as verdict' no_match 'Verdict:' "$TMP/dashboard.out"
# latest-final may point at an old successful response. Consumers must use the
# run selected by latest-log, and never use stdout when native final is absent.
OLD_FINAL="$FINAL"
run_review 3 TEST_MISSING_FINAL=1
ln -sfn "$OLD_FINAL" "$TMP/log/review-test/latest-codex.final.md"
check 'missing native final leaves manifest null' json_is "$MANIFEST" '.verdict==null'
dashboard
check 'old final and plausible stdout ignored' no_match 'Verdict:' "$TMP/dashboard.out"
check 'parse error exposed' grep -q 'Review failed: final response missing' "$TMP/dashboard.out"
fixture 'MAYBE — unknown'
run_review 3
check 'unknown token leaves manifest null' json_is "$MANIFEST" '.verdict==null'
for invalid in \
  '' \
  'SHIP — prose only' \
  '## Verdict\nSHIP — first\n## Verdict\nDISCUSS — duplicate' \
  '## Verdict\nSHIP — first\n## Verdict \nDISCUSS — duplicate' \
  '```\n## Verdict\nSHIP — prompt example\n```'; do
  printf '%b' "$invalid" > "$TMP/review.md"
  run_review 3
  check 'malformed wrapper output leaves manifest null' json_is "$MANIFEST" '.verdict==null'
  dashboard
  check 'malformed wrapper output reports error' grep -q 'Review failed:' "$TMP/dashboard.out"
  check 'malformed wrapper output never implies a verdict' no_match 'Verdict:' "$TMP/dashboard.out"
done
fixture 'SHIP — reviewer exit 3'
run_review 3 TEST_REVIEW_RC=3 DEV_TRIO_REVIEWER_MODEL=claude
check 'reviewer exit 3 is distinct from a parse error' json_is "$RESULT" '.status=="invocation-failed" and .invocation_rc==3'

# Result missing/corrupt: preserve the raw log for inspection, never re-parse it.
fixture 'SHIP — no result fallback'
run_review 0
mv "$RESULT" "$RESULT.saved"
dashboard
check 'legacy result is unavailable' grep -q 'Review result unavailable' "$TMP/dashboard.out"
check 'legacy stream never implies SHIP' no_match 'Verdict:' "$TMP/dashboard.out"
printf '{broken' > "$RESULT"
dashboard
check 'corrupt result is unavailable' grep -q 'Review result unavailable' "$TMP/dashboard.out"

# Retarget latest-log during the first readlink call, before any content is
# read. A frame must still show only the pinned invocation, never the new one.
fixture 'SHIP — pinned invocation'
run_review 0
PINNED_LOG="$LOG"
fixture 'NEEDS-FIX — retargeted invocation'
run_review 0
RETARGET_LOG="$LOG"
ln -sfn "$PINNED_LOG" "$TMP/log/review-test/latest-codex.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/readlink" <<'STUB'
#!/usr/bin/env bash
target=$(/usr/bin/readlink "$1") || exit
ln -sfn "$REVIEW_LINK_TARGET" "$1"
printf '%s\n' "$target"
STUB
chmod +x "$TMP/bin/readlink"
dashboard PATH="$TMP/bin:$PATH" REVIEW_LINK_TARGET="$RETARGET_LOG"
check 'dashboard pins the original log target' grep -q 'SHIP — pinned invocation' "$TMP/dashboard.out"
check 'retarget cannot mix another review into the frame' no_match 'retargeted invocation' "$TMP/dashboard.out"
rm "$TMP/bin/readlink"

fixture 'OUT-OF-SCOPE. violates spec'
run_review 0 DEV_TRIO_REVIEW_PROFILE=spec
check 'spec wrapper verdict preserved' json_is "$MANIFEST" '.verdict=="OUT-OF-SCOPE"'
dashboard
check 'spec dashboard reports contract verdict' grep -q 'OUT-OF-SCOPE. violates spec' "$TMP/dashboard.out"
fixture 'SHIP — bound receipt'
RECEIPT=$(review_receipt_create "$TMP/caller.log")
run_review 0 DEV_TRIO_REVIEW_RECEIPT="$RECEIPT"
review_result_from_receipt "$RECEIPT" 0 > "$TMP/receipt-result.json"
check 'receipt identifies exact wrapper result' json_is "$TMP/receipt-result.json" ".result_path==\"$RESULT\" and .final_path==\"$FINAL\" and .verdict==\"SHIP\""
check 'receipt cannot override failed wrapper rc' no_receipt_result "$RECEIPT" 2
EMPTY_RECEIPT=$(review_receipt_create "$TMP/caller.log")
check 'fresh empty receipt cannot reuse previous result' no_receipt_result "$EMPTY_RECEIPT" 0
# Force an artifact failure after model success and after a failed invocation.
for invocation_rc in 0 7; do
  expected_rc=2
  [ "$invocation_rc" -eq 0 ] || expected_rc="$invocation_rc"
  actual_rc=0
  invoke DEV_TRIO_REVIEW_RECEIPT="$TMP/missing/receipt" TEST_REVIEW_RC="$invocation_rc" > "$TMP/io.out" 2> "$TMP/io.err" || actual_rc=$?
  check 'artifact failure preserves failed invocation rc' test "$actual_rc" -eq "$expected_rc"
  failed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
  check 'artifact failure completes the log' grep -q "=== END (rc=$expected_rc) ===" "$failed_log"
  check 'artifact failure has an explicit diagnostic' grep -q 'result write failed' "$TMP/io.err"
  check 'artifact failure leaves no successful result' test ! -f "${failed_log%.log}.review.json"
  check 'artifact failure leaves manifest null' json_is "${failed_log%.log}.manifest.json" '.verdict==null and .ended_at!=null'
done

# A nested dispatcher adds only its role to the parent manifest.
# shellcheck source=../dev-trio/lib/manifest.sh
. "$ROOT/dev-trio/lib/manifest.sh"
manifest_init fixture-parent "$TMP/parent.log"
manifest_set_verdict DISCUSS
PARENT_TMP="$MANIFEST_TMP"
fixture 'SHIP — nested review'
run_review 0 MANIFEST_PARENT_TMP="$PARENT_TMP"
check 'nested review leaves parent verdict alone' json_is "$PARENT_TMP" '.verdict=="DISCUSS" and (.roles|length)==1 and .ended_at==null'
check 'nested review emits no child manifest' test ! -e "$MANIFEST"
manifest_finalize

# Force both invocations into the same timestamp and shared namespace.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = '+%Y%m%d-%H%M%S' ]; then echo 20000101-000000; else /bin/date "$@"; fi
STUB
chmod +x "$TMP/bin/date"
fixture 'SHIP — concurrent review'
invoke PATH="$TMP/bin:$PATH" > "$TMP/parallel-1.out" 2> "$TMP/parallel-1.err" &
pid1=$!
invoke PATH="$TMP/bin:$PATH" > "$TMP/parallel-2.out" 2> "$TMP/parallel-2.err" &
pid2=$!
rc1=0; rc2=0
wait "$pid1" || rc1=$?
wait "$pid2" || rc2=$?
check 'first concurrent invocation succeeds' test "$rc1" -eq 0
check 'second concurrent invocation succeeds' test "$rc2" -eq 0
results=( "$TMP/log/review-test"/codex-20000101-000000-*.review.json )
check 'concurrent invocations have distinct results' test "${#results[@]}" -eq 2
for result in "${results[@]}"; do
  check 'concurrent result complete' json_is "$result" '.verdict=="SHIP" and .exit_code==0'
  check 'concurrent manifest complete' json_is "${result%.review.json}.manifest.json" '.verdict=="SHIP" and .ended_at!=null'
  check 'concurrent final intact' cmp -s "$TMP/review.md" "${result%.review.json}.final.md"
done
printf 'review-result smoke: %s assertions passed\n' "$PASS"
