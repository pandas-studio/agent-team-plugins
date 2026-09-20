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
no_runstate_begin() { ! runstate_begin "$1" channel=codex wrapper=ask-reviewer.sh 2>/dev/null; }
no_runstate_complete() { ! runstate_complete "$1" exit_code=0 2>/dev/null; }
no_runstate_read() { ! runstate_read "$1" >/dev/null 2>&1; }
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
INVOKE_ENV=(
  -u REVIEWER_CLI -u CODEX_CLI -u CLAUDE_CLI -u REVIEWER_ROLE_FILE
  -u DEV_TRIO_REVIEW_PROFILE -u DEV_TRIO_REVIEW_RECEIPT -u MANIFEST_PARENT_TMP
  -u TEST_MISSING_FINAL -u TEST_STDOUT_FILE -u TEST_REVIEW_RC
  AGENT_TEAM=review-test TMUX='' AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json"
  DEV_TRIO_LOG_DIR="$TMP/log" DEV_TRIO_REVIEWER_MODEL=codex
  CODEX_CLI="$TMP/reviewer" CLAUDE_CLI="$TMP/reviewer"
  TEST_REVIEW_FILE="$TMP/review.md"
)
invoke() {
  env "${INVOKE_ENV[@]}" "$@" "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review'
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
research_dashboard() {
  env AGENT_TEAM=review-test TMUX='' TERM=dumb DEV_TRIO_LOG_DIR="$TMP/log" \
    "$@" bash "$ROOT/dev-trio/bin/dashboard.sh" agy --once < /dev/null > "$TMP/dashboard.out"
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

# #71: a pipeline ends when every process holding its write end closes it, not
# when the CLI exits. This wrapper appends its transcript through a descriptor,
# so a CLI that leaves a descendant holding either stream has no pipe of this
# wrapper's to hold — on the native and the stdout-capture path alike.
#
# The descendant blocks on a release file rather than a sleep, and records its
# own exit. The reproducer is then "the wrapper returned first", which says what
# the fix changed without asserting a wall-clock threshold on a loaded machine.
# Its watchdog keeps the old shape failing rather than hanging.
cat > "$TMP/leaky-reviewer" <<'STUB'
#!/usr/bin/env bash
final=""; prev=""
for a in "$@"; do
  [ "$prev" != "--output-last-message" ] || final="$a"
  prev="$a"
done
hold() {
  waited=0
  while [ ! -e "$LEAK_RELEASE" ] && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ -z "${LEAK_LATE:-}" ] || printf 'late descendant text\n' >&3
  : > "$LEAK_DONE"
}
# fd 3 is the held stream, so a late write lands where the wrapper would have
# been waiting. Only the named stream is inherited; the other goes to /dev/null.
case "${LEAK_STREAM:-stderr}" in
  stderr) hold 3>&2 >/dev/null & ;;
  stdout) hold 3>&1 2>/dev/null & ;;
esac
[ -z "$final" ] || cp "$TEST_REVIEW_FILE" "$final"
cat "$TEST_REVIEW_FILE"
exit "${TEST_REVIEW_RC:-0}"
STUB
chmod +x "$TMP/leaky-reviewer"
fixture 'SHIP — leaked descendant'
leak_release() {
  : > "$TMP/leak-release"
  waited=0
  while [ ! -e "$TMP/leak-done" ] && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
}
leak_review() {
  rm -f "$TMP/leak-release" "$TMP/leak-done"
  leak_rc=0
  invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
    LEAK_RELEASE="$TMP/leak-release" LEAK_DONE="$TMP/leak-done" "$@" \
    > "$TMP/leak.out" 2> "$TMP/leak.err" || leak_rc=$?
  leak_returned_first=0
  [ -e "$TMP/leak-done" ] || leak_returned_first=1
  leak_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
  leak_release
}
for leak_model in codex claude; do
  for leak_stream in stderr stdout; do
    leak_review DEV_TRIO_REVIEWER_MODEL="$leak_model" LEAK_STREAM="$leak_stream"
    check "a leaked $leak_stream does not hold the wrapper open ($leak_model)" \
      test "$leak_returned_first" -eq 1
    # Expected to hold before this change too — evidence of no regression, not
    # of the fix.
    check "the leaky run still succeeds ($leak_model/$leak_stream)" test "$leak_rc" -eq 0
    check "the leaky run answers on stdout ($leak_model/$leak_stream)" \
      grep -q 'SHIP — leaked descendant' "$TMP/leak.out"
    check "the transcript reached the log ($leak_model/$leak_stream)" \
      grep -q 'SHIP — leaked descendant' "$leak_log"
    check "the leaky run records a completion ($leak_model/$leak_stream)" \
      json_is "${leak_log%.log}.run.json" '.completion.exit_code==0'
    check "the leaky run publishes a verdict ($leak_model/$leak_stream)" \
      json_is "${leak_log%.log}.review.json" '.verdict=="SHIP"'
  done
