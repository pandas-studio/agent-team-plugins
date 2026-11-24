#!/usr/bin/env bash
# Model-free regressions for dev-trio #19 and #21, including real wrapper and
# dashboard consumers. No tmux, login, model CLI, or user's registry is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../dev-trio/lib/review-result.sh
. "$ROOT/dev-trio/lib/review-result.sh"
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
# agy's home is pinned to a directory that does not exist, so agy roles get
# --add-dir but never --log-file, whatever this machine has installed (#103).
export DEV_TRIO_AGY_HOME=/nonexistent/dev-trio-test-agy-home
trap 'wait; rm -rf "$TMP"' EXIT
PASS=0
check() {
  local label="$1"; shift
  if ! "$@"; then
    echo "FAIL: $label" >&2
    [ ! -f "$TMP/wrapper.err" ] || cat "$TMP/wrapper.err" >&2
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
no_runstate_begin() { ! runstate_begin "$1" channel=reviewer wrapper=ask-reviewer.sh 2>/dev/null; }
no_runstate_complete() { ! runstate_complete "$1" exit_code=0 2>/dev/null; }
no_runstate_read() { ! runstate_read "$1" >/dev/null 2>&1; }
# completion.timing shapes (dev-trio/lib/runstate.sh). Each names all three
# keys, so a missing key and a null value are told apart.
TIMING_SECONDS='type == "number" and . >= 0 and floor == .'
TIMING_KEYS='(.completion.timing | keys) == ["model_s", "post_model_s", "pre_model_s"]'
TIMING_ALL="$TIMING_KEYS and (.completion.timing | all(.[]; $TIMING_SECONDS))"
TIMING_NO_POST="$TIMING_KEYS and .completion.timing.post_model_s == null and (.completion.timing | [.pre_model_s, .model_s] | all(.[]; $TIMING_SECONDS))"
TIMING_NONE='.completion.timing == {pre_model_s: null, model_s: null, post_model_s: null}'
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
  for separator in ' — ' '. ' ': '; do
    fixture "$token${separator}reason"
    parse
    check "$token punctuation parsed" json_is "$TMP/parsed.json" ".verdict == \"$token\" and .exit_code == 0 and .status == \"ok\""
    check 'empty placeholders count zero' json_is "$TMP/parsed.json" '.findings == {blocker:[],major:[],minor:[]}'
    check 'result reader agrees' review_result_read "$TMP/parsed.json" >/dev/null
  done
done
# A colon separator (#128) is a separator only when followed by a space and a reason.
for line in 'SHIP:reason' 'SHIP: ' 'NEEDS-FIX:: two colons' 'SHIPPED: unknown token'; do
  fixture "$line"
  parse
  check "malformed colon verdict fails: $line" json_is "$TMP/parsed.json" \
    '.status=="parse-failed" and .exit_code==3 and .verdict==null and .findings=={blocker:null,major:null,minor:null}'
done
fixture 'SHIP:reason'
parse
check 'missing space after the colon names the accepted forms' json_is "$TMP/parsed.json" '.error|contains("TOKEN: reason")'
fixture 'SHIP: '
parse
check 'colon with no reason is an empty reason' json_is "$TMP/parsed.json" '.error=="empty verdict reason"'
fixture 'SHIPPED: unknown token'
parse
check 'colon does not widen the token vocabulary' json_is "$TMP/parsed.json" '.error=="unknown or malformed verdict token"'
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
# A list item indented 1-3 spaces directly under a finding belongs to that
# finding: it is folded into the finding's line, so counts do not inflate and
# the review still parses. 3 of 131 Claude reviews after #189 failed on exactly
# this shape (fix options or cases as sub-bullets).
printf '## Verdict\nSHIP — nested detail joins its finding\n## Findings\n### Major\n- A real finding.\n  - Supporting detail.\n' > "$TMP/review.md"
parse
check 'a nested bullet folds into its finding' json_is "$TMP/parsed.json" \
  '.status=="ok" and .findings.major==["- A real finding. Supporting detail."]'
printf '## Verdict\nNEEDS-FIX — options as sub-bullets\n## Findings\n### Blocker\n- None.\n### Major\n- `a.py:1` — first.\n- `nb.ipynb` cell 1 — the cap leaves no room → either:\n  - (a) print the headroom;\n  * (b) or measure one run;\n  1. (c) or cap the limit.\n\n  Changing the cap is your call.\n### Minor / Nit\n- `c.py:3` — nit.\n' > "$TMP/review.md"
parse
check 'sub-bullet options fold into the last finding only' json_is "$TMP/parsed.json" \
  '.status=="ok" and .findings.blocker==[] and .findings.major==["- `a.py:1` — first.", "- `nb.ipynb` cell 1 — the cap leaves no room → either: (a) print the headroom; (b) or measure one run; (c) or cap the limit."] and .findings.minor==["- `c.py:3` — nit."]'
printf '## Verdict\nSHIP — a fold never crosses a heading\n## Findings\n### Blocker\n- A blocker.\n### Major\n  - Detail with no finding of its own section.\n' > "$TMP/review.md"
parse
check 'an indented item opening a section still fails' json_is "$TMP/parsed.json" '.status=="parse-failed" and (.error|contains("noncanonical major"))'
# Any heading ends the finding being folded, even one that is not a severity
# heading: an indented "### Major" must not move a Major concern into Minor.
printf '## Verdict\nSHIP — headings end a fold\n## Findings\n### Major\n- None.\n### Minor / Nit\n- Cleanup.\n  ### Major\n  - Missing authorization check.\n' > "$TMP/review.md"
parse
check 'an indented heading ends the fold' json_is "$TMP/parsed.json" '.status=="parse-failed" and (.error|contains("noncanonical minor"))'
printf '## Verdict\nSHIP — headings end a fold\n## Findings\n### Major\n- A finding.\n#### Detail\n  - Detail item.\n' > "$TMP/review.md"
parse
check 'a deeper heading ends the fold' json_is "$TMP/parsed.json" '.status=="parse-failed" and (.error|contains("noncanonical major"))'
printf '## Verdict\nSHIP — column 0 numbered lists stay ambiguous\n## Findings\n### Major\n- A real finding.\n1. Is this a second finding?\n' > "$TMP/review.md"
parse
check 'a column-0 numbered item after a finding still fails' json_is "$TMP/parsed.json" '.status=="parse-failed" and .findings.major==null'
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
FOLDED_125="$MAJOR_125"' `ex02b` with `{"Shareholding"}`: the hint no longer names the missing class. `ex06` with `{"payer"}`: the hint only repeats the default. Suggestion: keep the true sentences and rewrite only the ones that guess a cause.'
check 'sub-bullet reproductions fold into one finding' jq -e --arg major "$FOLDED_125" \
  '.status=="ok" and .findings.major==[$major] and (.findings.minor|length)==1 and .findings.blocker==[]' "$TMP/parsed.json"
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
# A fence is sized by the run of its opening character only: "~~~`" opens a
# three-tilde fence that "~~~" closes, and "`~~" does not close a backtick fence.
printf '~~~`\nexample\n~~~\n## Verdict\nSHIP — after a closed tilde fence\n## Findings\n### Blocker\n- None.\n### Major\n- None.\n### Minor / Nit\n- None.\n' > "$TMP/review.md"
parse
check 'a tilde fence with a trailing backtick closes on three tildes' json_is "$TMP/parsed.json" '.status=="ok" and .verdict=="SHIP"'
printf '## Verdict\nNEEDS-FIX — real\n## Findings\n### Major\n- Real.\n```\n`~~\n## Verdict\nSHIP — still fenced\n```\n' > "$TMP/review.md"
parse
check 'a mixed run does not close a backtick fence' json_is "$TMP/parsed.json" '.status=="ok" and .verdict=="NEEDS-FIX"'
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

# Kimi Code 2.3+ print mode (PromptBlockWriter) prefixes the first line of each
# assistant block with "• " and continuation lines with two spaces, plus an
# optional "To resume this session: kimi -r <id>" hint on stderr.
cat > "$TMP/review.md" <<'REVIEW'
• I will inspect the repository diff first.

• ## Verdict
  NEEDS-FIX — one major finding in Kimi print mode

  ## Findings

  ### Blocker
  - None.

  ### Major
  - `src/app.py:12` — missing check → validate input.

  ### Minor / Nit
  - 없음.

  ## What I checked
  - Checked `src/app.py`.

To resume this session: kimi -r 12345678-1234-1234-1234-123456789abc
REVIEW
parse
check 'kimi PromptBlockWriter review parses cleanly' json_is "$TMP/parsed.json" \
  '.status=="ok" and .exit_code==0 and .verdict=="NEEDS-FIX" and .findings.blocker==[] and .findings.major==["- `src/app.py:12` — missing check → validate input."] and .findings.minor==[]'

cat > "$TMP/review.md" <<'REVIEW'
• ## Verdict
  SHIP — indented finding inside Kimi block must still fail
  ## Findings
  ### Major
    - Indented two spaces inside the model response.
REVIEW
parse
check 'kimi PromptBlockWriter preserves fail-closed indentation check' json_is "$TMP/parsed.json" \
  '.status=="parse-failed" and .exit_code==3 and (.error|contains("noncanonical major"))'

cat > "$TMP/review.md" <<'REVIEW'
• ## Verdict
  SHIP — first block
• ## Verdict
  NEEDS-FIX — second block
REVIEW
parse
check 'kimi PromptBlockWriter rejects duplicate verdicts across blocks' json_is "$TMP/parsed.json" \
  '.status=="parse-failed" and .exit_code==3 and .error=="duplicate Verdict headings"'
fixture 'OUT-OF-SCOPE: contract violation'
parse
check 'default vocabulary stays closed with a colon' json_is "$TMP/parsed.json" '.exit_code==3 and .verdict==null'
parse 0 spec
check 'spec profile permits a colon contract verdict' json_is "$TMP/parsed.json" '.verdict=="OUT-OF-SCOPE" and .exit_code==0 and .verdict_line=="OUT-OF-SCOPE: contract violation"'
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
# INVOKE_ARGS are wrapper options for every invoke (empty unless a section sets
# them, e.g. --summary).
INVOKE_ARGS=()
invoke() {
  env "${INVOKE_ENV[@]}" "$@" "$ROOT/dev-trio/bin/ask-reviewer.sh" \
    ${INVOKE_ARGS[@]+"${INVOKE_ARGS[@]}"} 'fixture review'
}
run_review() {
  local expected="$1" rc=0; shift
  invoke "$@" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || rc=$?
  check "wrapper rc=$expected (actual $rc)" test "$rc" -eq "$expected"
  LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
  RESULT="${LOG%.log}.review.json"
  MANIFEST="${LOG%.log}.manifest.json"
  FINAL="${LOG%.log}.final.md"
  check 'wrapper publishes a readable result' review_result_read "$RESULT" >/dev/null
  check 'result matches wrapper rc' json_is "$RESULT" ".exit_code==$expected"
  check 'stderr names exact result' grep -Fq "result: $RESULT" "$TMP/wrapper.err"
}
dashboard() {
  printf q | env AGENT_TEAM=review-test TMUX='' TERM=dumb DEV_TRIO_LOG_DIR="$TMP/log" \
    "$@" bash "$ROOT/dev-trio/bin/dashboard.sh" reviewer > "$TMP/dashboard.out"
}
research_dashboard() {
  env AGENT_TEAM=review-test TMUX='' TERM=dumb DEV_TRIO_LOG_DIR="$TMP/log" \
    "$@" bash "$ROOT/dev-trio/bin/dashboard.sh" researcher --once < /dev/null > "$TMP/dashboard.out"
}
# #83: a resolved explanation after None must not become Major findings.
# Both model adapters write the one reviewer channel; this loop
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
  for separator in ' — ' '. ' ': '; do
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
ln -sfn "$OLD_FINAL" "$TMP/log/review-test/latest-reviewer.final.md"
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
ln -sfn "$PINNED_LOG" "$TMP/log/review-test/latest-reviewer.log"
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

for separator in '. ' ': '; do
  fixture "OUT-OF-SCOPE${separator}violates spec"
  run_review 0 DEV_TRIO_REVIEW_PROFILE=spec
  check 'spec wrapper verdict preserved' json_is "$MANIFEST" '.verdict=="OUT-OF-SCOPE"'
  dashboard
  check 'spec dashboard reports contract verdict' grep -Fq "OUT-OF-SCOPE${separator}violates spec" "$TMP/dashboard.out"
done
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
  failed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
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
  failed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
  check 'artifact failure also exercises the END fault' test -f "$TMP/end-write-fired"
  check 'logging cannot mask an artifact failure' test "$actual_rc" -eq "$expected_rc"
  check 'failed publication leaves no successful result' test ! -f "${failed_log%.log}.review.json"
  check 'artifact failure warns about the incomplete log' grep -q 'final log append failed' "$TMP/io.err"
  check 'artifact failure retains its completion reason' json_is "${failed_log%.log}.run.json" \
    ".completion.exit_code==$expected_rc and .completion.verdict==null and .completion.reason==\"result-write-failed\""
  check 'artifact failure still times the run' json_is "${failed_log%.log}.run.json" "$TIMING_ALL"
done

# Swapping the pathname after capture must not retarget the held END descriptor.
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
fixture 'SHIP — log pathname replaced'
for model in codex claude; do
  run_review 0 PATH="$TMP/end-open-shim:$PATH" DEV_TRIO_REVIEWER_MODEL="$model"
  check 'log pathname replacement was exercised' test -d "$LOG"
  check 'END did not open the replacement' no_match 'final log append failed' "$TMP/wrapper.err"
  check 'pathname replacement retains completion' json_is "${LOG%.log}.run.json" \
    '.completion.exit_code==0 and .completion.verdict=="SHIP" and .completion.reason=="ok"'
  rmdir "$LOG"
  mv "$LOG.saved" "$LOG"
  check 'held descriptor completed the original log' grep -q '^=== END (rc=0) ===' "$LOG"
  dashboard
  check 'dashboard retains the verdict after replacement' grep -q 'SHIP — log pathname replaced' "$TMP/dashboard.out"
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
  leak_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
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
closed_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
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
short_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'a short capture publishes no verdict' \
  json_is "${short_log%.log}.review.json" '.verdict==null and .exit_code==3'
check 'a short capture leaves no partial final' test ! -s "${short_log%.log}.final.md"
fixture 'SHIP — leaked descendant'

# A log that becomes unopenable between its header and the descriptor check
# falls back to an out-of-band transcript. Swap it as the latest final link is
# published, immediately before the wrapper opens its held read descriptor.
mkdir -p "$TMP/swapshim"
cat > "$TMP/swapshim/mv" <<'SHIM'
#!/bin/sh
/bin/mv "$@" || exit $?
for destination do :; done
if [ "$destination" = "$SWAP_SHIM_DIR/latest-reviewer.final.md" ]; then
  target="$SWAP_SHIM_DIR/$(readlink "$SWAP_SHIM_DIR/latest-reviewer.log")"
  if [ ! -e "$SWAP_SHIM_FIRED" ]; then
    : > "$SWAP_SHIM_FIRED"
    /bin/mv "$target" "$target.saved" && mkdir "$target"
  fi
fi
SHIM
chmod +x "$TMP/swapshim/mv"
rm -f "$TMP/swap-fired"
fixture 'SHIP — out of band'
oob_rc=0
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/oob-release" LEAK_DONE="$TMP/oob-done" LEAK_STREAM=stderr \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/swapshim:$PATH" \
  SWAP_SHIM_DIR="$TMP/log/review-test" SWAP_SHIM_FIRED="$TMP/swap-fired" \
  > "$TMP/oob.out" 2> "$TMP/oob.err" || oob_rc=$?
: > "$TMP/oob-release"
oob_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'out-of-band swap was exercised' test -d "$oob_log"
rmdir "$oob_log"
mv "$oob_log.saved" "$oob_log"
check 'an unopenable log does not fail the review' test "$oob_rc" -eq 0
check 'an unopenable log falls back out of band' grep -q 'keeping it out of band' "$TMP/oob.err"
check 'the out-of-band transcript still reaches stdout' \
  grep -q 'SHIP — out of band' "$TMP/oob.out"
check 'the out-of-band run still publishes a verdict' \
  json_is "${oob_log%.log}.review.json" '.verdict=="SHIP" and .exit_code==0'
check 'the out-of-band transcript is not left beside the logs' \
  test -z "$(find "$TMP/log/review-test" -name '*.transcript.*' -print -quit)"
check 'out-of-band END reaches the original log inode' grep -q '^=== END (rc=0) ===' "$oob_log"
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
  interrupted_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
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
  # The signal is recorded while the call runs, the call comes back, and only
  # then does the wrapper exit: both marks exist when the abort is published.
  check "an interrupted run times the call that came back ($interrupt_signal)" \
    json_is "${interrupted_log%.log}.run.json" "$TIMING_ALL"
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
rm -f "$TMP/swap-fired-oob" "$TMP/oob2-ready" "$TMP/oob2-release"
set -m
env "${INVOKE_ENV[@]}" CODEX_CLI="$TMP/slow-reviewer" CLAUDE_CLI="$TMP/slow-reviewer" \
  SLOW_READY="$TMP/oob2-ready" SLOW_RELEASE="$TMP/oob2-release" \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/swapshim:$PATH" \
  SWAP_SHIM_DIR="$TMP/log/review-test" SWAP_SHIM_FIRED="$TMP/swap-fired-oob" \
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
oob2_log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'interrupted swap was exercised' test -d "$oob2_log"
rmdir "$oob2_log"
mv "$oob2_log.saved" "$oob2_log"
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
results=( "$TMP/log/review-test"/reviewer-20000101-000000-*.review.json )
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
  '.channel=="reviewer" and .role=="reviewer" and .model=="claude" and .team=="review-test"'
check 'metadata binds its own artifacts' json_is "$RUN" \
  ".log_path==\"$LOG\" and .result_path==\"$RESULT\" and .final_path==\"$FINAL\""
check 'metadata records completion once the run ends' json_is "$RUN" \
  '.completion.exit_code==0 and .completion.verdict=="SHIP" and .completion.reason=="ok"'
check 'a finished run records the time before, in and after the model call' json_is "$RUN" "$TIMING_ALL"
check 'standalone run is not marked nested' json_is "$RUN" '.nested==false'
check 'metadata carries the focus it was given' json_is "$RUN" \
  '(.inputs|map(select(.kind=="focus"))|length)==1'

# model_s is the time inside the model call. A 1.2 s call crosses at least one
# whole-second boundary, so it reads 1 or more however the clock falls.
cat > "$TMP/pausing-reviewer" <<'STUB'
#!/usr/bin/env bash
sleep 1.2
exec "$PAUSING_REVIEWER" "$@"
STUB
chmod +x "$TMP/pausing-reviewer"
fixture 'SHIP — timed run'
run_review 0 CODEX_CLI="$TMP/pausing-reviewer" PAUSING_REVIEWER="$TMP/reviewer"
TIMED_RUN="${LOG%.log}.run.json"
check 'time spent in the model call is counted as model time' json_is "$TIMED_RUN" \
  "$TIMING_ALL and .completion.timing.model_s >= 1"
# The clock is the epoch, not Bash's SECONDS, which the caller controls: an
# inherited value (large or negative) changes nothing.
for inherited_seconds in 100000 -100; do
  fixture "SHIP — inherited SECONDS=$inherited_seconds"
  run_review 0 SECONDS="$inherited_seconds"
  check "an inherited SECONDS=$inherited_seconds leaves the timing whole" json_is "${LOG%.log}.run.json" \
    "$TIMING_ALL and .completion.timing.pre_model_s < 1000"
done

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
  no_runstate_begin "$TMP/nonexistent-dir/reviewer-1.log"
check 'failed begin leaves no metadata' test ! -e "$TMP/nonexistent-dir/reviewer-1.run.json"
: > "$TMP/log/review-test/orphan-20000101-000000-1.log"
check 'completing a run with no metadata fails' \
  no_runstate_complete "$TMP/log/review-test/orphan-20000101-000000-1.log"
check 'failed completion invents no metadata' \
  test ! -e "$TMP/log/review-test/orphan-20000101-000000-1.run.json"
# completion.timing at the function: what a caller with no marks publishes, and
# that a bad timing value costs only itself, never the completion.
UNMARKED="$TMP/log/review-test/unmarked-20000101-000000-1.log"
runstate_begin "$UNMARKED" channel=reviewer wrapper=ask-reviewer.sh
runstate_complete "$UNMARKED" exit_code=4 reason=failed
check 'a completion with no timing arguments has three null timings' \
  json_is "${UNMARKED%.log}.run.json" "$TIMING_NONE and .completion.exit_code==4"
BADTIME="$TMP/log/review-test/badtime-20000101-000000-1.log"
runstate_begin "$BADTIME" channel=reviewer wrapper=ask-reviewer.sh
check 'a bad timing value does not fail the completion' \
  runstate_complete "$BADTIME" exit_code=0 pre_model_s=3 model_s=abc post_model_s=-1
check 'a bad timing value is published as null beside the good one' \
  json_is "${BADTIME%.log}.run.json" \
  '.completion.exit_code==0 and .completion.timing == {pre_model_s: 3, model_s: null, post_model_s: null}'
check 'metadata with null timings is readable' runstate_read "${BADTIME%.log}.run.json" >/dev/null
check 'metadata with timings from a real run is readable' runstate_read "$TIMED_RUN" >/dev/null
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
  AGY_LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-researcher.log")"
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
# Same failure and same limit as "an ordinary run does not wait out a bound"
# above: a fixed wait charged to every call. A stubbed researcher run is
# 1.2-1.6 s on a developer Mac and slower on a hosted macOS runner, where a
# 3 s limit failed with nothing waiting (PRs #197, #214, #235).
check 'an ordinary run adds no waiting of its own' test $((SECONDS - PROMPT_START)) -lt 5
check 'researcher succeeds' test "$AGY_RC" -eq 0
check 'answer artifact holds the answer' grep -q 'loader resolves the role' "$AGY_FINAL"
check 'answer artifact excludes CLI diagnostics' no_match 'Ripgrep not found' "$AGY_FINAL"
check 'log still carries the diagnostics' grep -q 'Ripgrep not found' "$AGY_LOG"
check 'callers receive the answer on stdout' grep -q 'loader resolves the role' "$TMP/research.out"
check 'callers do not receive diagnostics as an answer' no_match 'Ripgrep not found' "$TMP/research.out"
check 'research metadata describes the channel' json_is "$AGY_RUN" \
  '.channel=="researcher" and .role=="researcher" and .completion.exit_code==0'
check 'a finished research run records all three timings' json_is "$AGY_RUN" "$TIMING_ALL"
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
# The marks are inherited too. An end mark that survived would give this run
# a post_model_s it never had (and a negative model_s, published as null), and
# a surviving RUN_MODEL_RETURNED would cost it the model_s it has.
env -u DEV_TRIO_RESEARCHER_MODEL -u RESEARCHER_CLI -u AGY_CLI \
  RUN_MODEL_T0=1 RUN_MODEL_T1=1 RUN_MODEL_RETURNED=1 \
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
ABORTED_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-researcher.log")"
ABORTED_RUN="${ABORTED_RUN%.log}.run.json"
check 'aborted run publishes a completion' json_is "$ABORTED_RUN" '.completion != null'
check 'aborted run is recorded as aborted' json_is "$ABORTED_RUN" '.completion.reason=="aborted"'
check 'aborted run records the signal exit code' json_is "$ABORTED_RUN" '.completion.exit_code==143'
# The research wrapper exits from its signal trap while the call is still
# running: the start mark exists, the end mark does not.
check 'aborted run times the call up to the abort, and nothing after it' \
  json_is "$ABORTED_RUN" "$TIMING_NO_POST"
research_dashboard
check 'aborted run is not reported as still running' no_match 'no completion recorded' "$TMP/dashboard.out"

# A run that ends after its metadata exists but before the model call: the
# latest link cannot be made, errexit ends the wrapper, and the EXIT trap
# publishes the completion with no timing.
mkdir "$TMP/latest-ln-shim"
cat > "$TMP/latest-ln-shim/ln" <<'SHIM'
#!/bin/sh
case "$*" in *"/.latest-"*) exit 1 ;; esac
exec /bin/ln "$@"
SHIM
chmod +x "$TMP/latest-ln-shim/ln"
fixture 'SHIP — never reached'
premodel_rc=0
invoke PATH="$TMP/latest-ln-shim:$PATH" DEV_TRIO_LOG_DIR="$TMP/premodel-log" \
  > "$TMP/premodel.out" 2> "$TMP/premodel.err" || premodel_rc=$?
