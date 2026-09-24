#!/usr/bin/env bash
# Model-free regressions for dev-trio #19 and #21, including real wrapper and
# dashboard consumers. No tmux, login, model CLI, or user's registry is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../dev-trio/lib/review-result.sh
. "$ROOT/dev-trio/lib/review-result.sh"
TMP=$(mktemp -d)
# agy's home is pinned to a directory that does not exist, so agy roles get
# --add-dir but never --log-file, whatever this machine has installed (#103).
export DEV_TRIO_AGY_HOME=/nonexistent/dev-trio-test-agy-home
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
no_match_tree() { ! grep -rq "$1" "$2"; }
no_runstate_begin() { ! runstate_begin "$1" channel=codex wrapper=ask-reviewer.sh 2>/dev/null; }
no_runstate_complete() { ! runstate_complete "$1" exit_code=0 2>/dev/null; }
no_runstate_read() { ! runstate_read "$1" >/dev/null 2>&1; }
fixture() {
  printf '## Verdict\n%s\n\n## Findings\n\n### Blocker\n- 없음.\n\n### Major\n- None.\n\n### Minor / Nit\n- 없음\n' "$1" > "$TMP/review.md"
}
parse() { review_result_parse "$TMP/review.md" "${1:-0}" "${2:-default}" > "$TMP/parsed.json"; }
contradictory_fixture() {
  local severity="$1" marker="$2" order="$3" repeated="${4:-no}" first second
  printf '## Verdict\nSHIP — inspect the findings\n## Findings\n### %s\n' "$severity" > "$TMP/review.md"
  first="$marker"; second='A real finding.'
  if [ "$order" = finding-first ]; then first='A real finding.'; second="$marker"; fi
  printf -- '- %s\n' "$first" >> "$TMP/review.md"
  [ "$repeated" != yes ] || printf '## What I checked\n- inspected\n## Findings\n### %s\n' "$severity" >> "$TMP/review.md"
  printf -- '- %s\n' "$second" >> "$TMP/review.md"
}
for token in SHIP NEEDS-FIX DISCUSS; do
  for separator in ' — ' '. '; do
    fixture "$token${separator}reason"
    parse
    check "$token punctuation parsed" json_is "$TMP/parsed.json" ".verdict == \"$token\" and .exit_code == 0 and .status == \"ok\""
    check 'empty placeholders count zero' json_is "$TMP/parsed.json" '.findings == {blocker:[],major:[],minor:[]}'
    check 'result reader agrees' review_result_read "$TMP/parsed.json" >/dev/null
  done
done
cat > "$TMP/review.md" <<'REVIEW'
## Verdict
NEEDS-FIX — findings
## Findings
### Blocker
- None of the writes are atomic.
- 없음. 이 문장은 실제 finding입니다.
- x
- `a.py:2` — preserve "quotes" and backslashes \.
### Major
- none found
### Minor / Nit
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
# Empty markers and real findings contradict each other, regardless of order
# or repeated headings. These are lexical checks, not verdict-based filtering.
for severity in Blocker Major 'Minor / Nit'; do
  case "$severity" in Blocker) key=blocker ;; Major) key=major ;; *) key=minor ;; esac
  for marker in 'None.' none NONE nOnE. 없음 없음. 'None. ' $'nOnE.\t' '없음 ' $'없음.\t'; do
    for order in empty-first finding-first; do
      contradictory_fixture "$severity" "$marker" "$order"
      parse
      check "$severity $marker $order fails closed" json_is "$TMP/parsed.json" \
        ".status==\"parse-failed\" and .exit_code==3 and .verdict==null and .verdict_line==null and .findings=={blocker:null,major:null,minor:null} and (.error|contains(\"$key\"))"
    done
  done
  for order in empty-first finding-first; do
    contradictory_fixture "$severity" 'None.' "$order" yes
    parse
    check "$severity $order across repeated headings fails closed" json_is "$TMP/parsed.json" \
      ".status==\"parse-failed\" and .exit_code==3 and .findings=={blocker:null,major:null,minor:null} and (.error|contains(\"$key\"))"
  done