done
# A failed invocation keeps its own status through the replay.
leak_review DEV_TRIO_REVIEWER_MODEL=codex LEAK_STREAM=stdout TEST_REVIEW_RC=7
check 'a leaked descendant cannot rewrite a failed rc' test "$leak_rc" -eq 7
check 'a failed leaky invocation still returns first' test "$leak_returned_first" -eq 1
# The replay is the frozen transcript: the header and the END marker belong to
# the log, not to stdout, and the wrapper adds exactly one blank line after it.
leak_review DEV_TRIO_REVIEWER_MODEL=codex LEAK_STREAM=stderr
check 'the replay excludes the log header' no_match '=== RESPONSE ===' "$TMP/leak.out"
check 'the replay excludes the end marker' no_match '=== END (rc=' "$TMP/leak.out"
# The oracle is the fixture the stub printed, not a re-parse of the log: the
# replay is those bytes verbatim plus the wrapper's own trailing newline. A
# transcript with CRLF, no final newline and a literal marker keeps the replay
# honest where the extractor normalizes.
printf '## Verdict\r\nSHIP — byte exact\r\n\r\n## Findings\r\n\r\n### Blocker\r\n- None.\r\n=== END (rc=9) ===\nno final newline' > "$TMP/bytes-review.md"
leak_review DEV_TRIO_REVIEWER_MODEL=codex LEAK_STREAM=stderr TEST_REVIEW_FILE="$TMP/bytes-review.md"
cat "$TMP/bytes-review.md" > "$TMP/bytes-expected"
printf '\n' >> "$TMP/bytes-expected"
check 'the replay is the transcript byte for byte' cmp -s "$TMP/bytes-expected" "$TMP/leak.out"
# Both sides carry one trailing blank line: the log's comes from the newline
# that opens the END marker, stdout's from the wrapper's own trailing echo.
fixture 'SHIP — leaked descendant'
leak_review DEV_TRIO_REVIEWER_MODEL=codex LEAK_STREAM=stderr
awk '/^=== RESPONSE ===$/ { inblk=1; next } /^=== END \(rc=/ { inblk=0; next } inblk' \
  "$leak_log" > "$TMP/leak.logged"
check 'the replay is exactly the logged transcript' cmp -s "$TMP/leak.logged" "$TMP/leak.out"
# What a descendant writes after its parent exited is not part of the review.
leak_review DEV_TRIO_REVIEWER_MODEL=claude LEAK_STREAM=stdout LEAK_LATE=1
# Without these two, the assertions below would pass on a descendant that never
# ran: the release helper times out silently.
check 'the late descendant finished' test -e "$TMP/leak-done"
check 'the late descendant did write' grep -q 'late descendant text' "$leak_log"
check 'a late descendant write stays out of stdout' no_match 'late descendant text' "$TMP/leak.out"
check 'a late descendant write stays out of the final' \
  no_match 'late descendant text' "${leak_log%.log}.final.md"
check 'a late descendant write does not truncate the review' \
  grep -q 'SHIP — leaked descendant' "${leak_log%.log}.final.md"
# A review that quotes the log's own markers parses the way it always has: the
# extractor resets at a second header and stops at an END line, and the frozen
# transcript is fed through it rather than used as the final directly.
printf '## Verdict\nDISCUSS — discarded by the reset\n=== RESPONSE ===\n' > "$TMP/marker-review.md"
printf '## Verdict\nSHIP — after the reset\n\n## Findings\n\n### Blocker\n- None.\n' >> "$TMP/marker-review.md"
printf '=== END (rc=0) ===\ntrailing console noise\n' >> "$TMP/marker-review.md"
leak_review DEV_TRIO_REVIEWER_MODEL=claude LEAK_STREAM=stderr TEST_REVIEW_FILE="$TMP/marker-review.md"
check 'a quoted header resets the synthesized final' \
  json_is "${leak_log%.log}.review.json" '.verdict=="SHIP"'
check 'a quoted end marker stops the synthesized final' \
  no_match 'trailing console noise' "${leak_log%.log}.final.md"
