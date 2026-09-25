#!/usr/bin/env bash
# runstate.sh — per-invocation run metadata for the dev-trio dashboard.
#
# The dashboard used to re-derive the model, the start time, the focus/query and
# the completion state by parsing the run log's `=== ... ===` framing. That
# framing is interleaved with untrusted text (a focus is written to the log
# *before* the wrapper's own `=== MODEL: ... ===` line), so any of those values
# could be forged by the text being reviewed. This lib publishes them instead,
# as a structured artifact the wrappers own.
#
# One file per invocation, beside the log: <log-without-.log>.run.json.
#
# Schema (schema_version=1):
#   {
#     schema_version: 1,
#     channel,          # log stream: "agy" | "codex". NEVER a model id: any CLI
#                       # can fill any role via the registry, so the channel
#                       # names the log family only.
#     wrapper,          # ask-researcher.sh | ask-reviewer.sh
#     variant,          # dev-trio-research | dev-trio-review
#     team,             # namespace dir the artifacts live in
#     run_stem,         # "codex-20260919-122406-48531"
#     started_at,       # ISO-8601 with offset
#     started_display,  # the TS stem, what the dashboard has always shown
#     pid,              # diagnostic only — no consumer may derive state from it
#     role,             # resolved role: researcher | reviewer
#     model,            # resolved model id from the registry
#     pm_host,          # claude | codex
#     nested,           # true when dispatched under MANIFEST_PARENT_TMP
#     log_path,         # absolute
#     final_path,       # absolute, or null
#     final_source,     # "native" | "stdout" | "none"
#     result_path,      # absolute *.review.json, or null (research has none)
#     inputs: [ { kind, value?, path?, bytes?, sha256? } ],
#                       # bytes + sha256 (from inputdigest=) stand in for a
#                       # text too large to keep here, e.g. a research context
#     completion: null | { ended_at, exit_code, verdict, reason }
#                       # reason: ok | failed | aborted | result-write-failed
#                       #       | final-write-failed
#   }
#
# Public API:
#   runstate_begin    <log_path> key=value ...
#   runstate_complete <log_path> exit_code=<n> [verdict=<v>] [reason=<r>]
#   runstate_published <log_path>     # rc=0 iff completion is already published
#   runstate_read     <run_json_path> # validating reader; prints the document
#   runstate_path     <log_path>      # echo the sidecar path
#
# Why not the RFC 0004 manifest: it is published only at manifest_finalize, so a
# live run has none; nested dispatches emit none by contract; it carries no exit
# code; and a research run has no *.review.json. This file is the live artifact
# and IS emitted for nested runs. The manifest stays the archival record.
#
# Best-effort contract: this is a UI artifact. Every write failure warns on
# stderr and returns nonzero, and callers are expected to ignore that rc — a
# dashboard sidecar must never change a wrapper's exit code or abort a review.
# That is the opposite of *.review.json, whose I/O failures are fatal.
#
# Mode 0600 keeps other users out. It does not defend against a same-user
# process that can rewrite these artifacts; nothing here authenticates a writer.
#
# Requires Bash 3.2, POSIX awk/sed and jq 1.6+.

if ! command -v jq >/dev/null 2>&1; then
  echo "runstate.sh: jq not found in PATH — required for run metadata" >&2
  return 1 2>/dev/null || exit 1
fi

RUNSTATE_SCHEMA_VERSION=1

_runstate_now_iso() {
  # ISO-8601 with timezone, portable across BSD (macOS) and GNU date.
  date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}

# runstate_path <log_path> — the sidecar path for a run log.
runstate_path() {
  local log_path="$1" dir base
  dir=$(dirname "$log_path")
  base=$(basename "$log_path")
  printf '%s/%s.run.json' "$dir" "${base%.log}"
}

# _runstate_publish <dst> <json> — atomic write, mode 0600.
_runstate_publish() {
  local dst="$1" json="$2" tmp
  tmp=$(mktemp "$dst.tmp.XXXXXX") || {
    echo "runstate: cannot create a temporary file next to $dst" >&2
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    echo "runstate: cannot write $tmp" >&2
    return 1
  fi
  # Reject directories (including symlinks to them); the check is best-effort
  # against a concurrent replacement before mv.
  if [ -d "$dst" ] || ! mv "$tmp" "$dst"; then
    rm -f "$tmp"
    echo "runstate: cannot publish $dst" >&2
    return 1
  fi
}

# _runstate_sha256 <string> — sha256 of the literal string, no newline added.
# Fails rather than printing a bad digest, with or without the caller's pipefail.
_runstate_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum) || return 1
  else
    out=$(printf '%s' "$1" | shasum -a 256) || return 1
  fi
  out="${out%% *}"
  [ "${#out}" -eq 64 ] || return 1
  printf '%s\n' "$out"
}