PREMODEL_RUN=$(find "$TMP/premodel-log" -name 'reviewer-*.run.json')
check 'a run that fails before the model call exits nonzero' test "$premodel_rc" -ne 0
check 'a run that fails before the model call has one metadata file' \
  test "$(printf '%s\n' "$PREMODEL_RUN" | grep -c .)" -eq 1
check 'a run that fails before the model call publishes no timing' json_is "$PREMODEL_RUN" \
  "$TIMING_NONE and .completion.reason==\"aborted\" and .completion.exit_code==$premodel_rc"

# A BASH_ENV that unsets SECONDS changes nothing: it is not the clock.
printf 'unset SECONDS\n' > "$TMP/unset-seconds.sh"
help_without_seconds() { env BASH_ENV="$TMP/unset-seconds.sh" "$ROOT/dev-trio/bin/$1" --help > /dev/null; }
for wrapper in ask-reviewer.sh ask-researcher.sh; do
  check "an unset SECONDS leaves --help working ($wrapper)" help_without_seconds "$wrapper"
done
fixture 'SHIP — unset SECONDS'
run_review 0 BASH_ENV="$TMP/unset-seconds.sh"
check 'an unset SECONDS leaves the timing whole' json_is "${LOG%.log}.run.json" "$TIMING_ALL"