done
for indent in ' ' '  ' '   '; do
  for content in '- A real finding.' '- None.'; do
    printf '## Verdict\nSHIP — indentation must not hide findings\n## Findings\n### Major\n%s%s\n' "$indent" "$content" > "$TMP/review.md"
    parse
    check 'noncanonical indentation fails instead of reporting zero findings' json_is "$TMP/parsed.json" '.status=="parse-failed" and .exit_code==3 and .verdict==null and .findings=={blocker:null,major:null,minor:null} and (.error|contains("major"))'
  done
  printf '## Verdict\nSHIP — resolved explanation\n## Findings\n### Major\n- None.\n\n%sThe prior concern is resolved:\n%s- Normal completion is preserved.\n' "$indent" "$indent" > "$TMP/review.md"
  parse
  check 'indented resolved explanation is rejected' json_is "$TMP/parsed.json" '.status=="parse-failed" and (.error|contains("column 0"))'
done
printf '## Verdict\nSHIP — nested bullets are ambiguous\n## Findings\n### Major\n- A real finding.\n  - Supporting detail.\n' > "$TMP/review.md"
parse
check 'nested bullets fail instead of inflating finding counts' json_is "$TMP/parsed.json" '.status=="parse-failed" and .findings.major==null'
# #125: the role's own template is the documented form, so it must parse, with
# one finding per example line — including the one with several reproductions.
for role in dev-trio spec-trio; do
  awk '/^## Output format/ { on = 1; next }
       on && /^```/ { if (block) exit; block = 1; next }
       block' "$ROOT/$role/lib/roles/reviewer.md" \
    | sed 's/^<one of: [^>]*> — <[^>]*>$/NEEDS-FIX — template example/' > "$TMP/review.md"
  parse
  check "$role output template parses with one finding per example line" json_is "$TMP/parsed.json" \
    '.status=="ok" and .verdict=="NEEDS-FIX" and (.findings|map_values(length))=={blocker:1,major:2,minor:1}'
done
# #125: the shape two completed Claude reviews produced — reproductions and the
# suggested fix as sub-bullets, continuation prose between them.
review_125() {
  printf '## Verdict\nNEEDS-FIX — two hints lose true statements\n\n## Findings\n\n### Blocker\n- None.\n\n### Major\n%s\n\n### Minor / Nit\n- `tests/test_hints.py:334` — one exercise is special-cased.\n\n## What I checked\n%s\n' "$1" "$2" > "$TMP/review.md"
}
major_125_is() { jq -e --arg major "$MAJOR_125" "$1" "$TMP/parsed.json" >/dev/null; }
MAJOR_125='- `scripts/hints.py:977` (same pattern: `scripts/hints.py:716`) — the new hints drop true statements.'
review_125 "$MAJOR_125"'
  - `ex02b` with `{"Shareholding"}`: the hint no longer names the missing class.
  - `ex06` with `{"payer"}`: the hint only repeats the default.

  Several removed sentences were true whenever they fired.
  - Suggestion: keep the true sentences and rewrite only the ones that guess a cause.' '- The diff and the fired hints.'
parse
check 'sub-bullet reproductions fail with unknown counts' json_is "$TMP/parsed.json" \
  '.status=="parse-failed" and .exit_code==3 and .verdict==null and .findings=={blocker:null,major:null,minor:null} and (.error|contains("noncanonical major"))'
MAJOR_125='- `scripts/hints.py:977` (same pattern: `scripts/hints.py:716`) — the new hints drop true statements: (1) `ex02b` with `{"Shareholding"}` → the hint no longer names the missing class; (2) `ex06` with `{"payer"}` → the hint only repeats the default → keep the true sentences and rewrite only the ones that guess a cause.'
review_125 "$MAJOR_125" '- Several removed sentences were true whenever they fired:
  - `ex02b` named the missing class.
  - `ex06` named both parties.'
parse
check 'inline reproductions parse as one finding with both cases' major_125_is \
  '.status=="ok" and .findings.major==[$major] and (.findings.minor|length)==1 and .findings.blocker==[]'
review_125 "$MAJOR_125"'

  Several removed sentences were true whenever they fired.' '- The diff and the fired hints.'
parse
check 'continuation prose neither counts nor joins the finding' major_125_is '.status=="ok" and .findings.major==[$major]'
for bullet in '* A real finding.' '+ A real finding.' '1. A real finding.' '12) A real finding.' $'-\tA real finding.' '* None.'; do
  for indent in '' '  '; do
    printf '## Verdict\nSHIP — unsupported list markers must not hide findings\n## Findings\n### Major\n- None.\n%s%s\n' "$indent" "$bullet" > "$TMP/review.md"
    parse
    check 'alternate list markers fail instead of bypassing the guard' json_is "$TMP/parsed.json" '.status=="parse-failed" and .exit_code==3 and .verdict==null and .findings.major==null and (.error|contains("noncanonical major"))'
  done
done
printf '## Verdict\nSHIP — a genuine alternate-marker finding\n## Findings\n### Major\n* A real finding.\n' > "$TMP/review.md"
parse
check 'an alternate-marker finding without an empty marker is still rejected' json_is "$TMP/parsed.json" '.status=="parse-failed" and .findings.major==null'
for surrounding in empty-marker finding; do
  fixture 'SHIP — blank bullets have no content'
  if [ "$surrounding" = finding ]; then
    printf '## Verdict\nSHIP — a real finding\n## Findings\n### Major\n- A real finding.\n' > "$TMP/review.md"
  fi
  printf -- '- \n- \t\n  - \t\n* \n+\t\n1. \n2)\t\n' >> "$TMP/review.md"
  parse
  check 'blank bullets do not create contradictions or counts' json_is "$TMP/parsed.json" ".status==\"ok\" and (.findings.major|length)==$([ "$surrounding" = finding ] && printf 1 || printf 0)"
done
printf '## Verdict\nSHIP — explicit contradictory fixture\n## Findings\n### Major\n- None.\n- A real finding.\n' > "$TMP/review.md"
parse 0 spec
check 'spec profile also rejects contradictory findings' json_is "$TMP/parsed.json" '.status=="parse-failed" and .profile=="spec"'
printf '## Verdict\nSHIP — explicit failed invocation fixture\n## Findings\n### Major\n- A real finding.\n- None.\n' > "$TMP/review.md"
parse 7
check 'invocation failure precedes contradictory findings' json_is "$TMP/parsed.json" '.status=="invocation-failed" and .exit_code==7'
for marker in 'None.' none NONE nOnE. 없음 없음.; do
  for whitespace in '' ' ' $'\t' $' \t'; do
    printf '## Verdict\r\nSHIP — empty markers with trailing whitespace\r\n## Findings\r\n### Major\r\n- None.\r\n- %s%s\r\n' "$marker" "$whitespace" > "$TMP/review.md"
    cp "$TMP/review.md" "$TMP/marker-original.md"
    parse
    check 'trailing whitespace does not turn empty markers into findings' json_is "$TMP/parsed.json" '.status=="ok" and .findings=={blocker:null,major:[],minor:null}'
    check 'whitespace and CRLF in the source remain byte-identical' cmp -s "$TMP/marker-original.md" "$TMP/review.md"
  done
done
printf '## Verdict\nSHIP — real findings retain their whitespace\n## Findings\n### Major\n- None. extra  \n- 없음. 실제 finding\t\n' > "$TMP/review.md"
parse
check 'near-match findings retain trailing spaces and tabs' json_is "$TMP/parsed.json" '.status=="ok" and .findings.major==["- None. extra  ","- 없음. 실제 finding\t"]'
cat > "$TMP/review.md" <<'REVIEW'
## Verdict
SHIP — inspect without inferring counts from the verdict
## Findings
### Blocker
- None.
- NONE
- 없음
### Major
- A real finding.
### Major
- Another real finding.
### Minor / Nit
REVIEW
parse
check 'repeated compatible sections and SHIP findings remain supported' json_is "$TMP/parsed.json" '.status=="ok" and .findings=={blocker:[],major:["- A real finding.","- Another real finding."],minor:[]}'
fixture 'SHIP — examples are not findings'
cat >> "$TMP/review.md" <<'REVIEW'
> - A quoted example.
    - An indented example.
	- A tab-indented code example.
```markdown
- A fenced example.
```
## What I checked
- Normal completion is preserved.
- Group identity remains owned.
REVIEW
parse
check 'examples and checked explanations do not contradict empty markers' json_is "$TMP/parsed.json" '.status=="ok" and .findings=={blocker:[],major:[],minor:[]}'
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
# Host-specific authentication is covered by test_dev_trio_hosts.py; an ambient
# Codex PM must not ask these response-only stubs to authenticate as Claude.
INVOKE_ENV=(
  -u DEV_TRIO_PM_HOST
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
# #83: a resolved explanation after None must not become Major findings.
# Both model adapters use the fixed reviewer channel named codex; this loop
# exercises native-final versus stdout capture, not different log channels.
cat > "$TMP/resolved-review.md" <<'REVIEW'
## Verdict
SHIP — the earlier concern is resolved.
## Findings
### Blocker
- None.
### Major
- None.

The prior concern is resolved:
- Normal completion is preserved.
- Group identity remains owned.

### Minor / Nit
- Optional documentation cleanup.
REVIEW
for model in codex claude; do
  cp "$TMP/resolved-review.md" "$TMP/review.md"
  receipt=$(review_receipt_create "$TMP/receipt")
  run_review 3 DEV_TRIO_REVIEWER_MODEL="$model" DEV_TRIO_REVIEW_RECEIPT="$receipt"
  check "$model contradiction preserves the final Markdown" cmp -s "$TMP/review.md" "$FINAL"
  check "$model contradiction leaves verdict and findings unknown" json_is "$RESULT" '.status=="parse-failed" and .invocation_rc==0 and .verdict==null and .findings=={blocker:null,major:null,minor:null} and (.error|contains("major"))'
  check "$model contradiction leaves manifest verdict null" json_is "$MANIFEST" '.verdict==null and .ended_at!=null'
  check "$model manifest links the exact failed result" json_is "$MANIFEST" ".inputs | any(.kind==\"review-result\" and .path==\"$RESULT\" and (.sha256|length)==64)"
  review_result_from_receipt "$receipt" 3 > "$TMP/receipt-result.json"
  check "$model receipt agrees with failed result" json_is "$TMP/receipt-result.json" ".status==\"parse-failed\" and .result_path==\"$RESULT\" and .final_path==\"$FINAL\""
  dashboard
  check "$model dashboard exposes contradictory findings" grep -q 'Review failed:.*major' "$TMP/dashboard.out"
  check "$model dashboard does not display a verdict" no_match 'Verdict:' "$TMP/dashboard.out"
  check "$model dashboard does not display finding counts" no_match 'Findings:' "$TMP/dashboard.out"
  sed '/^- Normal completion/s/^/  /; /^- Group identity/s/^/  /' "$TMP/resolved-review.md" > "$TMP/review.md"
  run_review 3 DEV_TRIO_REVIEWER_MODEL="$model"
  check "$model indented explanation reports the format error" json_is "$RESULT" '.status=="parse-failed" and .findings.major==null and (.error|contains("column 0"))'
  check "$model indented explanation preserves the final" cmp -s "$TMP/review.md" "$FINAL"
  check "$model indented explanation leaves manifest verdict null" json_is "$MANIFEST" '.verdict==null'
  dashboard
  check "$model dashboard reports indentation failure" grep -q 'Review failed:.*major' "$TMP/dashboard.out"
  check "$model dashboard does not report zero findings for indented bullets" no_match 'Findings:' "$TMP/dashboard.out"
  fixture 'SHIP — the earlier concern is resolved'
  printf '## What I checked\n- Normal completion is preserved.\n- Group identity remains owned.\n' >> "$TMP/review.md"
  run_review 0 DEV_TRIO_REVIEWER_MODEL="$model"
  check "$model corrected placement has empty findings" json_is "$RESULT" '.status=="ok" and .verdict=="SHIP" and .findings=={blocker:[],major:[],minor:[]}'
  dashboard
  check "$model corrected placement displays zero majors" grep -q '0 major' "$TMP/dashboard.out"
done
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

# #75: fail only the final END write, after capture and result publication.
# Closing printf's output forces a real write error without destroying the
# readable transcript. BASH_ENV scopes the fault to the invoked wrapper tree.
cat > "$TMP/fail-end-write.sh" <<'SHIM'
printf() {
  case "${1:-}" in
    '\n=== END (rc=%d) ===\n')
      : > "$END_FAILURE_FIRED"
      builtin printf "$@" >&-
      return $?
      ;;
  esac
  builtin printf "$@"
}
SHIM
END_FAILURE_ENV=(BASH_ENV="$TMP/fail-end-write.sh" END_FAILURE_FIRED="$TMP/end-write-fired")
for model in codex claude; do
  for outcome in success parse-failed invocation-failed; do
    fixture 'SHIP — final log failure'
    invocation_rc=0
    expected_rc=0
    expected_verdict='"SHIP"'
    expected_status=ok
    case "$outcome" in
      parse-failed)
        fixture 'MAYBE — invalid verdict'
        expected_rc=3; expected_verdict=null; expected_status=parse-failed ;;
      invocation-failed)
        invocation_rc=9; expected_rc=9; expected_verdict=null; expected_status=invocation-failed ;;
    esac
    RECEIPT=$(review_receipt_create "$TMP/caller.log")
    rm -f "$TMP/end-write-fired"
    run_review "$expected_rc" "${END_FAILURE_ENV[@]}" DEV_TRIO_REVIEWER_MODEL="$model" \
      TEST_REVIEW_RC="$invocation_rc" DEV_TRIO_REVIEW_RECEIPT="$RECEIPT"
    check 'final log write fault was exercised' test -f "$TMP/end-write-fired"
    check 'failed final write leaves END absent' no_match '^=== END (rc=' "$LOG"
    check 'final log failure is reported' grep -q 'final log append failed' "$TMP/wrapper.err"
    check 'final log failure preserves the result' json_is "$RESULT" \
      ".verdict==$expected_verdict and .status==\"$expected_status\""
    check 'final log failure preserves the manifest' json_is "$MANIFEST" \
      ".verdict==$expected_verdict and .ended_at!=null"
    check 'caller receipt agrees with wrapper status' review_result_from_receipt "$RECEIPT" "$expected_rc" >/dev/null
    check 'final log failure still publishes real completion' json_is "${LOG%.log}.run.json" \
      ".completion.exit_code==$expected_rc and .completion.verdict==$expected_verdict and .completion.reason==\"ok\""
    dashboard
    check 'missing END does not leave the dashboard running' no_match 'no completion recorded' "$TMP/dashboard.out"
    check 'missing END does not report an abort' no_match 'aborted' "$TMP/dashboard.out"
    if [ "$expected_rc" -eq 0 ]; then
      check 'missing END still displays the verdict' grep -q 'SHIP — final log failure' "$TMP/dashboard.out"
      check 'missing END still displays completion' grep -q 'done' "$TMP/dashboard.out"
    else
      check 'missing END still displays the real failure' grep -Fq "failed (rc=$expected_rc)" "$TMP/dashboard.out"
    fi
  done
done

# Required artifact publication must still fail even if END cannot be written.
fixture 'SHIP — receipt failure with a broken log'
for invocation_rc in 0 7; do
  expected_rc=2
  [ "$invocation_rc" -eq 0 ] || expected_rc="$invocation_rc"
  actual_rc=0
  rm -f "$TMP/end-write-fired"
  invoke "${END_FAILURE_ENV[@]}" DEV_TRIO_REVIEW_RECEIPT="$TMP/missing/receipt" \
    TEST_REVIEW_RC="$invocation_rc" > "$TMP/io.out" 2> "$TMP/io.err" || actual_rc=$?
  failed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-codex.log")"
  check 'artifact failure also exercises the END fault' test -f "$TMP/end-write-fired"
  check 'logging cannot mask an artifact failure' test "$actual_rc" -eq "$expected_rc"
  check 'failed publication leaves no successful result' test ! -f "${failed_log%.log}.review.json"
  check 'artifact failure warns about the incomplete log' grep -q 'final log append failed' "$TMP/io.err"
  check 'artifact failure retains its completion reason' json_is "${failed_log%.log}.run.json" \
    ".completion.exit_code==$expected_rc and .completion.verdict==null and .completion.reason==\"result-write-failed\""
done

# An actual failed open is distinct from printf failing on an open descriptor.
# Swap the log for a directory after the final has been captured and the result
# renamed, so both capture paths reach the same failing END redirection. This
# also works when tests run as root, unlike making the file read-only.
mkdir "$TMP/end-open-shim"
cat > "$TMP/end-open-shim/mv" <<'SHIM'
#!/bin/sh
/bin/mv "$@" || exit $?
for target do :; done
case "$target" in
  *.review.json)
    log="${target%.review.json}.log"
    /bin/mv "$log" "$log.saved" || exit $?
    mkdir "$log"
    ;;
esac
SHIM
chmod +x "$TMP/end-open-shim/mv"
fixture 'SHIP — log cannot reopen'
for model in codex claude; do
  run_review 0 PATH="$TMP/end-open-shim:$PATH" DEV_TRIO_REVIEWER_MODEL="$model"
  check 'END open fault was exercised' test -d "$LOG"
  check 'failed END open is reported' grep -q 'final log append failed' "$TMP/wrapper.err"
  check 'failed END open retains completion' json_is "${LOG%.log}.run.json" \
    '.completion.exit_code==0 and .completion.verdict=="SHIP" and .completion.reason=="ok"'
  rmdir "$LOG"
  mv "$LOG.saved" "$LOG"
  check 'restored transcript has no END marker' no_match '^=== END (rc=' "$LOG"
  dashboard
  check 'dashboard retains the verdict after an open failure' grep -q 'SHIP — log cannot reopen' "$TMP/dashboard.out"
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

# An interrupted run owes the caller no review and no transcript on stdout — it
# names its artifacts. The signal has to land while the CLI is running, which is
# where the wrapper's own redirections are in effect: a handler firing there
# writes into the log instead of stderr (measured), so the wrapper records the
# signal and reports once the call has returned.
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

# Researcher completion follows the same best-effort END contract. Its stdout
# remains the answer alone, including when logging a warning on stderr.
for outcome in success empty-answer invocation-failed; do
  answer_file="$TMP/answer.md"
  invocation_rc=0
  expected_rc=0
  case "$outcome" in
    empty-answer) answer_file=""; expected_rc=5 ;;
    invocation-failed) invocation_rc=9; expected_rc=9 ;;
  esac
  rm -f "$TMP/end-write-fired"
  research "${END_FAILURE_ENV[@]}" RESEARCH_ANSWER_FILE="$answer_file" RESEARCH_RC="$invocation_rc"
  check 'research END write fault was exercised' test -f "$TMP/end-write-fired"
  check 'research END failure preserves the exit code' test "$AGY_RC" -eq "$expected_rc"
  check 'research END failure leaves the marker absent' no_match '^=== END (rc=' "$AGY_LOG"
  check 'research END failure is reported' grep -q 'final log append failed' "$TMP/research.err"
  check 'research END warning stays off stdout' no_match 'final log append failed' "$TMP/research.out"
  expected_reason=ok
  [ "$expected_rc" -eq 0 ] || expected_reason=failed
  check 'research END failure preserves completion' json_is "$AGY_RUN" \
    ".completion.exit_code==$expected_rc and .completion.reason==\"$expected_reason\""
  research_dashboard
  check 'research without END does not remain running' no_match 'no completion recorded' "$TMP/dashboard.out"
  if [ "$expected_rc" -eq 0 ]; then
    check 'research END failure preserves the answer artifact' cmp -s "$TMP/answer.md" "$AGY_FINAL"
    check 'research END failure preserves answer output' grep -q 'loader resolves the role' "$TMP/research.out"
    check 'research END failure still displays completion' grep -q 'done' "$TMP/dashboard.out"
  else
    check 'research END failure still displays the real failure' grep -Fq "failed (rc=$expected_rc)" "$TMP/dashboard.out"
    check 'failed research still emits no answer' test -z "$(tr -d '\n' < "$TMP/research.out")"
  fi
done

# An aborted run publishes a completion from its EXIT trap, so it cannot read
# as live forever.
cat > "$TMP/slow-researcher" <<'STUB'
#!/usr/bin/env bash
: > "$RESEARCH_STARTED"
sleep 30
STUB
chmod +x "$TMP/slow-researcher"
env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
  AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
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
env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
  AGENT_TEAM=review-test TMUX='' DEV_TRIO_LOG_DIR="$TMP/log" \
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


# #103: headless agy that auto-denies a tool exits 0 with a notice on stderr.
# The review is reclassified from parse-failed to permission-denied only on
# this run's own evidence, and the denied target comes from agy's transcript,
# found through the conversation id in the --log-file the wrapper pinned.
AGY_HOME="$TMP/agy-home"
mkdir -p "$AGY_HOME/log"
AGY_ID=0179d9db-25b9-4d06-97c2-4b7f60b8eb8d
AGY_NOTICE='jetski: no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json (e.g. command(<target>)).'
cat > "$TMP/agy-reviewer" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$TEST_AGY_ARGV"
log=""
[ "${1:-}" != --log-file ] || log="$2"
# Like agy's own log: the conversation id, and the user's allow list.
if [ -n "$log" ] && [ -n "${TEST_AGY_ID:-}" ]; then
  printf 'I0923 17:51:49.1 1 server.go:1239] Created conversation %s\n' "$TEST_AGY_ID" > "$log"
  printf 'I0923 17:51:49.2 1 cli_setting_manager.go:92] permissions=&{Allow:[command(SENTINEL-RULE)]}\n' >> "$log"
fi
[ -z "${TEST_AGY_STDOUT:-}" ] || cat "$TEST_AGY_STDOUT"
[ "${TEST_AGY_NOTICE:-0}" != 1 ] || printf '%s\n' "$TEST_AGY_NOTICE_TEXT" >&2
# Enough output after the notice that an early-exiting scanner's producer
# dies of SIGPIPE.
[ "${TEST_AGY_NOISE:-0}" != 1 ] || seq 1 200000 >&2
exit 0
STUB
chmod +x "$TMP/agy-reviewer"
agy_transcript() {
  local dir="$AGY_HOME/brain/$AGY_ID/.system_generated/logs"
  rm -rf "$AGY_HOME/brain"
  mkdir -p "$dir"
  {
    printf '[1,2]\nnot json\n{"status":"ERROR","error":5}\n'
    jq -cn '{status:"ERROR",error:"permission check failed for command \"lsof -p $$ || pwd\": user denied permission to run command:\nlsof -p $$ || pwd"}'
    jq -cn '{status:"ERROR",error:"permission check failed for command \"a\\x01b\": user denied"}'
    jq -cn '{status:"ERROR",error:"permission check failed for read_url \"github.com\": user denied permission for read_url(github.com)"}'
    jq -cn '{status:"ERROR",error:("permission check failed for command " + ("echo a\nb\tc\u001bd" | tojson) + ": user denied")}'
    jq -cn '{status:"ERROR",error:"permission check failed for command \"lsof -p $$ || pwd\": again"}'
    printf '{"status":"ERR'
  } > "$dir/transcript_full.jsonl"
}
agy_review() {
  run_review "$@" DEV_TRIO_REVIEWER_MODEL=agy AGY_CLI="$TMP/agy-reviewer" \
    DEV_TRIO_AGY_HOME="$AGY_HOME" TEST_AGY_ARGV="$TMP/agy-argv" \
    TEST_AGY_NOTICE_TEXT="$AGY_NOTICE"
}
AGY_DENIED='["command(lsof -p $$ || pwd)","command(\"a\\x01b\")","read_url(github.com)","command(echo a\\nb\\tc\\u001bd)"]'

agy_transcript
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1
check 'agy argv pins its log and the workspace' test "$(sed -n '1p;3p;5p' "$TMP/agy-argv" | tr '\n' ' ')" = '--log-file --add-dir -p '
check 'agy workspace is the repository root' test "$(sed -n 4p "$TMP/agy-argv")" = "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
check 'agy log lives in agy home' test "$(sed -n 2p "$TMP/agy-argv")" = "$AGY_HOME/log/cli-dev-trio-review-${LOG##*/codex-}"
check 'denial is its own status with the targets' json_is "$RESULT" ".status==\"permission-denied\" and .exit_code==3 and .invocation_rc==0 and .verdict==null and .denied==$AGY_DENIED and .conversation_ids==[\"$AGY_ID\"]"
check 'denial keeps the parse error' json_is "$RESULT" '.error | startswith("agy denied a tool in headless mode: command(lsof") and endswith("(parse: missing Verdict heading)")'
check 'stderr names the denied command' grep -Fxq '[ask-reviewer] agy denied: command(lsof -p $$ || pwd)' "$TMP/wrapper.err"
check 'stderr names the conversation' grep -Fxq "[ask-reviewer] agy conversation: $AGY_ID" "$TMP/wrapper.err"
check 'manifest records the conversation' json_is "$MANIFEST" ".inputs | any(.kind==\"agy-conversation\" and .value==\"$AGY_ID\")"
check "agy's allow list is not copied into the wrapper's logs" no_match_tree SENTINEL-RULE "$TMP/log"
check "agy's allow list is not echoed" no_match SENTINEL-RULE "$TMP/wrapper.err"
check "agy's allow list is not on stdout" no_match SENTINEL-RULE "$TMP/wrapper.out"
receipt=$(review_receipt_create "$TMP/receipt")
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1 DEV_TRIO_REVIEW_RECEIPT="$receipt"
review_result_from_receipt "$receipt" 3 > "$TMP/receipt-result.json"
check 'receipt carries the denial' json_is "$TMP/receipt-result.json" ".status==\"permission-denied\" and .denied==$AGY_DENIED"
dashboard
check 'dashboard reports the denial as a failure' grep -q 'Review failed:.*agy denied' "$TMP/dashboard.out"
manifest_init fixture-agy-parent "$TMP/agy-parent.log"
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1 MANIFEST_PARENT_TMP="$MANIFEST_TMP"
check 'a nested run still reports the conversation' json_is "$RESULT" ".status==\"permission-denied\" and .conversation_ids==[\"$AGY_ID\"]"
check 'the nested run adds nothing but its role to the parent' json_is "$MANIFEST_TMP" '(.inputs | any(.kind=="agy-conversation") | not) and (.roles|length)==1'

rm -rf "$AGY_HOME/brain"
agy_review 3 TEST_AGY_NOTICE=1
check 'a notice-only run with no record is a denial of unknown target' json_is "$RESULT" '.status=="permission-denied" and .denied==[] and .conversation_ids==[] and (.error|contains("target unknown"))'
check 'stderr says the target is unknown' grep -q 'its target is not recorded' "$TMP/wrapper.err"

printf '## Verdict\nSHIP — fine\n## Verdict\nSHIP — twice\n' > "$TMP/agy-stdout.md"
agy_transcript
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_STDOUT="$TMP/agy-stdout.md"
check 'a recovered denial before a malformed review stays a parse failure' json_is "$RESULT" '.status=="parse-failed" and .error=="duplicate Verdict headings" and (has("denied")|not)'
rm -rf "$AGY_HOME/brain"
agy_review 3 TEST_AGY_STDOUT="$TMP/agy-stdout.md" TEST_AGY_NOTICE=1
check 'a notice beside a malformed review, with no record, stays a parse failure' json_is "$RESULT" '.status=="parse-failed"'

fixture 'SHIP — clean'
agy_transcript
agy_review 0 TEST_AGY_ID="$AGY_ID" TEST_AGY_STDOUT="$TMP/review.md" TEST_AGY_NOTICE=1
check 'a review that parsed is never demoted' json_is "$RESULT" '.status=="ok" and .verdict=="SHIP"'

# The same notice from a model without workspace_args is not agy's evidence.
printf '%s\n' "$AGY_NOTICE" > "$TMP/review.md"
agy_transcript
run_review 3 DEV_TRIO_REVIEWER_MODEL=codex DEV_TRIO_AGY_HOME="$AGY_HOME"
check 'codex output quoting the notice stays a parse failure' json_is "$RESULT" '.status=="parse-failed"'

# A conversation id that is not a uuid never becomes part of a path: a decoy
# transcript where "../../x" would lead is not read.
mkdir -p "$TMP/x/.system_generated/logs"
cp "$AGY_HOME/brain/$AGY_ID/.system_generated/logs/transcript_full.jsonl" "$TMP/x/.system_generated/logs/"
rm -rf "$AGY_HOME/brain"
agy_review 3 TEST_AGY_ID=../../x TEST_AGY_NOTICE=1
check 'a traversal id reads no transcript' json_is "$RESULT" '.status=="permission-denied" and .denied==[] and .conversation_ids==[]'

# A large transcript: the notice is still found, and a final that is mostly
# other text is still not "notice only" (#103 review: an early-exiting grep
# under pipefail turned both answers around).
seq 1 200000 > "$TMP/agy-noise"
{ printf '%s\n' "$AGY_NOTICE"; cat "$TMP/agy-noise"; } > "$TMP/agy-noisy"
agy_scan() { bash -c 'set -euo pipefail; . "$1/dev-trio/lib/agy-denial.sh"; shift; "$@"' _ "$ROOT" "$@"; }
check 'a notice followed by much output is still found' agy_scan agy_denial_notice_in "$TMP/agy-noisy"
check 'a notice early in a byte range is still found' agy_scan agy_denial_notice_in "$TMP/agy-noisy" 0 300
check 'much other output is not notice-only' eval '! agy_scan agy_denial_notice_only "$TMP/agy-noisy"'
agy_transcript
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1 TEST_AGY_NOISE=1
check 'a notice beside other output stays a parse failure even with recorded denials' json_is "$RESULT" '.status=="parse-failed" and (has("denied")|not)'
agy_transcript
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1 TEST_AGY_STDOUT="$TMP/agy-stdout.md"
check 'a notice, recorded denials and a malformed review stay a parse failure' json_is "$RESULT" '.status=="parse-failed" and .error=="duplicate Verdict headings"'

# A log directory agy could not create a file in gets no --log-file either:
# the wrapper creates the file itself first, and here it cannot.
chmod 600 "$AGY_HOME/log"
agy_review 3 TEST_AGY_NOTICE=1
chmod 700 "$AGY_HOME/log"
check 'unsearchable log directory: no --log-file' test "$(head -1 "$TMP/agy-argv")" = --add-dir
check 'the reserved agy log is private' test "$(find "$AGY_HOME/log" -name 'cli-dev-trio-review-*' ! -perm 600 | wc -l | tr -d ' ')" = 0

# Without a writable log directory agy gets no --log-file — given one it
# cannot create, it writes its whole log to stderr — but keeps --add-dir.
mv "$AGY_HOME/log" "$AGY_HOME/log.off"
agy_review 3 TEST_AGY_NOTICE=1
check 'no log directory: no --log-file' test "$(head -1 "$TMP/agy-argv")" = --add-dir
mv "$AGY_HOME/log.off" "$AGY_HOME/log"

printf 'review-result smoke: %s assertions passed\n' "$PASS"
