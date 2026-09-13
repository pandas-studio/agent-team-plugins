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
    function emit(tag, value) { print tag "\t" value }
    function verdict(line, token, reason) {
      raw = line
      token = line
      sub(/[ .].*$/, "", token)
      if (token !~ /^(SHIP|NEEDS-FIX|DISCUSS)$/ && !(profile == "spec" && token == "OUT-OF-SCOPE")) {
        problem = "unknown or malformed verdict token"; return
      }
      reason = substr(line, length(token) + 1)
      if (reason ~ /^ — /) sub(/^ — /, "", reason)
      else if (reason ~ /^\. /) sub(/^\. /, "", reason)
      else { problem = "expected TOKEN — reason or TOKEN. reason"; return }
      if (reason !~ /[^[:space:]]/) { problem = "empty verdict reason"; return }
      parsed = token
    }
    {
      sub(/\r$/, "")
      line = $0
      # Fences may be indented up to three spaces. Only a matching closing
      # fence ends the block; quoted and indented examples are never candidates.
      if (fence != "") {
        candidate = line; sub(/^   ? ?/, "", candidate)
        if (substr(candidate, 1, 1) == fence) {
          marks = candidate; sub(/[^`~].*$/, "", marks)
          rest = substr(candidate, length(marks) + 1)
          if (length(marks) >= fence_len && marks !~ (fence == "`" ? "~" : "`") && rest ~ /^[[:space:]]*$/) fence = ""
        }
        next
      }
      if (line ~ /^    / || line ~ /^\t/ || line ~ /^ *> / || line ~ /^ *>$/) {
        if (pending) { pending = 0; problem = "verdict must immediately follow its heading" }
        next
      }
      candidate = line; sub(/^   ? ?/, "", candidate)
      if (candidate ~ /^```/ || candidate ~ /^~~~/) {
        if (pending) { pending = 0; problem = "verdict must immediately follow its heading" }
        fence = substr(candidate, 1, 1)
        marks = candidate; sub(/[^`~].*$/, "", marks)
        fence_len = length(marks)
        next
      }
      # Recognize Markdown-equivalent headings when detecting ambiguity, but
      # require the canonical spelling for a successful result. Otherwise a
      # second "## Verdict " could silently hide a conflicting verdict.
      if (line ~ /^ ? ? ?##[[:blank:]]+Verdict([[:blank:]]+#+)?[[:blank:]]*$/) {
        headings++; pending = 1; in_findings = 0; section = ""
        if (line != "## Verdict") problem = "noncanonical Verdict heading"
        next
      }
      if (pending) { pending = 0; verdict(line) }
      if (line == "## Findings") { in_findings = 1; section = ""; next }
      if (line ~ /^## /) { in_findings = 0; section = ""; next }
      if (!in_findings) next
      if (line ~ /^### /) {
        section = ""
        if (line == "### Blocker") section = "blocker"
        if (line == "### Major") section = "major"
        if (line == "### Minor" || line == "### Minor / Nit") section = "minor"
        if (section != "") emit("section", section)
        next
      }
      if (section != "" && line ~ /^- /) {
        if (tolower(line) ~ /^- none\.?$/ || line == "- 없음" || line == "- 없음.") next
        emit(section, line)
      }
    }
    END {
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
      (.status == "parse-failed" or .status == "invocation-failed") and
      .exit_code != 0 and .verdict == null and (.error | type == "string")
    end) |
    select(.findings | type == "object") |
    select(all(.findings.blocker, .findings.major, .findings.minor;
      . == null or (type == "array" and all(.[]; type == "string"))))
  ' "$1" 2>/dev/null
}