# A clock that cannot be read costs the timing, nothing else: only `date +%s`
# fails here, so the other timestamps are still written.
REAL_DATE=$(command -v date)
mkdir "$TMP/clockless-shim"
cat > "$TMP/clockless-shim/date" <<SHIM
#!/bin/sh
[ "\${1:-}" != +%s ] || exit 1
exec "$REAL_DATE" "\$@"
SHIM
chmod +x "$TMP/clockless-shim/date"
fixture 'SHIP — no clock'
run_review 0 PATH="$TMP/clockless-shim:$PATH"
check 'a run with no clock still records its completion' json_is "${LOG%.log}.run.json" \
  "$TIMING_NONE and .completion.reason==\"ok\" and .completion.exit_code==0"

# Each mark runs `date`, so where a mark sits decides what happens while that
# `date` runs. This shim acts on the Nth `date +%s` of a review: 1 is the
# wrapper's baseline, 2 the start mark, 3 the end mark.
mkdir "$TMP/acting-clock"
cat > "$TMP/acting-clock/date" <<'SHIM'
#!/bin/sh
if [ "${1:-}" = +%s ]; then
  n=$(( $(cat "$CLOCK_COUNT" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$CLOCK_COUNT"
  if [ "$n" = "$CLOCK_ACT_AT" ]; then
    case "$CLOCK_ACT" in
      term)
        i=0
        while [ ! -s "$CLOCK_PIDFILE" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        kill -TERM "$(cat "$CLOCK_PIDFILE")"
        sleep 0.3 ;;
      late) printf 'LATE-CLOCK-BYTES\n' >&8 ;;
    esac
  fi
fi
exec "$CLOCK_REAL_DATE" "$@"
SHIM
chmod +x "$TMP/acting-clock/date"
cat > "$TMP/marking-reviewer" <<'STUB'
#!/usr/bin/env bash
: > "$MODEL_RAN"
exec "$MARKED_REVIEWER" "$@"
STUB
chmod +x "$TMP/marking-reviewer"

# A TERM during the start mark ends the run before the model is launched: the
# mark is taken before the traps that only record a signal.
fixture 'SHIP — cancelled at the start mark'
rm -f "$TMP/clock-count" "$TMP/clock-pid" "$TMP/model-ran"
env "${INVOKE_ENV[@]}" PATH="$TMP/acting-clock:$PATH" CLOCK_REAL_DATE="$REAL_DATE" \
  CLOCK_COUNT="$TMP/clock-count" CLOCK_ACT_AT=2 CLOCK_ACT=term CLOCK_PIDFILE="$TMP/clock-pid" \
  CODEX_CLI="$TMP/marking-reviewer" MARKED_REVIEWER="$TMP/reviewer" MODEL_RAN="$TMP/model-ran" \
  DEV_TRIO_LOG_DIR="$TMP/cancel-log" \
  "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review' > "$TMP/cancel.out" 2> "$TMP/cancel.err" &
cancel_pid=$!
echo "$cancel_pid" > "$TMP/clock-pid"
cancel_rc=0
wait "$cancel_pid" || cancel_rc=$?
check 'a TERM during the start mark exits 143' test "$cancel_rc" -eq 143
check 'a TERM during the start mark launches no model' test ! -e "$TMP/model-ran"
check 'a TERM during the start mark records an aborted run' \
  json_is "$(find "$TMP/cancel-log" -name 'reviewer-*.run.json')" \
  '.completion.reason=="aborted" and .completion.exit_code==143'

# Bytes written while the end mark runs come after the transcript's end was
# sampled, so they reach neither the replay on stdout nor the final.
fixture 'SHIP — late bytes at the end mark'
rm -f "$TMP/clock-count"
run_review 0 PATH="$TMP/acting-clock:$PATH" CLOCK_REAL_DATE="$REAL_DATE" \
  CLOCK_COUNT="$TMP/clock-count" CLOCK_ACT_AT=3 CLOCK_ACT=late
check 'the end mark ran the acting clock' grep -q 'LATE-CLOCK-BYTES' "$LOG"
check 'bytes written during the end mark are not replayed' no_match 'LATE-CLOCK-BYTES' "$TMP/wrapper.out"
check 'bytes written during the end mark are not in the final' no_match 'LATE-CLOCK-BYTES' "$FINAL"

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
  NATIVE_LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-researcher.log")"
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
FAIL_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-researcher.log")"
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
LEAK_RUN="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-researcher.log")"
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
cat >/dev/null
log=""
[ "${1:-}" != --log-file ] || log="$2"
# Like agy's own log: the conversation id, and the user's allow list.
# The log's and its directory's modes while the run is live, before cleanup.
if [ -n "$log" ] && [ -n "${TEST_AGY_PERMS:-}" ]; then
  { ls -ld "${log%/*}" | cut -c1-10; ls -l "$log" | cut -c1-10; } > "$TEST_AGY_PERMS"
fi
if [ -n "$log" ] && [ -n "${TEST_AGY_ID:-}" ]; then
  printf 'I0923 17:51:49.1 1 server.go:1239] Created conversation %s%s\n' "$TEST_AGY_ID" "${TEST_AGY_LOG_SUFFIX:-}" > "$log"
  printf 'I0923 17:51:49.2 1 cli_setting_manager.go:92] permissions=&{Allow:[command(SENTINEL-RULE)]}\n' >> "$log"
  [ -z "${TEST_AGY_EXTRA_LOG:-}" ] || printf '%s\n' "$TEST_AGY_EXTRA_LOG" >> "$log"
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
check 'agy argv pins its log and the workspace without a prompt' test "$(sed -n '1p;3p;5p;6p;7p;8p' "$TMP/agy-argv" | tr '\n' ' ')" = '--log-file --add-dir --input-format text --output-format text '
check 'agy workspace is the repository root' test "$(sed -n 4p "$TMP/agy-argv")" = "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
check 'agy log lives in agy home' test "$(sed -n 2p "$TMP/agy-argv")" = "$AGY_HOME/log/cli-dev-trio-review-${LOG##*/reviewer-}"
# The channel is the role: an agy reviewer still writes reviewer-* and links
# links latest-reviewer.* to this run, and no pre-role latest-codex.*; the
# model is in the run metadata.
check 'agy reviewer log is on the reviewer channel' eval 'case "${LOG##*/}" in reviewer-[0-9]*.log) true ;; *) false ;; esac'
check 'agy reviewer metadata records the real model' json_is "${LOG%.log}.run.json" \
  ".channel==\"reviewer\" and .role==\"reviewer\" and .model==\"agy\" and .run_stem==\"$(basename "${LOG%.log}")\""
check "latest-reviewer.log names this run" test "$(readlink "$TMP/log/review-test/latest-reviewer.log")" = "${LOG##*/}"
check "latest-reviewer.final.md names this run" test "$(readlink "$TMP/log/review-test/latest-reviewer.final.md")" = "${FINAL##*/}"
for suffix in log final.md; do
  check "no latest-codex.$suffix is published" eval "[ ! -e \"\$TMP/log/review-test/latest-codex.$suffix\" ] && [ ! -L \"\$TMP/log/review-test/latest-codex.$suffix\" ]"
done
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
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_LOG_SUFFIX=' (backend=BACKEND_TYPE_UNSPECIFIED)' TEST_AGY_NOTICE=1
check 'agy 1.4+ trailing backend tag still resolves the conversation and denials' json_is "$RESULT" ".status==\"permission-denied\" and .denied==$AGY_DENIED and .conversation_ids==[\"$AGY_ID\"]"
# --summary on a denial: the published result as it is, and no final text,
# because the review did not parse.
INVOKE_ARGS=(--summary)
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1
INVOKE_ARGS=()
check 'a summarized denial carries the published result' \
  test "$(jq -cS .result "$TMP/wrapper.out")" = "$(jq -cS . "$RESULT")"
check 'a summarized denial is one document' \
  eval '[ "$(wc -l < "$TMP/wrapper.out" | tr -d " ")" = 1 ] && jq -e -s "length == 1" "$TMP/wrapper.out" >/dev/null'
check 'a summarized denial has no final text' json_is "$TMP/wrapper.out" \
  '.exit_code==3 and .model=="agy" and .result.status=="permission-denied" and .final_text==null and .final_truncated==false and .error==null'
check 'a summarized denial still names the denial on stderr' \
  grep -Fxq '[ask-reviewer] agy denied: command(lsof -p $$ || pwd)' "$TMP/wrapper.err"

# agy 1.4+ print-mode soft-denials close the stream before writing a status:ERROR
# step to transcript_full.jsonl, leaving only the preceding PLANNER_RESPONSE
# (step 53) and the CLI log's unapproved confirmation at step 54.
agy_soft_denial_transcript() {
  local dir="$AGY_HOME/brain/$AGY_ID/.system_generated/logs"
  rm -rf "$AGY_HOME/brain"
  mkdir -p "$dir"
  {
    jq -cn '{step_index:26,type:"PLANNER_RESPONSE",status:"DONE",tool_calls:[{id:"c1",name:"read_file",args:{Path:"/repo/a.md"}},{id:"c2",name:"run_command",args:{CommandLine:"git status"}}]}'
    jq -cn '{step_index:27,type:"VIEW_FILE_OUTLINE",status:"DONE"}'
    jq -cn '{step_index:53,type:"PLANNER_RESPONSE",status:"DONE",tool_calls:[{id:"c3",name:"read_file",args:{Path:"/repo/c.md"}},{id:"c4",name:"run_command",args:{CommandLine:"git log -S \"```mermaid\" --oneline -- slides/src/"}}]}'
    jq -cn '{step_index:54,type:"VIEW_FILE_OUTLINE",status:"DONE"}'
  } > "$dir/transcript_full.jsonl"
}
agy_soft_denial_transcript
SOFT_LOG=$(printf 'W1026 12:08:06.8 1 print.go:196] Print mode: soft-denying tool confirmation "RunCommand" at step 55\nI1026 12:08:06.8 1 server.go:2203] Tool confirmation for conversation %s step 55 (type=*gemini_coder_go_proto.Step_Generic approved=false)\nI1026 12:08:06.8 1 server.go:2203] Tool confirmation for conversation 00000000-0000-0000-0000-000000000000 step 28 (type=*gemini_coder_go_proto.Step_Generic approved=false)' "$AGY_ID")
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_LOG_SUFFIX=' (backend=BACKEND_TYPE_UNSPECIFIED)' TEST_AGY_EXTRA_LOG="$SOFT_LOG" TEST_AGY_NOTICE=1
check 'agy 1.4+ print-mode soft-denial extracts the denied command from PLANNER_RESPONSE' json_is "$RESULT" \
  ".status==\"permission-denied\" and .denied==[\"command(git log -S \\\"\`\`\`mermaid\\\" --oneline -- slides/src/)\"] and .conversation_ids==[\"$AGY_ID\"]"
check 'stderr names the soft-denied backtick git command' grep -Fxq '[ask-reviewer] agy denied: command(git log -S "```mermaid" --oneline -- slides/src/)' "$TMP/wrapper.err"

# A soft-denied read_file (agy 1.5.9, 2026-11-16): the denied call is the 4th
# of a parallel batch and agy exited before writing its row (step 10), so the
# path is the planner's. PATH_JSON is that call's Path; further arguments are
# extra transcript rows.
agy_read_denial_transcript() {
  local dir="$AGY_HOME/brain/$AGY_ID/.system_generated/logs" path="$1" row
  shift
  rm -rf "$AGY_HOME/brain"
  mkdir -p "$dir"
  {
    jq -cn --argjson path "$path" '{step_index:6,type:"PLANNER_RESPONSE",status:"DONE",tool_calls:[
      {id:"r1",name:"read_file",args:{Path:"/agy/brain/steps/3/output.txt",StartLine:1,EndLine:800}},
      {id:"r2",name:"read_file",args:{Path:"/agy/brain/steps/3/output.txt",StartLine:801,EndLine:1600}},
      {id:"r3",name:"read_file",args:{Path:"/repo/notes.md"}},
      {id:"r4",name:"read_file",args:{Path:$path}}]}'
    for row in 7 8 9; do jq -cn --argjson s "$row" '{step_index:$s,type:"GENERIC",status:"DONE"}'; done
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$dir/transcript_full.jsonl"
}
agy_read_denial_review() {
  agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_LOG_SUFFIX=' (backend=BACKEND_TYPE_UNSPECIFIED)' TEST_AGY_EXTRA_LOG="$READ_LOG" TEST_AGY_NOTICE=1
}
READ_LOG=$(printf 'W1116 19:26:35.5 1 tool_confirmation_manager.go:221] Print mode: soft-denying tool confirmation "ReadFile" at step 10\nI1116 19:26:35.5 1 server.go:2738] Tool confirmation for conversation %s step 10 (type=*gemini_coder_go_proto.Step_Generic approved=false)' "$AGY_ID")
READ_HINT='(check whether this path is inside the workspace before adding a rule; see the README step on read_file targets)'
read_denied_row() {
  jq -cn --argjson s "$1" --arg p "$2" '{step_index:$s,type:"GENERIC",status:"ERROR",error:("permission check failed for read_file " + ($p | tojson) + ": user denied permission for read_file(" + $p + ")")}'
}

