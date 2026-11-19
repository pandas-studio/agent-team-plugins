#!/usr/bin/env bash
# One parser for a completed invocation's final response. Domain failures are
# JSON results (exit_code != 0); a nonzero function rc means an I/O/tool failure.
# Requires Bash 3.2, POSIX awk and jq. Never reads latest links or streamed logs.

_review_result_failure() {
  jq -n --arg status "$1" --arg error "$2" --argjson invocation_rc "$3" \
    --argjson exit_code "$4" --arg profile "$5" \
    '{schema_version: 1, profile: $profile, status: $status,
      invocation_rc: $invocation_rc, exit_code: $exit_code, error: $error,
      verdict: null, verdict_line: null,
      findings: {blocker: null, major: null, minor: null}}'
}

review_result_parse() {
  local final="$1" invocation_rc="$2" profile="${3:-default}"
  if [ "$invocation_rc" -ne 0 ]; then
    _review_result_failure invocation-failed 'reviewer invocation failed' "$invocation_rc" "$invocation_rc" "$profile"
    return
  fi
  if [ ! -f "$final" ] || [ ! -r "$final" ] || [ ! -s "$final" ]; then
    _review_result_failure parse-failed 'final response missing, unreadable or empty' 0 3 "$profile"
    return
  fi
  local records
  records=$(awk -v profile="$profile" '
    BEGIN { bullet = "• " }
    function emit(tag, value) { print tag "\t" value }
    function verdict(line, token, reason) {
      raw = line
      token = line
      sub(/[ .:].*$/, "", token)
      if (token !~ /^(SHIP|NEEDS-FIX|DISCUSS)$/ && !(profile == "spec" && token == "OUT-OF-SCOPE")) {
        problem = "unknown or malformed verdict token"; return
      }
      reason = substr(line, length(token) + 1)
      if (reason ~ /^ — /) sub(/^ — /, "", reason)
      else if (reason ~ /^\. /) sub(/^\. /, "", reason)
      else if (reason ~ /^: /) sub(/^: /, "", reason)
      else { problem = "expected TOKEN — reason, TOKEN. reason or TOKEN: reason"; return }
      if (reason !~ /[^[:space:]]/) { problem = "empty verdict reason"; return }
      parsed = token
    }
    # Length of the run of character ch that s starts with.
    function run_of(s, ch,    n) { n = 0; while (substr(s, n + 1, 1) == ch) n++; return n }
    # A finding is held until the next list item, heading or the end, so the
    # sub-items written under it can still join its line.
    function flush() {
      if (open_finding) emit(open_section, open_text)
      open_finding = 0
    }
    function parse_line(line, candidate, rest, content, n) {
      # Fences may be indented up to three spaces. A fence is sized by the run
      # of its opening character, and only a run of that character at least as
      # long ends it; quoted and indented examples are never candidates.
      if (fence != "") {
        if (line ~ /^    / || line ~ /^\t/) return
        candidate = line; sub(/^ ? ? ?/, "", candidate)
        if (substr(candidate, 1, 1) == fence) {
          n = run_of(candidate, fence)
          rest = substr(candidate, n + 1)
          if (n >= fence_len && rest ~ /^[[:space:]]*$/) fence = ""
        }
        return
      }
      if (line ~ /^    / || line ~ /^\t/ || line ~ /^ *> / || line ~ /^ *>$/) {
        if (pending) { pending = 0; problem = "verdict must immediately follow its heading" }
        return
      }
      candidate = line; sub(/^ ? ? ?/, "", candidate)
      if (candidate ~ /^```/ || candidate ~ /^~~~/) {
        if (pending) { pending = 0; problem = "verdict must immediately follow its heading" }
        fence = substr(candidate, 1, 1)
        fence_len = run_of(candidate, fence)
        if (fence == "`" && substr(candidate, fence_len + 1) ~ /`/) problem = "invalid backtick fence"
        return
      }
      # Recognize Markdown-equivalent headings when detecting ambiguity, but
      # require the canonical spelling for a successful result. Otherwise a
      # second "## Verdict " could silently hide a conflicting verdict.
      if (line ~ /^ ? ? ?##[[:blank:]]+Verdict([[:blank:]]+#+)?[[:blank:]]*$/) {
        flush()
        headings++; pending = 1; in_findings = 0; section = ""
        if (line != "## Verdict") problem = "noncanonical Verdict heading"
        return
      }
      if (pending) { pending = 0; verdict(line) }
      if (line == "## Findings") { flush(); in_findings = 1; section = ""; return }
      if (line ~ /^## /) { flush(); in_findings = 0; section = ""; return }
      if (!in_findings) return
      if (line ~ /^### /) {
        flush()
        section = ""
        if (line == "### Blocker") section = "blocker"
        if (line == "### Major") section = "major"
        if (line == "### Minor" || line == "### Minor / Nit") section = "minor"
        if (section != "") emit("section", section)
        return
      }
      # Any other heading, indented or deeper, ends the finding being folded:
      # an item under it is not detail of the finding above.
      if (candidate ~ /^#+([[:blank:]]|$)/) { flush(); return }
      if (section != "" && candidate ~ /^([-*+]|[0-9]+[.)])([[:blank:]]|$)/) {
        content = candidate
        sub(/^([-*+]|[0-9]+[.)])[[:blank:]]*/, "", content)
        if (content !~ /[^[:space:]]/) return
        # An item indented 1-3 spaces right under a finding is detail of that
        # finding (cases, fix options): it joins the line of that finding, so it is
        # neither lost nor counted as a finding of its own.
        if (candidate != line && open_finding) {
          open_text = open_text " " content
          return
        }
        # Anywhere else an indented or non-dash item fails rather than being
        # dropped or counted: the structured format requires column 0.
        if (candidate != line || candidate !~ /^- /) {
          problem = "noncanonical " section " finding bullet: use dash-space bullets at column 0"
          return
        }
        flush()
        # Remember each severity across repeated headings: an explicit empty
        # marker cannot coexist with a finding in the aggregated result.
        if (tolower(line) ~ /^- none\.?[[:space:]]*$/ || line ~ /^- 없음\.?[[:space:]]*$/) {
          empty[section] = 1
        } else {
          found[section] = 1
          open_finding = 1; open_section = section; open_text = line
        }
        if (empty[section] && found[section]) problem = "contradictory " section " findings: empty marker mixed with finding bullets"
      }
    }
    {
      sub(/\r$/, "")
      raw_lines[++nraw] = $0
    }
    END {
      # Kimi Code 2.3+ print mode (PromptBlockWriter) prefixes the first line
      # of each assistant block with "• " and every continuation line with two
      # spaces, followed by an optional "To resume this session: kimi -r ..."
      # hint on stderr. Unindent only when the entire transcript matches that
      # envelope so ordinary indented Markdown still fails closed.
      for (i = 1; i <= nraw; i++) {
        r = raw_lines[i]
        if (index(r, bullet) == 1) {
          in_kimi_block = 1
          kimi_blocks++
          kimi_lines[++nkimi] = substr(r, length(bullet) + 1)
        } else if (r == "") {
          if (in_kimi_block) kimi_lines[++nkimi] = ""
        } else if (in_kimi_block && substr(r, 1, 2) == "  ") {
          kimi_lines[++nkimi] = substr(r, 3)
        } else if (r ~ /^(To resume this session: kimi -r [0-9a-f-]+|kimi version [0-9]|Warning: |Session ".*" was updated by another client; reloaded it\.|No sessions to continue under )/) {
          continue
        } else {
          not_kimi = 1
        }
      }
      if (!not_kimi && kimi_blocks > 0) {
        for (i = 1; i <= nkimi; i++) parse_line(kimi_lines[i])
      } else {
        for (i = 1; i <= nraw; i++) parse_line(raw_lines[i])
      }
      flush()
      if (fence != "") problem = "unclosed code fence"
      if (headings == 0) problem = "missing Verdict heading"
      else if (headings != 1) problem = "duplicate Verdict headings"
      else if (pending) problem = "missing verdict line"
      if (problem != "" || parsed == "") emit("error", problem != "" ? problem : "missing verdict")
      else { emit("verdict", parsed); emit("verdict_line", raw) }
    }
  ' "$final") || return 1
  printf '%s\n' "$records" | jq -Rn --arg profile "$profile" '
    reduce inputs as $line (
      {schema_version: 1, profile: $profile, status: "ok", invocation_rc: 0,
       exit_code: 0, error: null, verdict: null, verdict_line: null,
       findings: {blocker: null, major: null, minor: null}};
      ($line | index("\t")) as $tab |
      ($line[:$tab]) as $tag | ($line[$tab+1:]) as $value |
      if $tag == "section" then .findings[$value] //= []
      elif ($tag == "blocker" or $tag == "major" or $tag == "minor") then .findings[$tag] += [$value]
      elif $tag == "error" then .error = $value
      else .[$tag] = $value end
    ) |
    if .error != null then
      .status = "parse-failed" | .exit_code = 3 | .verdict = null | .verdict_line = null |
      .findings = {blocker: null, major: null, minor: null}
    else . end'
}

# review_result_permission_denied PARSED_JSON [CONVERSATION_ID...] -- [TARGET...]
# Turn a parse-failed result into the headless-denial result (#103): agy
# auto-denied a tool and produced no review. The exit code stays 3 — callers
# see the same contract as a parse failure — and the status, the denied
# targets and agy's conversation ids say what happened. The parse error is
# kept in `error`. The caller decides *whether* this applies; see ask-reviewer.
review_result_permission_denied() {
  local parsed="$1" ids=() targets=() in_targets=0 arg
  shift
  for arg in "$@"; do
    if [ "$in_targets" -eq 0 ] && [ "$arg" = -- ]; then in_targets=1; continue; fi
    if [ "$in_targets" -eq 1 ]; then targets+=("$arg"); else ids+=("$arg"); fi
  done
  printf '%s\n' "$parsed" | jq -c \
    --argjson ids "$(printf '%s\n' ${ids[@]+"${ids[@]}"} | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson denied "$(printf '%s\n' ${targets[@]+"${targets[@]}"} | jq -Rsc 'split("\n") | map(select(length > 0))')" '
    .status = "permission-denied" | .exit_code = 3 | .invocation_rc = 0 |
    .verdict = null | .verdict_line = null |
    .findings = {blocker: null, major: null, minor: null} |
    .error = ("agy denied a tool in headless mode: " +
      (if ($denied | length) > 0 then ($denied | join(", ")) else "target unknown" end) +
      " (parse: " + (.error // "no review") + ")") |
    .denied = $denied | .conversation_ids = $ids'
}

# Consumers load one atomic JSON snapshot; malformed/old files are unavailable,
# never an invitation to infer a verdict from another artifact.
review_result_read() {
  jq -sce '
    select(length == 1) | .[0] |
    select(.schema_version == 1) |
    select(.profile == "default" or .profile == "spec") |
    select(.invocation_rc | type == "number") |
    select(.exit_code | type == "number") |
    select(if .status == "ok" then
      .invocation_rc == 0 and .exit_code == 0 and .error == null and
      (.verdict == "SHIP" or .verdict == "NEEDS-FIX" or .verdict == "DISCUSS" or
       (.profile == "spec" and .verdict == "OUT-OF-SCOPE")) and
      (.verdict_line | type == "string")
    else
      (.status == "parse-failed" or .status == "invocation-failed" or
       .status == "permission-denied") and
      .exit_code != 0 and .verdict == null and (.error | type == "string")
    end) |
    select(if .status == "permission-denied" then
      .exit_code == 3 and
      (.denied | type == "array" and all(.[]; type == "string")) and
      (.conversation_ids | type == "array" and all(.[]; type == "string"))
    else true end) |
    select(.findings | type == "object") |
    select(all(.findings.blocker, .findings.major, .findings.minor;
      . == null or (type == "array" and all(.[]; type == "string"))))
  ' "$1" 2>/dev/null
}

# A caller reserves a fresh, absolute receipt path for each dispatch. It never
# parses stdout or consults a latest symlink to discover this invocation.
review_receipt_create() {
  local directory
  directory=$(cd "$(dirname "$1")" && pwd -P) || return 1
  mktemp "$directory/review-receipt.XXXXXX"
}

review_receipt_write() {
  local receipt="$1" result="$2" final="$3" temporary
  temporary=$(mktemp "$receipt.tmp.XXXXXX") || return 1
  if ! jq -n --arg result "$result" --arg final "$final" \
    '{schema_version: 1, result_path: $result, final_path: $final}' > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! mv -f "$temporary" "$receipt"; then
    rm -f "$temporary"
    return 1
  fi
}

review_result_from_receipt() {
  local receipt="$1" wrapper_rc="$2" pointers result final data
  pointers=$(jq -sce '
    select(length == 1) | .[0] | select(.schema_version == 1) |
    select(.result_path | type == "string" and startswith("/")) |
    select(.final_path | type == "string" and startswith("/"))
  ' "$receipt" 2>/dev/null) || return 1
  result=$(printf '%s\n' "$pointers" | jq -r '.result_path') || return 1
  final=$(printf '%s\n' "$pointers" | jq -r '.final_path') || return 1
  data=$(review_result_read "$result") || return 1
  printf '%s\n' "$data" | jq -ce --argjson rc "$wrapper_rc" \
    --arg result "$result" --arg final "$final" '
      select(.exit_code == $rc) | . + {result_path: $result, final_path: $final}'
}