check 'the replay keeps what the extractor dropped' \
  grep -q 'trailing console noise' "$TMP/leak.out"
fixture 'SHIP — leaked descendant'

# A replay that cannot be written is not a failed review.
closed_rc=0
# Its own handshake files: reusing the shared pair would let a descendant see a
# release left by an earlier block and exit before the wrapper even returned.
rm -f "$TMP/closed-release" "$TMP/closed-done"
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/closed-release" LEAK_DONE="$TMP/closed-done" \
  DEV_TRIO_REVIEWER_MODEL=codex LEAK_STREAM=stderr >&- 2> "$TMP/closed.err" || closed_rc=$?
check 'the closed-stdout descendant really held' test ! -e "$TMP/closed-done"
: > "$TMP/closed-release"
check 'a closed stdout does not fail the review' test "$closed_rc" -eq 0
closed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
check 'a closed stdout still publishes the result' \
  json_is "${closed_log%.log}.review.json" '.verdict=="SHIP" and .exit_code==0'
# A snapshot that came up short must not be published as a review. Injected with
# a `head` shim: the wrapper copies the frozen range through it, so truncating
# that copy leaves a prefix that still parses — a verdict line with its findings
# missing — which is exactly what must be rejected instead.
mkdir -p "$TMP/headshim"
cat > "$TMP/headshim/head" <<'SHIM'
#!/bin/sh
/usr/bin/head "$@" | /usr/bin/head -c "${HEAD_SHIM_BYTES:-20}"
SHIM
chmod +x "$TMP/headshim/head"
printf '## Verdict\nSHIP — prefix only\n\n## Findings\n\n### Blocker\n- A real one.\n' > "$TMP/short-review.md"
short_rc=0
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/short-release" LEAK_DONE="$TMP/short-done" LEAK_STREAM=stderr \
  DEV_TRIO_REVIEWER_MODEL=claude TEST_REVIEW_FILE="$TMP/short-review.md" \
  PATH="$TMP/headshim:$PATH" HEAD_SHIM_BYTES=24 \
  > "$TMP/short.out" 2> "$TMP/short.err" || short_rc=$?
: > "$TMP/short-release"
check 'a short transcript capture is not a review' test "$short_rc" -eq 3
check 'a short capture is reported' grep -q 'could not be captured in full' "$TMP/short.err"
short_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
check 'a short capture publishes no verdict' \
  json_is "${short_log%.log}.review.json" '.verdict==null and .exit_code==3'
check 'a short capture leaves no partial final' test ! -s "${short_log%.log}.final.md"
fixture 'SHIP — leaked descendant'

# A log that becomes unopenable between the header and the run falls back to an
# out-of-band transcript rather than /dev/null, because the pipeline it replaces
# still delivered the review on stdout in that case (`tee -a` reports the open
# failure, then keeps copying and draining). Injected through a `wc` shim: the
# wrapper's first count is where it takes the transcript offset, so the log is
# swapped for a directory right after it and restored at the second count, in
# time for the END append.
mkdir -p "$TMP/wcshim"
cat > "$TMP/wcshim/wc" <<'SHIM'
#!/bin/sh
count=$(/usr/bin/wc "$@")
if [ -n "${WC_SHIM_DIR:-}" ]; then
  target="$WC_SHIM_DIR/$(readlink "$WC_SHIM_DIR/latest-codex.log")"
  if [ ! -e "$WC_SHIM_FIRED" ]; then
    : > "$WC_SHIM_FIRED"
    rm -f "$target" && mkdir "$target"
  elif [ -d "$target" ]; then
    rmdir "$target" && : > "$target"
  fi
fi
printf '%s\n' "$count"
SHIM
chmod +x "$TMP/wcshim/wc"
rm -f "$TMP/wc-fired"
fixture 'SHIP — out of band'
oob_rc=0
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/oob-release" LEAK_DONE="$TMP/oob-done" LEAK_STREAM=stderr \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/wcshim:$PATH" \
  WC_SHIM_DIR="$TMP/log/review-test" WC_SHIM_FIRED="$TMP/wc-fired" \
  > "$TMP/oob.out" 2> "$TMP/oob.err" || oob_rc=$?
: > "$TMP/oob-release"
check 'an unopenable log does not fail the review' test "$oob_rc" -eq 0
check 'an unopenable log falls back out of band' grep -q 'keeping it out of band' "$TMP/oob.err"
check 'the out-of-band transcript still reaches stdout' \
  grep -q 'SHIP — out of band' "$TMP/oob.out"