agy_read_denial_transcript '"/outside/made_up"'
agy_read_denial_review
check 'a soft-denied read_file is named from the planner call at its index' json_is "$RESULT" \
  ".status==\"permission-denied\" and .denied==[\"read_file(/outside/made_up)\"] and .conversation_ids==[\"$AGY_ID\"]"
check 'the denial error names the read' json_is "$RESULT" '.error | startswith("agy denied a tool in headless mode: read_file(/outside/made_up) (parse:")'
check 'stderr names the soft-denied read with the workspace check' grep -Fxq "[ask-reviewer] agy denied: read_file(/outside/made_up) $READ_HINT" "$TMP/wrapper.err"

# The step agy did record is not restored a second time: the planner call
# here names another path, which would show if the fallback ran.
agy_read_denial_transcript '"/outside/planner_only"' "$(read_denied_row 10 /outside/recorded)"
agy_read_denial_review
check 'a recorded read denial suppresses the planner fallback for that step' json_is "$RESULT" '.denied==["read_file(/outside/recorded)"]'

# The same path from both sources — an earlier denial agy recorded and went on
# from, then the unrecorded one that ended the run — is listed once.
agy_read_denial_transcript '"/outside/made_up"' "$(read_denied_row 5 /outside/made_up)"
agy_read_denial_review
check 'a read named by an ERROR row and by the planner is listed once' json_is "$RESULT" '.denied==["read_file(/outside/made_up)"]'