# _runstate_bytes <string> — its length in bytes, not characters.
_runstate_bytes() {
  local LC_ALL=C
  printf '%s\n' "${#1}"
}

# _runstate_input <key> <kind> <text> — one inputs[] element as compact JSON.
# Text reaches jq on stdin, never as an argument: a research context can exceed
# Linux's 128 KiB per-argument limit (#118). The here-string appends exactly
# one newline, which the filter drops.
_runstate_input() {
  local key="$1" kind="$2" text="$3" bytes sha
  case "$key" in
    input)
      jq -nc --arg kind "$kind" --rawfile raw /dev/stdin \
        '{kind: $kind, value: $raw[:-1]}' <<<"$text"
      ;;
    inputpath)
      jq -nc --arg kind "$kind" --arg path "$text" '{kind: $kind, path: $path}'
      ;;
    inputdigest)
      bytes=$(_runstate_bytes "$text") || return 1
      sha=$(_runstate_sha256 "$text") || return 1
      jq -nc --arg kind "$kind" --argjson bytes "$bytes" --arg sha256 "$sha" \
        '{kind: $kind, bytes: $bytes, sha256: $sha256}'
      ;;
  esac
}

# runstate_begin <log_path> key=value ...
#   Recognised keys: channel wrapper variant team run_stem started_display pid
#                    role model pm_host nested log_path final_path final_source
#                    result_path
#   Inputs are passed as repeated input=<kind>:<value> / inputpath=<kind>:<path>
#   so a caller can record the focus/query text and referenced files, or as
#   inputdigest=<kind>:<text> to record only the text's byte count and sha256
#   (the bytes the caller holds, e.g. a context before it goes into a prompt).
runstate_begin() {
  local log_path="${1:-}"
  shift || true
  if [ -z "$log_path" ]; then
    echo "runstate_begin: usage: runstate_begin <log_path> key=value ..." >&2
    return 2
  fi
  local channel="" wrapper="" variant="" team="" run_stem="" started_display=""
  local pid="" role="" model="" pm_host="" nested="false"
  local final_path="" final_source="none" result_path=""
  local inputs_lines="" element
  local arg k v kind rest
  for arg in "$@"; do
    k="${arg%%=*}"
    v="${arg#*=}"
    case "$k" in
      channel)         channel="$v" ;;
      wrapper)         wrapper="$v" ;;
      variant)         variant="$v" ;;
      team)            team="$v" ;;
      run_stem)        run_stem="$v" ;;
      started_display) started_display="$v" ;;
      pid)             pid="$v" ;;
      role)            role="$v" ;;
      model)           model="$v" ;;
      pm_host)         pm_host="$v" ;;
      nested)          nested="$v" ;;
      final_path)      final_path="$v" ;;
      final_source)    final_source="$v" ;;
      result_path)     result_path="$v" ;;
      input|inputpath|inputdigest)
        kind="${v%%:*}"
        rest="${v#*:}"
        element=$(_runstate_input "$k" "$kind" "$rest") || return 1
        inputs_lines="$inputs_lines$element
"
        ;;
      *) echo "runstate_begin: unknown key '$k'" >&2; return 2 ;;
    esac
  done
  local doc
  # The elements are slurped from stdin into the inputs array, so no input
  # travels as an argument here either (#118).
  doc=$(printf '%s' "$inputs_lines" | jq -s \
    --argjson schema_version "$RUNSTATE_SCHEMA_VERSION" \
    --arg channel "$channel" \
    --arg wrapper "$wrapper" \
    --arg variant "$variant" \
    --arg team "$team" \
    --arg run_stem "$run_stem" \
    --arg started_at "$(_runstate_now_iso)" \
    --arg started_display "$started_display" \
    --arg pid "$pid" \
    --arg role "$role" \
    --arg model "$model" \
    --arg pm_host "$pm_host" \
    --arg nested "$nested" \
    --arg log_path "$log_path" \
    --arg final_path "$final_path" \
    --arg final_source "$final_source" \
    --arg result_path "$result_path" \
    '{
       schema_version: $schema_version,
       channel: $channel,
       wrapper: $wrapper,
       variant: $variant,
       team: $team,
       run_stem: $run_stem,
       started_at: $started_at,
       started_display: $started_display,
       pid: ( if $pid == "" then null else ($pid | tonumber) end ),
       role: $role,
       model: $model,
       pm_host: $pm_host,
       nested: ( $nested == "true" ),
       log_path: $log_path,
       final_path:  ( if $final_path  == "" then null else $final_path  end ),
       final_source: $final_source,
       result_path: ( if $result_path == "" then null else $result_path end ),
       inputs: .,
       completion: null
     }') || {
    echo "runstate_begin: could not build run metadata for $log_path" >&2
    return 1
  }
  _runstate_publish "$(runstate_path "$log_path")" "$doc"
}