oob_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
check 'the out-of-band run still publishes a verdict' \
  json_is "${oob_log%.log}.review.json" '.verdict=="SHIP" and .exit_code==0'
check 'the out-of-band transcript is not left beside the logs' \
  test -z "$(find "$TMP/log/review-test" -name '*.transcript.*' -print -quit)"
fixture 'SHIP — leaked descendant'

# An interrupted run owes the caller what the CLI produced and no review. The
# signal has to land while the CLI is running, which is where the wrapper's own
# redirections are in effect: a replay from the EXIT trap there writes into the
# log instead of stdout (measured), so the wrapper records the signal and
# replays once the call has returned.
cat > "$TMP/slow-reviewer" <<'STUB'
#!/usr/bin/env bash
cat "$TEST_REVIEW_FILE"
: > "$SLOW_READY"
waited=0
while [ ! -e "$SLOW_RELEASE" ] && [ "$waited" -lt 150 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
exit 0
STUB
chmod +x "$TMP/slow-reviewer"
# `cmd &` keeps $! on the wrapper itself; backgrounding the invoke function
# would make it a subshell, and the signal would never reach the wrapper. Job
# control is on for the launch because a background job in a non-interactive
# shell inherits SIGINT ignored, and bash will not trap a signal that was
# ignored on entry — so without it the INT case would signal nothing and the
# run would simply succeed. With it the job leads its own process group and is
# signalled the way a terminal signals a foreground job.
interrupt_review() {
  local signal="$1"; shift
  rm -f "$TMP/slow-ready" "$TMP/slow-release"
  set -m
  env "${INVOKE_ENV[@]}" CODEX_CLI="$TMP/slow-reviewer" CLAUDE_CLI="$TMP/slow-reviewer" \
    SLOW_READY="$TMP/slow-ready" SLOW_RELEASE="$TMP/slow-release" "$@" \
    "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review' \
    > "$TMP/interrupted.out" 2> "$TMP/interrupted.err" &
  interrupted_pid=$!
  waited=0
  while [ ! -e "$TMP/slow-ready" ] && [ "$waited" -lt 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  interrupted_ready=0
  [ ! -e "$TMP/slow-ready" ] || interrupted_ready=1
  kill -"$signal" -"$interrupted_pid" 2>/dev/null || kill -"$signal" "$interrupted_pid" 2>/dev/null || true
  : > "$TMP/slow-release"
  interrupted_rc=0
  wait "$interrupted_pid" || interrupted_rc=$?
  set +m
  interrupted_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
}
# ralph-meta.sh's own extraction, verbatim from `:248` and `:256`: the log path
# out of this wrapper's stderr, then the response body out of that log. An
# interrupted run does not replay its transcript to stdout; it names its
# artifacts, and this is the consumer that makes that enough.
meta_log_path() {
  awk -F'[(),]' '/^\(log: / { for (i=1; i<=NF; i++) { if ($i ~ /log: /) { sub(/^[[:space:]]*log:[[:space:]]*/, "", $i); print $i; exit } } }' "$1"
}
meta_response_body() {
  awk '/^=== RESPONSE ===/{flag=1; next} /^=== END/{flag=0} flag' "$1" 2>/dev/null
}
fixture 'SHIP — interrupted'
for interrupt_signal in TERM INT; do
  interrupt_review "$interrupt_signal"
  check "the stub was running when signalled ($interrupt_signal)" test "$interrupted_ready" -eq 1
  expected_rc=143
  [ "$interrupt_signal" != INT ] || expected_rc=130
  check "an interrupted run keeps the signal's status ($interrupt_signal)" \
    test "$interrupted_rc" -eq "$expected_rc"
  check "an interrupted run records an aborted completion ($interrupt_signal)" \
    json_is "${interrupted_log%.log}.run.json" ".completion.reason==\"aborted\" and .completion.exit_code==$expected_rc"
  check "an interrupted run publishes no review ($interrupt_signal)" \
    test ! -f "${interrupted_log%.log}.review.json"
  check "an interrupted run names its artifacts ($interrupt_signal)" \
    grep -q "^(log: .*, rc=$expected_rc)$" "$TMP/interrupted.err"
  check "an interrupted run's stdout carries no transcript ($interrupt_signal)" \
    test ! -s "$TMP/interrupted.out"
  META_LOG_PATH=$(meta_log_path "$TMP/interrupted.err")
  check "a caller can extract the log path ($interrupt_signal)" \
    test "$META_LOG_PATH" = "$interrupted_log"
  meta_response_body "$META_LOG_PATH" > "$TMP/interrupted.body"
  check "a caller recovers the partial transcript ($interrupt_signal)" \
    grep -q 'SHIP — interrupted' "$TMP/interrupted.body"
done
# The three together: the log unopenable, the run interrupted, and a stdout that
# cannot take the replay. Nothing else holds those bytes, so the wrapper keeps
# the out-of-band transcript and says where it is — retention cannot depend on
# the replay having worked.
fixture 'SHIP — nowhere else to go'
rm -f "$TMP/wc-fired-oob" "$TMP/oob2-ready" "$TMP/oob2-release"
set -m
env "${INVOKE_ENV[@]}" CODEX_CLI="$TMP/slow-reviewer" CLAUDE_CLI="$TMP/slow-reviewer" \
  SLOW_READY="$TMP/oob2-ready" SLOW_RELEASE="$TMP/oob2-release" \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/wcshim:$PATH" \
  WC_SHIM_DIR="$TMP/log/review-test" WC_SHIM_FIRED="$TMP/wc-fired-oob" \
  "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review' \
  >&- 2> "$TMP/oob2.err" &
oob2_pid=$!
waited=0
while [ ! -e "$TMP/oob2-ready" ] && [ "$waited" -lt 150 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check 'the stub was running when signalled (out of band)' test -e "$TMP/oob2-ready"
kill -TERM -"$oob2_pid" 2>/dev/null || kill -TERM "$oob2_pid" 2>/dev/null || true
: > "$TMP/oob2-release"
oob2_rc=0
wait "$oob2_pid" || oob2_rc=$?
set +m
check 'an interrupted out-of-band run keeps the signal status' test "$oob2_rc" -eq 143
check 'an interrupted out-of-band run still names its artifacts' \
  grep -q '^(log: .*, rc=143)$' "$TMP/oob2.err"
check 'the retained transcript is reported' grep -q 'the transcript is at' "$TMP/oob2.err"
OOB2_KEPT=$(sed -n 's/.*the transcript is at //p' "$TMP/oob2.err" | tail -1)
check 'the retained transcript exists' test -s "$OOB2_KEPT"
check 'the retained transcript holds what the CLI produced' \
  grep -q 'SHIP — nowhere else to go' "$OOB2_KEPT"
rm -f "$OOB2_KEPT"
fixture 'SHIP — leaked descendant'

# An ordinary run pays nothing for the bound — the failure mode the first
# attempt at this issue shipped with.
fixture 'SHIP — ordinary run'
ORDINARY_START=$SECONDS
run_review 0
# 5 s is where the first attempt at this issue landed — it charged every
# ordinary call the whole drain deadline. An ordinary stubbed run here is ~0.3 s,
# so the threshold catches that failure with room to spare on a loaded runner.
check 'an ordinary run does not wait out a bound' test $((SECONDS - ORDINARY_START)) -lt 5

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

# ── run metadata (#69) ───────────────────────────────────────────────────────
# Everything the dashboard renders comes from these files; the log body is
# never parsed, so its framing can be quoted by the text under review.
fixture 'SHIP — metadata run'
run_review 0 DEV_TRIO_REVIEWER_MODEL=claude
RUN="${LOG%.log}.run.json"
check 'wrapper publishes run metadata' test -f "$RUN"
check 'metadata names channel, role and resolved model' json_is "$RUN" \
  '.channel=="codex" and .role=="reviewer" and .model=="claude" and .team=="review-test"'
check 'metadata binds its own artifacts' json_is "$RUN" \
  ".log_path==\"$LOG\" and .result_path==\"$RESULT\" and .final_path==\"$FINAL\""
check 'metadata records completion once the run ends' json_is "$RUN" \
  '.completion.exit_code==0 and .completion.verdict=="SHIP" and .completion.reason=="ok"'
check 'standalone run is not marked nested' json_is "$RUN" '.nested==false'
check 'metadata carries the focus it was given' json_is "$RUN" \
  '(.inputs|map(select(.kind=="focus"))|length)==1'

# A nested dispatch emits no manifest by contract, but the dashboard still has
# to be able to describe it — so it does emit run metadata.
manifest_init fixture-parent-run "$TMP/parent-run.log"
PARENT_RUN_TMP="$MANIFEST_TMP"
fixture 'SHIP — nested metadata'
run_review 0 MANIFEST_PARENT_TMP="$PARENT_RUN_TMP"
check 'nested dispatch still publishes run metadata' json_is "${LOG%.log}.run.json" '.nested==true'
check 'nested dispatch emits no child manifest' test ! -e "$MANIFEST"
manifest_finalize

# The sidecar's own failure modes. It is a UI artifact: a failed write reports
# itself and returns nonzero, and the wrappers keep going (they branch on that
# rc rather than letting errexit take the review down with it).
# shellcheck source=../dev-trio/lib/runstate.sh
. "$ROOT/dev-trio/lib/runstate.sh"
check 'begin into a missing directory fails' \
  no_runstate_begin "$TMP/nonexistent-dir/codex-1.log"
check 'failed begin leaves no metadata' test ! -e "$TMP/nonexistent-dir/codex-1.run.json"
: > "$TMP/log/review-test/orphan-20000101-000000-1.log"
check 'completing a run with no metadata fails' \
  no_runstate_complete "$TMP/log/review-test/orphan-20000101-000000-1.log"
check 'failed completion invents no metadata' \
  test ! -e "$TMP/log/review-test/orphan-20000101-000000-1.run.json"
# Malformed metadata yields nothing at all — never a half-populated frame.
for bad in '{"schema_version": 1, "chan' '' '[]' '{"schema_version":2}'; do
  printf '%s' "$bad" > "$TMP/bad.run.json"
  check 'malformed metadata is unavailable' no_runstate_read "$TMP/bad.run.json"
  check 'malformed metadata yields no output' test -z "$(runstate_read "$TMP/bad.run.json" || true)"
done

# ── researcher answer capture + dashboard (#69) ──────────────────────────────
cat > "$TMP/researcher" <<'STUB'
#!/usr/bin/env bash
if [ -n "${RESEARCH_STDERR:-}" ]; then printf '%s\n' "$RESEARCH_STDERR" >&2; fi
[ -z "${RESEARCH_ANSWER_FILE:-}" ] || cat "$RESEARCH_ANSWER_FILE"
exit "${RESEARCH_RC:-0}"
STUB
chmod +x "$TMP/researcher"
# Sets AGY_RC / AGY_LOG / AGY_FINAL / AGY_RUN for the invocation it just ran.
research() {
  AGY_RC=0
  env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
    AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
    AGY_CLI="$TMP/researcher" "$@" \
    "$ROOT/dev-trio/bin/ask-researcher.sh" 'fixture question' \
    < /dev/null > "$TMP/research.out" 2> "$TMP/research.err" || AGY_RC=$?
  AGY_LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-agy.log")"
  AGY_FINAL="${AGY_LOG%.log}.final.md"
  AGY_RUN="${AGY_LOG%.log}.run.json"
}
# Two distinct URLs, one of them repeated, two of them on a single line: a
# line count gets this wrong in both directions.
cat > "$TMP/answer.md" <<'ANSWER'
The short answer is that the loader resolves the role before the binary.

See https://example.com/a and https://example.com/b for the contract.
Repeated on purpose: https://example.com/a
ANSWER
PROMPT_START=$SECONDS
research RESEARCH_ANSWER_FILE="$TMP/answer.md" RESEARCH_STDERR='Ripgrep not found; falling back'
check 'an ordinary run adds no waiting of its own' test $((SECONDS - PROMPT_START)) -lt 3
check 'researcher succeeds' test "$AGY_RC" -eq 0
check 'answer artifact holds the answer' grep -q 'loader resolves the role' "$AGY_FINAL"
check 'answer artifact excludes CLI diagnostics' no_match 'Ripgrep not found' "$AGY_FINAL"
check 'log still carries the diagnostics' grep -q 'Ripgrep not found' "$AGY_LOG"
check 'callers receive the answer on stdout' grep -q 'loader resolves the role' "$TMP/research.out"
check 'callers do not receive diagnostics as an answer' no_match 'Ripgrep not found' "$TMP/research.out"
check 'research metadata describes the channel' json_is "$AGY_RUN" \
  '.channel=="agy" and .role=="researcher" and .completion.exit_code==0'
check 'research metadata has no review result' json_is "$AGY_RUN" '.result_path==null'
research_dashboard
check 'research dashboard shows the lead' grep -q 'loader resolves the role' "$TMP/dashboard.out"
check 'research dashboard counts distinct citations' grep -q '2 unique' "$TMP/dashboard.out"
check 'research dashboard reports completion' grep -q 'done' "$TMP/dashboard.out"

# stderr-only: the CLI exits 0 having said nothing on stdout. That is not an
# answer, and the empty artifact must not read as one.
research RESEARCH_STDERR='permission denied for the web tool'
check 'stderr-only research fails with the empty-answer code' test "$AGY_RC" -eq 5
check 'stderr-only research leaves an empty answer artifact' test ! -s "$AGY_FINAL"
check 'stderr-only research records its failure' json_is "$AGY_RUN" '.completion.exit_code==5'
research_dashboard
check 'dashboard says no answer was captured' grep -q 'No answer captured' "$TMP/dashboard.out"
check 'dashboard does not report zero sources' no_match '0 unique' "$TMP/dashboard.out"

# An aborted run publishes a completion from its EXIT trap, so it cannot read
# as live forever.
cat > "$TMP/slow-researcher" <<'STUB'
#!/usr/bin/env bash
: > "$RESEARCH_STARTED"
sleep 30
STUB
chmod +x "$TMP/slow-researcher"
env -u DEV_TRIO_RESEARCHER_MODEL AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
  AGY_CLI="$TMP/slow-researcher" RESEARCH_STARTED="$TMP/started" \
  "$ROOT/dev-trio/bin/ask-researcher.sh" 'aborted question' \
  < /dev/null > /dev/null 2>&1 &
slow_pid=$!
waited=0
while [ ! -f "$TMP/started" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
check 'slow researcher started' test -f "$TMP/started"
kill -TERM "$slow_pid" 2>/dev/null || true
wait "$slow_pid" 2>/dev/null || true
ABORTED_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-agy.log")"
ABORTED_RUN="${ABORTED_RUN%.log}.run.json"
check 'aborted run publishes a completion' json_is "$ABORTED_RUN" '.completion != null'
check 'aborted run is recorded as aborted' json_is "$ABORTED_RUN" '.completion.reason=="aborted"'
check 'aborted run records the signal exit code' json_is "$ABORTED_RUN" '.completion.exit_code==143'
research_dashboard
check 'aborted run is not reported as still running' no_match 'no completion recorded' "$TMP/dashboard.out"

# Native answer capture. The artifact is authoritative: a CLI that claims a
# native final and writes none has produced no answer, however it exited, and a
# CLI that writes one while saying nothing on stdout has.
cat > "$TMP/models.json" <<'MODELS'
{"version":1,
 "models":{"native-researcher":{"command":"true",
   "env_command":"NATIVE_RESEARCHER_CLI",
   "args":["{prompt}"],
   "final_args":["--final","{final}","{prompt}"]}},
 "roles":{}}
MODELS
cat > "$TMP/native-researcher" <<'STUB'
#!/usr/bin/env bash
final=""; prev=""
for a in "$@"; do [ "$prev" = "--final" ] && final="$a"; prev="$a"; done
[ -z "${NATIVE_SKIP_FINAL:-}" ] && printf 'the native answer
' > "$final"
[ -z "${NATIVE_QUIET:-}" ] && printf 'streamed transcript
'
exit 0
STUB
chmod +x "$TMP/native-researcher"
native_research() {
  NATIVE_RC=0
  env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
    AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
    AGENT_TEAM_MODELS_CONFIG="$TMP/models.json" \
    DEV_TRIO_RESEARCHER_MODEL=native-researcher \
    NATIVE_RESEARCHER_CLI="$TMP/native-researcher" "$@" \
    "$ROOT/dev-trio/bin/ask-researcher.sh" 'native question' \
    < /dev/null > "$TMP/native.out" 2> "$TMP/native.err" || NATIVE_RC=$?
  NATIVE_LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-agy.log")"
  NATIVE_RUN="${NATIVE_LOG%.log}.run.json"
}
native_research
check 'native capture succeeds' test "$NATIVE_RC" -eq 0
check 'native capture is recorded as native' json_is "$NATIVE_RUN" '.final_source=="native" and .completion.exit_code==0'
check 'native answer artifact holds the answer' grep -q 'the native answer' "${NATIVE_LOG%.log}.final.md"
# ralph-trio and spec-trio inject the wrapper's STDOUT, so the answer — not the
# CLI's streamed transcript — has to be what comes out of it.
check 'callers receive the answer on stdout' grep -q 'the native answer' "$TMP/native.out"
check 'callers do not receive the transcript as an answer' no_match 'streamed transcript' "$TMP/native.out"
check 'the transcript is still in the log' grep -q 'streamed transcript' "$NATIVE_LOG"
# A CLI that says nothing on stdout but writes a valid answer has answered.
# The artifact decides, and only registry_run_answer can say so — it alone
# still holds the CLI's own exit status.
native_research NATIVE_QUIET=1
check 'a silent CLI with a native answer succeeds' test "$NATIVE_RC" -eq 0
check 'its answer still reaches the caller' grep -q 'the native answer' "$TMP/native.out"
check 'its run is recorded as successful' json_is "$NATIVE_RUN" '.completion.exit_code==0'
native_research NATIVE_SKIP_FINAL=1
check 'a missing native answer is an empty answer' test "$NATIVE_RC" -eq 5
check 'a missing native answer is recorded as such' \
  json_is "$NATIVE_RUN" '.completion.exit_code==5'
# A failed invocation stays failed: this wrapper cannot tell a CLI that chose to
# exit 5 from the registry's own empty-stdout 5, so a file on disk must not
# promote either one to success.
cat > "$TMP/native-fail" <<'STUB'
#!/usr/bin/env bash
final=""; prev=""
for a in "$@"; do [ "$prev" = "--final" ] && final="$a"; prev="$a"; done
printf 'an answer that should not rescue the exit code\n' > "$final"
exit 5
STUB
chmod +x "$TMP/native-fail"
NATIVE_RC=0
env -u DEV_TRIO_RESEARCHER_MODEL AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
  AGENT_TEAM_MODELS_CONFIG="$TMP/models.json" DEV_TRIO_RESEARCHER_MODEL=native-researcher \
  NATIVE_RESEARCHER_CLI="$TMP/native-fail" \
  "$ROOT/dev-trio/bin/ask-researcher.sh" 'failing question' \
  < /dev/null > "$TMP/native-fail.out" 2>&1 || NATIVE_RC=$?
check 'a failed invocation with an answer file still fails' test "$NATIVE_RC" -eq 5
FAIL_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-agy.log")"
check 'the failure is recorded, not the file' json_is "${FAIL_RUN%.log}.run.json" '.completion.exit_code==5'

# #71: a pipeline ends when every process holding its write end closes it, not
# when the CLI exits. This wrapper discards the streamed copy, so its transcript
# is a plain append and a leaked descendant has no pipe of this wrapper's to
# hold. A descendant holding *stdout* still blocks inside registry_run_answer's
# own tee (lib/registry.sh), which is not this wrapper's to drain. Every caller
# of that function traverses the pipe, native capture included, and it is the
# last instance of #71 now that ask-reviewer.sh logs on a descriptor too.
cat > "$TMP/leaky-researcher" <<'STUB'
#!/usr/bin/env bash
{ sleep 10; } > /dev/null &
printf 'the answer arrived promptly\n'
exit 0
STUB
chmod +x "$TMP/leaky-researcher"
LEAK_START=$SECONDS
leak_rc=0
env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
  AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
  AGENT_TEAM_MODELS_CONFIG="$TMP/models.json" DEV_TRIO_RESEARCHER_MODEL=agy \
  AGY_CLI="$TMP/leaky-researcher" \
  "$ROOT/dev-trio/bin/ask-researcher.sh" 'leaky question' \
  < /dev/null > "$TMP/leak.out" 2> "$TMP/leak.err" || leak_rc=$?
LEAK_ELAPSED=$((SECONDS - LEAK_START))
check 'an inherited stderr does not hold the wrapper open' test "$LEAK_ELAPSED" -lt 5
check 'the leaky run still succeeds' test "$leak_rc" -eq 0
check 'the leaky run still answers' grep -q 'arrived promptly' "$TMP/leak.out"
LEAK_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-agy.log")"
check 'the leaky run records a completion' json_is "${LEAK_RUN%.log}.run.json" '.completion != null'
check 'the transcript reached the log' grep -q 'arrived promptly' "$LEAK_RUN"

# The reader takes a file, not the first document in one.
VALID_RUN=$(cat "$AGY_RUN")
printf '%s\n{}\n' "$VALID_RUN" > "$TMP/two-docs.run.json"
check 'a second appended document is not readable as the first' \
  no_runstate_read "$TMP/two-docs.run.json"
printf '%s' "$VALID_RUN" | jq -c '.inputs=[7]' > "$TMP/bad-inputs.run.json"
check 'inputs that are not records are rejected' no_runstate_read "$TMP/bad-inputs.run.json"
printf '%s' "$VALID_RUN" | jq -c 'del(.completion)' > "$TMP/no-completion.run.json"
check 'metadata with no completion field is rejected' no_runstate_read "$TMP/no-completion.run.json"

printf 'review-result smoke: %s assertions passed\n' "$PASS"