agy_read_denial_transcript '{"not":"a string"}'
agy_read_denial_review
check 'a read_file call without a string Path names no target' json_is "$RESULT" '.status=="permission-denied" and .denied==[] and (.error|contains("target unknown"))'
check 'stderr says that read target is not recorded' grep -q 'its target is not recorded' "$TMP/wrapper.err"

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

# #193: a log directory agy could not create a file in (a host sandbox that
# blocks agy home) gets a private temporary log instead of none: given no
# --log-file, agy writes its whole log, allow list included, to the transcript.
# TMPDIR is given with a trailing slash; the path is the physical one.
chmod 600 "$AGY_HOME/log"
mkdir -p "$TMP/tmproot"
TMP_ROOT=$(cd -P "$TMP/tmproot" && pwd -P)
agy_transcript
agy_review 3 TEST_AGY_ID="$AGY_ID" TEST_AGY_NOTICE=1 TEST_AGY_PERMS="$TMP/agy-perms" TMPDIR="$TMP/tmproot/"
chmod 700 "$AGY_HOME/log"
FALLBACK_LOG=$(sed -n 2p "$TMP/agy-argv")
check 'unsearchable log directory: the log is pinned in a private temporary directory' \
  test "$(head -1 "$TMP/agy-argv")" = --log-file
check 'the fallback log is under the physical TMPDIR' \
  eval 'case "$FALLBACK_LOG" in "$TMP_ROOT"/dev-trio-agy.*/cli-dev-trio-review-*.log) true ;; *) false ;; esac'
check 'the fallback directory and log are private while the run is live' \
  test "$(tr '\n' ' ' < "$TMP/agy-perms")" = 'drwx------ -rw------- '
check 'the fallback directory is removed when the run ends' test ! -e "${FALLBACK_LOG%/*}"
check 'nothing of the fallback is left in TMPDIR' test -z "$(ls -A "$TMP/tmproot" | grep "^dev-trio-agy\.")"
check 'stderr says the fallback was used' grep -Fq "[ask-reviewer] could not create agy's per-run log under $AGY_HOME/log; using a private temporary file" "$TMP/wrapper.err"
check 'the transcript header says so, before the response marker' \
  test "$(grep -n -e '^=== AGY LOG: private temporary fallback ===$' -e '^=== RESPONSE ===$' "$LOG" | cut -d: -f2- | tr '\n' '|')" = '=== AGY LOG: private temporary fallback ===|=== RESPONSE ===|'
check 'the allow list stays out of the transcript' no_match 'SENTINEL-RULE' "$LOG"
check 'a denial is still named through the fallback log' json_is "$RESULT" ".status==\"permission-denied\" and .denied==$AGY_DENIED and .conversation_ids==[\"$AGY_ID\"]"

# A TMPDIR reached through a symlink resolves to its physical directory.
ln -s "$TMP/tmproot" "$TMP/tmplink"
chmod 600 "$AGY_HOME/log"
agy_review 3 TEST_AGY_NOTICE=1 TMPDIR="$TMP/tmplink"
chmod 700 "$AGY_HOME/log"
check 'a symlinked TMPDIR gives a physical fallback path' \
  eval 'case "$(sed -n 2p "$TMP/agy-argv")" in "$TMP_ROOT"/dev-trio-agy.*) true ;; *) false ;; esac'
check 'and is cleaned up' test -z "$(ls -A "$TMP/tmproot" | grep "^dev-trio-agy\.")"

# A TMPDIR inside agy home is still a fallback: marked and removed.
chmod 600 "$AGY_HOME/log"
mkdir -p "$AGY_HOME/tmpin"
agy_review 3 TEST_AGY_NOTICE=1 TMPDIR="$AGY_HOME/tmpin"
chmod 700 "$AGY_HOME/log"
check 'a TMPDIR inside agy home is marked as the fallback' grep -Fq 'could not create agy' "$TMP/wrapper.err"
check 'and removed' test -z "$(ls -A "$AGY_HOME/tmpin" | grep "^dev-trio-agy\.")"
rm -rf "$AGY_HOME/tmpin"

# A group/other-writable, non-sticky TMPDIR is refused, and nothing is left
# in it: agy gets no --log-file, as before the fallback.
mkdir -p "$TMP/tmpbad"
chmod 777 "$TMP/tmpbad"
chmod 600 "$AGY_HOME/log"
agy_review 3 TEST_AGY_NOTICE=1 TMPDIR="$TMP/tmpbad"
chmod 700 "$AGY_HOME/log"
check 'an unsafe TMPDIR: no --log-file' test "$(head -1 "$TMP/agy-argv")" = --add-dir
check 'an unsafe TMPDIR keeps nothing' test -z "$(ls -A "$TMP/tmpbad" | grep "^dev-trio-agy\.")"
check 'an unsafe TMPDIR: no fallback notice' no_match 'could not create agy' "$TMP/wrapper.err"
chmod 700 "$TMP/tmpbad"

