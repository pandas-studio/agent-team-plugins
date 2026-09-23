#!/usr/bin/env bash
# agy-denial.sh — name what headless agy denied (#103).
#
# agy's print mode cannot prompt, so a tool call that no allow-rule covers is
# auto-denied. When that leaves the run with nothing to say, agy exits 0 and
# prints one notice on stderr ("jetski: no output produced — a tool required
# the "command" permission …") that names the permission kind but not the
# target. The target is in agy's own conversation record:
#
#   <agy-home>/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl
#
# one JSON object per line; a denial is {"status":"ERROR","error":"permission
# check failed for <kind> \"<target>\": …"} with the target quoted Go-style.
# The conversation id is read from the CLI log a wrapper pinned with
# --log-file (line "server.go:NNNN] Created conversation <id>").
#
# Everything here is best-effort diagnosis: missing or partly written files
# yield fewer lines, never an error, and callers must not let it change a
# run's outcome. The CLI log also carries the user's full allow list, so
# nothing here copies or prints it. Requires jq; Bash 3.2.

_AGY_DENIAL_UUID_RE='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
_AGY_DENIAL_NOTICE='jetski: no output produced'

# agy_denial_conversations CLI_LOG — each well-formed conversation id the log
# records, in order. Anything else on such a line (a path, "../x") is dropped
# before it can become part of a path.
agy_denial_conversations() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  sed -n 's/^.*server\.go:[0-9][0-9]*\] Created conversation \([^[:space:]]*\)[[:space:]]*$/\1/p' "$1" 2>/dev/null \
    | grep -E "$_AGY_DENIAL_UUID_RE" 2>/dev/null \
    | awk '!seen[$0]++'
  return 0
}

# agy_denial_targets AGY_HOME CLI_LOG — each denied target as the allow-rule it
# would need, "<kind>(<target>)", unique and in the order agy recorded them.
# A target that is not valid JSON once unquoted (Go's \x.. and \a escapes are
# not) is kept in its raw quoted form rather than dropping the rest. Control
# characters are removed: the target is text the model wrote.
agy_denial_targets() {
  local home="$1" log="$2" id transcript
  for id in $(agy_denial_conversations "$log"); do
    transcript="$home/brain/$id/.system_generated/logs/transcript_full.jsonl"
    [ -f "$transcript" ] && [ -r "$transcript" ] || continue
    jq -Rr '
      fromjson? | select(type == "object") | select(.status == "ERROR")
      | .error | select(type == "string")
      | capture("^permission check failed for (?<kind>[A-Za-z_]+) (?<q>\"([^\"\\\\]|\\\\.)*\")")?
      | .q as $q
      | "\(.kind)(\($q | try fromjson catch $q))"
      | gsub("[[:cntrl:]]"; "")
    ' "$transcript" 2>/dev/null || true
  done | awk '!seen[$0]++'
  return 0
}

# Both scanners below read their whole input. An early-exiting `grep -q` at
# the end of a pipeline gets its producer killed by SIGPIPE, and under the
# wrappers' pipefail that turned a match into 141 — or, negated, a mismatch
# into success (measured, bash 3.2.57, a notice followed by 200,000 lines).
#
# _agy_denial_scan: prints "<notices> <other non-blank lines>".
_agy_denial_scan() {
  awk -v notice="$_AGY_DENIAL_NOTICE" '
    index($0, notice) == 1 && /permission/ { n++; next }
    /[^[:space:]]/ { o++ }
    END { printf "%d %d\n", n, o }
  '
}

# agy_denial_notice_in FILE [OFFSET END] — rc 0 iff a line of FILE (or of its
# byte range OFFSET..END) is agy's headless no-output notice about a permission.
agy_denial_notice_in() {
  local file="$1" offset="${2:-}" end="${3:-}" counts
  [ -f "$file" ] && [ -r "$file" ] || return 1
  if [ -n "$offset" ] && [ -n "$end" ]; then
    [ "$end" -gt "$offset" ] || return 1
    # `head` stops at END and `tail` then dies of SIGPIPE, so this pipeline's
    # status is not the answer; the scanner's output, which saw the whole
    # range, is.
    counts="$(tail -c "+$((offset + 1))" "$file" 2>/dev/null \
      | head -c "$((end - offset))" 2>/dev/null | _agy_denial_scan)" || true
  else
    counts="$(_agy_denial_scan < "$file")" || return 1
  fi
  case "$counts" in [0-9]*" "[0-9]*) ;; *) return 1 ;; esac
  [ "${counts%% *}" -gt 0 ]
}

# agy_denial_notice_only FILE — rc 0 iff FILE has at least one such notice and
# no other non-blank line: the whole "answer" of a run that produced nothing.
agy_denial_notice_only() {
  local counts
  [ -f "$1" ] && [ -r "$1" ] || return 1
  counts="$(_agy_denial_scan < "$1")" || return 1
  [ "${counts%% *}" -gt 0 ] && [ "${counts##* }" -eq 0 ]
}

# agy_denial_describe TARGET — one line for a human. unsandboxed(...) rules
# grant nothing in agy 1.2.9, so that kind is not presented as a rule to add.
agy_denial_describe() {
  case "$1" in
    unsandboxed\(*) printf '%s (unsandboxed rules are ignored by agy 1.2.9; see the README step on them)\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