# runstate_published <log_path> — rc=0 iff a completion is already published.
# The EXIT-trap backstop uses this so it cannot overwrite a real completion.
runstate_published() {
  local dst
  dst=$(runstate_path "$1")
  [ -f "$dst" ] || return 1
  [ "$(jq -r 'if (.completion // null) == null then "no" else "yes" end' "$dst" 2>/dev/null)" = "yes" ]
}

# runstate_complete <log_path> exit_code=<n> [verdict=<v>] [reason=<r>]
#   Rewrites the same file atomically — no second .done sidecar. Idempotent.
runstate_complete() {
  local log_path="${1:-}"
  shift || true
  if [ -z "$log_path" ]; then
    echo "runstate_complete: usage: runstate_complete <log_path> exit_code=<n> ..." >&2
    return 2
  fi
  local exit_code="" verdict="" reason="ok"
  local arg k v
  for arg in "$@"; do
    k="${arg%%=*}"
    v="${arg#*=}"
    case "$k" in
      exit_code) exit_code="$v" ;;
      verdict)   verdict="$v" ;;
      reason)    reason="$v" ;;
      *) echo "runstate_complete: unknown key '$k'" >&2; return 2 ;;
    esac
  done
  case "$exit_code" in
    ''|*[!0-9]*) echo "runstate_complete: exit_code must be a non-negative integer: '$exit_code'" >&2; return 2 ;;
  esac
  local dst
  dst=$(runstate_path "$log_path")
  if runstate_published "$log_path"; then
    return 0
  fi
  if [ ! -f "$dst" ]; then
    echo "runstate_complete: no run metadata at $dst — nothing to complete" >&2
    return 1
  fi
  local doc
  doc=$(jq \
    --argjson exit_code "$exit_code" \
    --arg ended_at "$(_runstate_now_iso)" \
    --arg verdict "$verdict" \
    --arg reason "$reason" \
    '.completion = {
       ended_at: $ended_at,
       exit_code: $exit_code,
       verdict: ( if $verdict == "" then null else $verdict end ),
       reason: $reason
     }' "$dst" 2>/dev/null) || {
    echo "runstate_complete: could not update $dst" >&2
    return 1
  }
  _runstate_publish "$dst" "$doc"
}

# runstate_read <run_json_path>
#   Print the document iff it satisfies the schema, else print nothing and
#   return nonzero. A caller MUST treat a nonzero rc as "metadata unavailable"
#   and never fall back to parsing the log for the same values.
#
#   A caller that has to bound what it loads passes the path of its own bounded
#   copy, so the checks below run over exactly the bytes it accepted.
# Slurped so the whole document is one value: a second document appended after
# a valid one must not be readable as "the first one".
_RUNSTATE_READ_FILTER='
    select(length == 1)
    | .[0]
    | select(type == "object")
    | select(.schema_version == 1)
    | select((.channel | type) == "string" and (.channel == "agy" or .channel == "codex"))
    | select((.wrapper | type) == "string")
    | select((.team    | type) == "string")
    | select((.run_stem | type) == "string")
    | select((.started_display | type) == "string")
    | select((.role  | type) == "string")
    | select((.model | type) == "string")
    | select((.nested | type) == "boolean")
    | select((.log_path | type) == "string" and (.log_path | startswith("/")))
    | select(.final_path  == null or ((.final_path  | type) == "string" and (.final_path  | startswith("/"))))
    | select(.result_path == null or ((.result_path | type) == "string" and (.result_path | startswith("/"))))
    | select((.final_source | type) == "string")
    | select((.started_at | type) == "string")
    | select(.pid == null or (.pid | type) == "number")
    | select((.pm_host | type) == "string")
    | select((.variant | type) == "string")
    # Every element the dashboard may render must already be the right shape:
    # a frame is built from this document without re-checking it field by field.
    | select((.inputs | type) == "array")
    | select(.inputs | all(
        type == "object"
        and (.kind | type) == "string"
        and (if has("value") then (.value | type) == "string" else true end)
        and (if has("path")  then (.path  | type) == "string" else true end)
        and (if has("bytes") then
               (.bytes | type) == "number" and .bytes >= 0 and (.bytes | floor) == .bytes
             else true end)
        and (if has("sha256") then
               (.sha256 | type) == "string" and (.sha256 | length) == 64
               and (.sha256 | explode | all((. >= 48 and . <= 57) or (. >= 97 and . <= 102)))
             else true end)
      ))
    | select(has("completion"))
    | select(
        .completion == null
        or (
          (.completion | type) == "object"
          and (.completion.exit_code | type) == "number"
          and (.completion.exit_code | floor) == .completion.exit_code
          and (.completion.ended_at | type) == "string"
          and (.completion.reason | type) == "string"
          and (.completion.verdict == null or (.completion.verdict | type) == "string")
        )
      )
  '

runstate_read() {
  local src="${1:-}"
  [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ] || return 1
  jq -sce "$_RUNSTATE_READ_FILTER" "$src" 2>/dev/null
}