# Without a log directory or a safe TMPDIR agy gets no --log-file — given one
# it cannot create, it writes its whole log to stderr — but keeps --add-dir.
# (An unwritable TMPDIR is not a case to test here: the answer capture needs
# it too, and the run fails with 6 whatever this fallback does.)
mv "$AGY_HOME/log" "$AGY_HOME/log.off"
chmod 777 "$TMP/tmpbad"
agy_review 3 TEST_AGY_NOTICE=1 TMPDIR="$TMP/tmpbad"
chmod 700 "$TMP/tmpbad"
check 'no log directory and no safe TMPDIR: no --log-file' test "$(head -1 "$TMP/agy-argv")" = --add-dir
mv "$AGY_HOME/log.off" "$AGY_HOME/log"
check 'the reserved agy log is private' test "$(find "$AGY_HOME/log" -name 'cli-dev-trio-review-*' ! -perm 600 | wc -l | tr -d ' ')" = 0

# --summary: stdout is one JSON document once the model call has returned, and
# nothing before that. Every field is compared with what the run published.
one_document() {
  [ "$(wc -l < "$1" | tr -d ' ')" = 1 ] \
    && jq -e -s 'length == 1 and (.[0] | type) == "object"' "$1" >/dev/null
}
same_result() { test "$(jq -cS .result "$1")" = "$(jq -cS . "$2")"; }
same_final_text() { jq -j .final_text "$1" | cmp -s - "$2"; }
summary_paths() {
  json_is "$1" ".paths == {log: \"$LOG\", final: \"$FINAL\", result: \"$RESULT\"} and .model == \"${2:-codex}\""
}
INVOKE_ARGS=(--summary)

fixture 'SHIP — summarized'
run_review 0
check 'a summary is one JSON document on one line' one_document "$TMP/wrapper.out"
check 'a summary has no transcript replay' no_match '^## Verdict' "$TMP/wrapper.out"
check 'a summary names the run' summary_paths "$TMP/wrapper.out"
check 'a summary carries the published result' same_result "$TMP/wrapper.out" "$RESULT"
check 'a summary carries the final text byte for byte' same_final_text "$TMP/wrapper.out" "$FINAL"
check 'a summary of an ok review has its fixed fields' json_is "$TMP/wrapper.out" \
  '.summary_version==1 and .exit_code==0 and .result.status=="ok" and .result.verdict=="SHIP" and .final_truncated==false and .error==null'
check 'a summarized run still writes the artifact line' grep -Fq "(log: $LOG, final: $FINAL, result: $RESULT, rc=0)" "$TMP/wrapper.err"
check 'a summarized run still publishes its completion' json_is "${LOG%.log}.run.json" '.completion.reason=="ok" and .completion.exit_code==0'

printf 'Just prose, with no Verdict heading.\n' > "$TMP/review.md"
run_review 3
check 'a summary of a parse failure is one document' one_document "$TMP/wrapper.out"
check 'a summary of a parse failure carries the result and no final text' json_is "$TMP/wrapper.out" \
  '.exit_code==3 and .result.status=="parse-failed" and .final_text==null and .final_truncated==false and .error==null'
check 'a summary of a parse failure carries the published result' same_result "$TMP/wrapper.out" "$RESULT"

for model_rc in 7 2 4; do
  fixture "SHIP — model exited $model_rc"
  run_review "$model_rc" TEST_REVIEW_RC="$model_rc"
  check "a summary after the model exited $model_rc is one document" one_document "$TMP/wrapper.out"
  check "a summary after the model exited $model_rc reports the invocation failure" json_is "$TMP/wrapper.out" \
    ".exit_code==$model_rc and .result.status==\"invocation-failed\" and .result.invocation_rc==$model_rc and .final_text==null and .error==null"
  check "a summary after the model exited $model_rc carries the published result" same_result "$TMP/wrapper.out" "$RESULT"
done

# A result that cannot be published: no result, and the step that failed.
fixture 'SHIP — summarized receipt failure'
write_rc=0
invoke DEV_TRIO_REVIEW_RECEIPT="$TMP/missing/receipt" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || write_rc=$?
LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
FINAL="${LOG%.log}.final.md"
check 'a summarized result-write failure keeps its exit code' test "$write_rc" -eq 2
check 'a summarized result-write failure is one document' one_document "$TMP/wrapper.out"
check 'a summarized result-write failure names the step and no result' json_is "$TMP/wrapper.out" \
  ".exit_code==2 and .result==null and .final_text==null and .final_truncated==false and .error==\"result-write-failed: publish receipt\" and .paths=={log: \"$LOG\", final: \"$FINAL\", result: null}"
check 'a summarized result-write failure still says so on stderr' grep -q 'result write failed: publish receipt' "$TMP/wrapper.err"

# A final past 64 KiB is not inlined, and the summary says so. The bound is
# inclusive: 65536 bytes are inlined, one more is not.
sized_fixture() {
  local size="$1" pad
  sized_frame() {
    printf '## Verdict\nSHIP — long\n\n## Findings\n\n### Blocker\n- None.\n\n### Major\n- None.\n\n### Minor / Nit\n- `long.txt:1` — '
    head -c "$1" /dev/zero | tr '\0' 'x'
    printf ' → shorten it.\n'
  }
  pad=$((size - $(sized_frame 0 | wc -c)))
  sized_frame "$pad" > "$TMP/review.md"
}
sized_fixture 65536
run_review 0
check 'the final at the bound is 65536 bytes' test "$(wc -c < "$FINAL" | tr -d ' ')" = 65536
check 'a summary with a final at the bound carries it byte for byte' same_final_text "$TMP/wrapper.out" "$FINAL"
check 'a summary with a final at the bound is not truncated' json_is "$TMP/wrapper.out" \
  '.exit_code==0 and .result.status=="ok" and .final_truncated==false'
sized_fixture 65537
run_review 0
check 'the long final is one byte over the bound' test "$(wc -c < "$FINAL" | tr -d ' ')" = 65537
check 'a summary with a long final leaves the text out and says so' json_is "$TMP/wrapper.out" \
  '.exit_code==0 and .result.status=="ok" and .final_text==null and .final_truncated==true'

# Control characters, quotes and a line that looks like a field stay inside the
# string value.
printf '## Verdict\nSHIP — "quoted" \033[31mred\033[0m\n\n## Findings\n\n### Blocker\n- None.\n\n### Major\n- None.\n\n### Minor / Nit\n- `a.sh:1` — "status": "ok", "exit_code": 9 } { here\r → none.\n' > "$TMP/review.md"
run_review 0
check 'a summary with control characters is still one document' one_document "$TMP/wrapper.out"
check 'a summary with control characters keeps the final byte for byte' same_final_text "$TMP/wrapper.out" "$FINAL"
check 'a field-shaped line in the final does not become a field' json_is "$TMP/wrapper.out" \
  '.exit_code==0 and (keys == ["error","exit_code","final_text","final_truncated","model","paths","result","summary_version"])'

# final_text is jq's reading of the final: a byte that is not UTF-8 arrives as
# U+FFFD, and the file keeps the byte.
# LC_ALL=C: under a UTF-8 locale macOS awk fails on that byte in the parser and
# the run ends as a result-write failure (exit 2, a summary with no result), so
# only the C locale gets an ok result to check.
printf '## Verdict\nSHIP — latin-1\n\n## Findings\n\n### Blocker\n- None.\n\n### Major\n- None.\n\n### Minor / Nit\n- `a.txt:1` — caf\351 → none.\n' > "$TMP/review.md"
run_review 0 LC_ALL=C
check 'a summary with a non-UTF-8 final is still one document' one_document "$TMP/wrapper.out"
check 'a non-UTF-8 byte in the final arrives as U+FFFD' json_is "$TMP/wrapper.out" \
  '.exit_code==0 and .result.status=="ok" and .final_truncated==false and (.final_text | endswith("— caf� → none.\n"))'
check 'the final file keeps the non-UTF-8 byte' \
  test "$(LC_ALL=C tr -cd '\351' < "$FINAL" | wc -c | tr -d ' ')" = 1

# Nobody reading stdout changes nothing: not the exit code, not the stderr, not
# the completion. The read end is closed before the wrapper starts — the reader
# closes its stdin and only then leaves the marker the writer waits for — so
# the write always meets a pipe with no reader.
stderr_norm() { sed -E 's/reviewer-[0-9]{8}-[0-9]{6}-[0-9]+/reviewer-STEM/g' "$1"; }
fixture 'SHIP — nobody reading'
run_review 0
stderr_norm "$TMP/wrapper.err" > "$TMP/read.err"
rm -f "$TMP/reader-closed"
pipe_rc=$(set +o pipefail
  {
    waited=0
    while [ ! -e "$TMP/reader-closed" ] && [ "$waited" -lt 150 ]; do sleep 0.2; waited=$((waited + 1)); done
    invoke 2> "$TMP/wrapper.err"
  } | { exec 0<&-; : > "$TMP/reader-closed"; }
  echo "${PIPESTATUS[0]}")
LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'the pipe had no reader before the wrapper started' test -e "$TMP/reader-closed"
check 'a summary to a pipe with no reader keeps the exit code' test "$pipe_rc" -eq 0
check 'a summary to a pipe with no reader writes the stderr of a read one' \
  eval 'stderr_norm "$TMP/wrapper.err" | cmp -s - "$TMP/read.err"'
check 'a summary to a pipe with no reader still completes the run' json_is "${LOG%.log}.run.json" '.completion.reason=="ok" and .completion.exit_code==0'
closed_rc=0
invoke >&- 2> "$TMP/wrapper.err" || closed_rc=$?
LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'a summary to a closed stdout keeps the exit code' test "$closed_rc" -eq 0
check 'a summary to a closed stdout writes the stderr of a read one' \
  eval 'stderr_norm "$TMP/wrapper.err" | cmp -s - "$TMP/read.err"'
check 'a summary to a closed stdout still completes the run' json_is "${LOG%.log}.run.json" '.completion.reason=="ok" and .completion.exit_code==0'

# A summary that cannot be rendered falls back to the fixed document; the exit
# code and the published result do not change.
REAL_JQ=$(command -v jq)
mkdir "$TMP/jq-shim"
cat > "$TMP/jq-shim/jq" <<SHIM
#!/bin/sh
case "\$*" in *summary_version*) exit 5 ;; esac
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$TMP/jq-shim/jq"
fixture 'SHIP — unrenderable summary'
run_review 0 PATH="$TMP/jq-shim:$PATH"
fixed_summary() {
  printf '%s\n' '{"summary_version":1,"exit_code":'"${1:-0}"',"result":null,"final_text":null,"error":"summary-unavailable"}' \
    | cmp -s - "$TMP/wrapper.out"
}
check 'an unrenderable summary is the fixed document, byte for byte' fixed_summary
check 'an unrenderable summary leaves the result published' json_is "$RESULT" '.status=="ok" and .verdict=="SHIP"'

# An ok result whose final stopped being a regular file after it was parsed —
# here a FIFO nobody writes to — is checked before it is read: the summary is
# the fixed document and the run completes. The swap happens at the wrapper's
# read of the result status, which comes after the parse and before the
# summary. A wrapper that read the FIFO anyway would block, so a writer is kept
# ready to end that read; the fixed-document check then fails instead of the
# suite hanging.
mkdir "$TMP/jq-fifo"
cat > "$TMP/jq-fifo/jq" <<SHIM
#!/bin/sh
if [ "\$*" = '-r .status' ] && [ ! -e "$TMP/fifo-swapped" ]; then
  swapped="$TMP/log/review-test/\$(readlink "$TMP/log/review-test/latest-reviewer.final.md")"
  rm -f "\$swapped" && mkfifo "\$swapped" && printf '%s\n' "\$swapped" > "$TMP/fifo-swapped"
fi
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$TMP/jq-fifo/jq"
fixture 'SHIP — the final became a FIFO'
rm -f "$TMP/fifo-swapped"
fifo_rc=0
invoke PATH="$TMP/jq-fifo:$PATH" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" &
fifo_pid=$!
waited=0
while kill -0 "$fifo_pid" 2>/dev/null && [ "$waited" -lt 150 ]; do sleep 0.2; waited=$((waited + 1)); done
fifo_unblock=""
if kill -0 "$fifo_pid" 2>/dev/null && [ -s "$TMP/fifo-swapped" ]; then
  ( : > "$(cat "$TMP/fifo-swapped")" ) &
  fifo_unblock=$!
fi
wait "$fifo_pid" || fifo_rc=$?
[ -z "$fifo_unblock" ] || { kill "$fifo_unblock" 2>/dev/null || true; wait "$fifo_unblock" 2>/dev/null || true; }
LOG="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
check 'the final was swapped for a FIFO after the parse' test -p "${LOG%.log}.final.md"
check 'a summary whose final became a FIFO keeps the exit code' test "$fifo_rc" -eq 0
check 'a summary whose final became a FIFO is the fixed document' fixed_summary
check 'a summary whose final became a FIFO still completes the run' json_is "${LOG%.log}.run.json" '.completion.reason=="ok" and .completion.exit_code==0'
rm -f "${LOG%.log}.final.md"

# A wrapper code that is not an integer is not reported as one: the fixed
# document carries null. Only a result changed after it was published can do
# this, so the shim answers the wrapper's read of the exit code.
mkdir "$TMP/jq-code"
cat > "$TMP/jq-code/jq" <<SHIM
#!/bin/sh
if [ "\$*" = '-r .exit_code' ]; then cat > /dev/null; echo 7.5; exit 0; fi
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$TMP/jq-code/jq"
fixture 'SHIP — a fractional exit code'
invoke PATH="$TMP/jq-code:$PATH" > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || true
check 'a non-integer exit code is null in the fixed document' fixed_summary null

# Before the model call stdout stays empty: usage errors and setup failures.
for bad in '--summary=x' '--bogus'; do
  bad_rc=0
  env "${INVOKE_ENV[@]}" "$ROOT/dev-trio/bin/ask-reviewer.sh" --summary "$bad" 'fixture review' \
    > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || bad_rc=$?
  check "--summary with $bad is a usage error" test "$bad_rc" -eq 2
  check "--summary with $bad writes nothing on stdout" test ! -s "$TMP/wrapper.out"
done
bad_rc=0
env "${INVOKE_ENV[@]}" "$ROOT/dev-trio/bin/ask-reviewer.sh" --summary --with-spec "$TMP/no-such-spec.md" 'fixture review' \
  > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || bad_rc=$?
check 'a setup failure under --summary exits nonzero' test "$bad_rc" -ne 0
check 'a setup failure under --summary writes nothing on stdout' test ! -s "$TMP/wrapper.out"
help_lists_summary() { "$ROOT/dev-trio/bin/ask-reviewer.sh" --help | grep -q -- '--summary'; }
check '--help lists --summary' help_lists_summary

# The flag works in any position, like the others.
fixture 'SHIP — summary after the focus'
late_rc=0
env "${INVOKE_ENV[@]}" "$ROOT/dev-trio/bin/ask-reviewer.sh" 'fixture review' --summary \
  > "$TMP/wrapper.out" 2> "$TMP/wrapper.err" || late_rc=$?
check '--summary after the focus runs' test "$late_rc" -eq 0
check '--summary after the focus is a summary' json_is "$TMP/wrapper.out" '.summary_version==1 and .result.verdict=="SHIP"'

# A signal during the model call: no summary, as there is no replay.
fixture 'SHIP — summarized and interrupted'
rm -f "$TMP/sum-ready" "$TMP/sum-release"
set -m
env "${INVOKE_ENV[@]}" CODEX_CLI="$TMP/slow-reviewer" CLAUDE_CLI="$TMP/slow-reviewer" \
  SLOW_READY="$TMP/sum-ready" SLOW_RELEASE="$TMP/sum-release" \
  "$ROOT/dev-trio/bin/ask-reviewer.sh" --summary 'fixture review' \
  > "$TMP/sum-int.out" 2> "$TMP/sum-int.err" &
sum_pid=$!
waited=0
while [ ! -e "$TMP/sum-ready" ] && [ "$waited" -lt 150 ]; do sleep 0.2; waited=$((waited + 1)); done
check 'the summarized stub was running when signalled' test -e "$TMP/sum-ready"
kill -TERM -"$sum_pid" 2>/dev/null || kill -TERM "$sum_pid" 2>/dev/null || true
: > "$TMP/sum-release"
sum_rc=0
wait "$sum_pid" || sum_rc=$?
set +m
check 'an interrupted summarized run keeps the signal status' test "$sum_rc" -eq 143
check 'an interrupted summarized run writes nothing on stdout' test ! -s "$TMP/sum-int.out"
check 'an interrupted summarized run still names its artifacts' grep -q '^(log: .*, rc=143)$' "$TMP/sum-int.err"

# The out-of-band transcript is the only copy when the summary replaces the
# replay: it is kept after a published review too, and named once, on each of
# the three ways a run ends.
oob_summary_undo() {
  local log="$TMP/log/review-test/$(readlink "$TMP/log/review-test/latest-reviewer.log")"
  check "out-of-band swap was exercised ($1)" test -d "$log"
  rmdir "$log"
  mv "$log.saved" "$log"
}
oob_summary_kept() {
  local kept
  check "the out-of-band transcript is named once ($1)" test "$(grep -Ec 'the transcript is at |it is at ' "$2")" -eq 1
  kept=$(sed -En 's/.*(the transcript is at|it is at) //p' "$2" | tail -1)
  check "the out-of-band transcript is kept ($1)" test -s "$kept"
  check "the kept transcript holds the review ($1)" grep -q "$3" "$kept"
  rm -f "$kept"
}
fixture 'SHIP — summarized out of band'
rm -f "$TMP/swap-fired-s1"
oob_rc=0
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/oobs-release" LEAK_DONE="$TMP/oobs-done" LEAK_STREAM=stderr \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/swapshim:$PATH" \
  SWAP_SHIM_DIR="$TMP/log/review-test" SWAP_SHIM_FIRED="$TMP/swap-fired-s1" \
  > "$TMP/oobs.out" 2> "$TMP/oobs.err" || oob_rc=$?
: > "$TMP/oobs-release"
oob_summary_undo published
check 'a summarized out-of-band review is published' test "$oob_rc" -eq 0
check 'a summarized out-of-band review is one document' one_document "$TMP/oobs.out"
check 'a summarized out-of-band review is a summary' json_is "$TMP/oobs.out" '.exit_code==0 and .result.verdict=="SHIP"'
check 'the published out-of-band notice says why it is kept' grep -q 'does not replay it; it is at ' "$TMP/oobs.err"
oob_summary_kept published "$TMP/oobs.err" 'SHIP — summarized out of band'

fixture 'SHIP — summarized out of band, receipt failure'
rm -f "$TMP/swap-fired-s2"
oob_rc=0
invoke CODEX_CLI="$TMP/leaky-reviewer" CLAUDE_CLI="$TMP/leaky-reviewer" \
  LEAK_RELEASE="$TMP/oobs2-release" LEAK_DONE="$TMP/oobs2-done" LEAK_STREAM=stderr \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/swapshim:$PATH" \
  SWAP_SHIM_DIR="$TMP/log/review-test" SWAP_SHIM_FIRED="$TMP/swap-fired-s2" \
  DEV_TRIO_REVIEW_RECEIPT="$TMP/missing/receipt" \
  > "$TMP/oobs2.out" 2> "$TMP/oobs2.err" || oob_rc=$?
: > "$TMP/oobs2-release"
oob_summary_undo result-write-failed
check 'a summarized out-of-band receipt failure exits 2' test "$oob_rc" -eq 2
check 'a summarized out-of-band receipt failure is one document' one_document "$TMP/oobs2.out"
check 'a summarized out-of-band receipt failure is a summary' json_is "$TMP/oobs2.out" '.error=="result-write-failed: publish receipt"'
oob_summary_kept result-write-failed "$TMP/oobs2.err" 'SHIP — summarized out of band, receipt failure'

fixture 'SHIP — summarized out of band, interrupted'
rm -f "$TMP/swap-fired-s3" "$TMP/oobs3-ready" "$TMP/oobs3-release"
set -m
env "${INVOKE_ENV[@]}" CODEX_CLI="$TMP/slow-reviewer" CLAUDE_CLI="$TMP/slow-reviewer" \
  SLOW_READY="$TMP/oobs3-ready" SLOW_RELEASE="$TMP/oobs3-release" \
  DEV_TRIO_REVIEWER_MODEL=claude PATH="$TMP/swapshim:$PATH" \
  SWAP_SHIM_DIR="$TMP/log/review-test" SWAP_SHIM_FIRED="$TMP/swap-fired-s3" \
  "$ROOT/dev-trio/bin/ask-reviewer.sh" --summary 'fixture review' \
  > "$TMP/oobs3.out" 2> "$TMP/oobs3.err" &
oobs3_pid=$!
waited=0
while [ ! -e "$TMP/oobs3-ready" ] && [ "$waited" -lt 150 ]; do sleep 0.2; waited=$((waited + 1)); done
oobs3_ready=0
[ ! -e "$TMP/oobs3-ready" ] || oobs3_ready=1
kill -TERM -"$oobs3_pid" 2>/dev/null || kill -TERM "$oobs3_pid" 2>/dev/null || true
: > "$TMP/oobs3-release"
oobs3_rc=0
wait "$oobs3_pid" || oobs3_rc=$?
set +m
check 'the summarized out-of-band stub was running when signalled' test "$oobs3_ready" -eq 1
oob_summary_undo interrupted
check 'a summarized out-of-band interruption keeps the signal status' test "$oobs3_rc" -eq 143
check 'a summarized out-of-band interruption writes nothing on stdout' test ! -s "$TMP/oobs3.out"
oob_summary_kept interrupted "$TMP/oobs3.err" 'SHIP — summarized out of band, interrupted'
INVOKE_ARGS=()

# Ten fixture runs — two models; a parsed review, a parse failure, a model that
# exits 7, a receipt, a receipt that cannot be written — each compared after
# run stems, plugin roots and mktemp suffixes are normalized.
# With --summary the exit code, stderr and receipt are what the same run writes
# without it. Without --summary nothing changed: stdout, stderr, exit code and
# receipt are what the base's wrapper writes. The base is chosen as
# scripts/check-version-bump.py chooses it, and that half only means something
# while the base has no --summary, so after this lands it skips.
printf '## Verdict\nNEEDS-FIX — one\n\n## Findings\n\n### Blocker\n- None.\n\n### Major\n- `a.sh:1` — broken → fix.\n\n### Minor / Nit\n- None.\n' > "$TMP/compat-ok.md"
printf 'Just prose, with no Verdict heading.\n' > "$TMP/compat-bad.md"
compat_norm() {
  sed -E -e 's/reviewer-[0-9]{8}-[0-9]{6}-[0-9]+/reviewer-STEM/g' \
    -e 's#\.tmp\.[A-Za-z0-9]{6}#.tmp.RAND#g' -e 's#review-receipt\.[A-Za-z0-9]{6}#review-receipt.RAND#g' \
    -e "s#$TMP/compat-old/dev-trio#ROOT#g" -e "s#$ROOT/dev-trio#ROOT#g" \
    -e "s#$TMP/compat-(old|new|summary)-side#SIDE#g" "$1"
}
# compat_run SIDE WRAPPER_ROOT MODEL CASE [wrapper option]
compat_run() {
  local side="$1" side_root="$2" model="$3" compat_case="$4" side_dir side_rc=0
  local review_file="$TMP/compat-ok.md" compat_receipt="" compat_env
  shift 4
  side_dir="$TMP/compat-$side-side"
  rm -rf "$side_dir"
  mkdir -p "$side_dir"
  compat_env=(DEV_TRIO_REVIEWER_MODEL="$model")
  case "$compat_case" in
    bad) review_file="$TMP/compat-bad.md" ;;
    rc7) compat_env+=(TEST_REVIEW_RC=7) ;;
    receipt) compat_receipt=$(review_receipt_create "$side_dir/receipt"); compat_env+=(DEV_TRIO_REVIEW_RECEIPT="$compat_receipt") ;;
    receipt-missing) compat_env+=(DEV_TRIO_REVIEW_RECEIPT="$side_dir/missing/receipt") ;;
  esac
  env "${INVOKE_ENV[@]}" TEST_REVIEW_FILE="$review_file" DEV_TRIO_LOG_DIR="$TMP/compat-log" "${compat_env[@]}" \
    "$side_root/bin/ask-reviewer.sh" "$@" 'fixture review' > "$side_dir/out" 2> "$side_dir/err" < /dev/null || side_rc=$?
  echo "$side_rc" > "$TMP/compat-$side.rc"
  compat_norm "$side_dir/out" > "$TMP/compat-$side.out"
  compat_norm "$side_dir/err" > "$TMP/compat-$side.err"
  if [ -n "$compat_receipt" ]; then compat_norm "$compat_receipt" > "$TMP/compat-$side.receipt"; else : > "$TMP/compat-$side.receipt"; fi
}
compat_ref="${VERSION_BUMP_BASE:-origin/main}"
! printf '%s' "$compat_ref" | grep -Eqx '0+' || compat_ref=origin/main
compat_base=""
if compat_commit=$(git -C "$ROOT" rev-parse --verify --quiet "$compat_ref^{commit}" 2>/dev/null); then
  if [ "${VERSION_BUMP_DIRECT:-}" = true ]; then
    compat_base="$compat_commit"
  else
    compat_base=$(git -C "$ROOT" merge-base "$compat_commit" HEAD) || compat_base=""
  fi
fi
compat_old=""
if [ -z "$compat_base" ]; then
  [ "${CI:-}" != true ] || check "the no-flag comparison base resolves ($compat_ref)" false
  echo "note: no base for the no-flag comparison ($compat_ref); skipped" >&2
elif git -C "$ROOT" show "$compat_base:dev-trio/bin/ask-reviewer.sh" > "$TMP/compat-base-wrapper" \
     && grep -q -- '--summary' "$TMP/compat-base-wrapper"; then
  echo "note: the base's ask-reviewer.sh already has --summary; the no-flag comparison is skipped" >&2
else
  mkdir "$TMP/compat-old"
  git -C "$ROOT" archive "$compat_base" dev-trio | tar -x -C "$TMP/compat-old"
  compat_old="$TMP/compat-old/dev-trio"
fi
for model in codex claude; do
  for compat_case in ok bad rc7 receipt receipt-missing; do
    compat_run new "$ROOT/dev-trio" "$model" "$compat_case"
    compat_run summary "$ROOT/dev-trio" "$model" "$compat_case" --summary
    for part in rc err receipt; do
      check "with --summary, $part is what the run writes without it ($model, $compat_case)" \
        cmp -s "$TMP/compat-new.$part" "$TMP/compat-summary.$part"
    done
    [ -n "$compat_old" ] || continue
    compat_run old "$compat_old" "$model" "$compat_case"
    for part in rc out err receipt; do
      check "without --summary, $part is unchanged ($model, $compat_case)" cmp -s "$TMP/compat-old.$part" "$TMP/compat-new.$part"
    done
  done
done

printf 'review-result smoke: %s assertions passed\n' "$PASS"
