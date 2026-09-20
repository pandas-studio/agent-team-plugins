#!/usr/bin/env bash
# index.sh — the attempt ledger of a debate directory (`index.jsonl`).
#
# One JSON object per line, append-only, one writer (the #45 lock). Two kinds:
#
#   {"v":1,"t":"start","id":"…","round":1,"role":"gen","model":"agy","file":"round-1-gen.md","ts":"…"}
#   {"v":1,"t":"end","id":"…","round":1,"role":"gen","file":"round-1-gen.md","rc":0,"ts":"…"}
#
# `id` is the attempt id debate.sh already stamps into the `\x1e` frames of
# `stream-<role>.log`, so a row locates its own bytes and a retry of the same
# round and model is told apart. `end` repeats `round`, `role` and `file` so
# every query is a filter and never a join against `start`: a crash can destroy
# a `start` line, and a completed round must still read as completed.
#
# Two reader invariants preserve completion across interrupted writes:
#
#   1. Readers are idempotent under duplicate records. Every query is a max or
#      an any. Do not add a query that counts attempts or takes "the last end
#      record" literally — a duplicate would then become a wrong answer.
#   2. Readers tolerate a missing `start`. Completion is decided by `end`
#      records alone; a `start` with no `end` is an incomplete attempt, and its
#      round runs again.
#
# The ledger is the sole completion record. debate.sh refuses continuation
# when a legacy sidecar records a completion the ledger does not contain;
# sidecars are never used to advance the resume point or select a transcript.
#
# Sourced under errexit/pipefail. Completion readers tolerate missing and
# malformed records; predicates and the continuation gate must still return
# failure when their condition is not met.
#
# Every function takes the debate directory as $1 rather than reading a global:
# on the fresh-debate path the caller has no $DEBATE_DIR yet.

# debate_index_file DIR
debate_index_file() {
  printf '%s/index.jsonl' "$1"
}

# _index_completed_rounds DIR [ROLE]: round numbers with an rc=0 end record,
# one per line, unordered and possibly repeated. Empty ROLE means any role.
#
# `jq -R` reads each line as a string and `fromjson? // empty` drops the ones
# that do not parse — which is what makes a crash survivable: a torn final line
# and a malformed line left by an older crash are skipped rather than fatal.
# (`jq -s` and `jq -n '[inputs]'` abort outright on a torn tail. And the spaces
# in `fromjson? // empty` are load-bearing: `?//` is jq's alternative-
# destructuring operator, a compile error here.)
#
# The filter emits bare numbers, never an array: `-r` prints an array as
# multi-line JSON and the caller's `sort -n | tail -1` would return "4]".
# `select(type == "object")` guards a line that is valid JSON but a scalar, and
# the number/positive/integral test guards a round shell arithmetic cannot use.
_index_completed_rounds() {
  local idx
  idx="$(debate_index_file "$1")"
  [ -f "$idx" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -rRn --arg role "${2:-}" '
    inputs
    | (fromjson? // empty)
    | select(type == "object")
    | select(.t == "end" and .rc == 0)
    | select($role == "" or .role == $role)
    | .round
    | select(type == "number" and . > 0 and . == floor)
  ' "$idx" 2>/dev/null || true
  return 0
}

# last_completed_round_of_role DIR ROLE: highest completed round for that role,
# empty when there is none. Empty ROLE means any role.
last_completed_round_of_role() {
  _index_completed_rounds "$1" "${2:-}" \
    | sort -n | tail -1
  return 0
}

# last_completed_round DIR: highest completed round of the debate.
last_completed_round() {
  last_completed_round_of_role "$1" ""
  return 0
}

# round_is_complete DIR N: rc=0 iff round N completed. A predicate — it must be
# allowed to return non-zero.
#
# `grep -x … >/dev/null` rather than `grep -qx`: -q makes grep exit on the first
# match, the producers then take SIGPIPE, and `pipefail` returns 141 for a round
# that *is* complete. Measured on a ledger of 20000 records with 199 sidecars:
# every query returned 141; at 4000 records it did not reproduce, the output
# still fitting the pipe buffer. Redirecting instead keeps grep reading to EOF.
round_is_complete() {
  _index_completed_rounds "$1" "" \
    | grep -x -- "$2" >/dev/null
}

# completed_round_file DIR N ROLE: the transcript basename of round N's
# *successful* attempt for that role, empty when the round did not complete.
#
# From the ledger: the `end` records for that round and role with `rc == 0`,
# taking the recorded `file` — never the current model settings, never a failed
# attempt's record, and with no ordering assumption ("the latest attempt") and
# no matching `start` required, since a crash can destroy one. Identical
# candidates are deduplicated; two *distinct* filenames for one completed round
# are ambiguous, and this guesses at neither.
completed_round_file() {
  local dir="$1" round="$2" role="$3" idx names
  idx="$(debate_index_file "$dir")"
  if [ -f "$idx" ] && command -v jq >/dev/null 2>&1; then
    # The count is taken inside jq, on the deduplicated array: counting lines in
    # the shell would call two candidates unambiguous whenever one of them is a
    # newline. A name carrying a control character is not a filename at all.
    names="$(jq -rRn --arg role "$role" --argjson round "$round" '
      [ inputs
        | (fromjson? // empty)
        | select(type == "object")
        | select(.t == "end" and .rc == 0)
        | select(.round == $round and .role == $role)
        | .file
        | select(type == "string" and . != "" and (explode | map(select(. < 32 or . == 127 or . == 65533)) | length == 0))
      ] | unique
      | if length == 1 then .[0] elif length == 0 then empty else "\u0001" end
    ' "$idx" 2>/dev/null || true)"
    case "$names" in
      "$(printf '\001')") return 1 ;;   # two different filenames: ambiguous
      "") ;;
      *) printf '%s\n' "$names"; return 0 ;;
    esac
  fi
  return 0
}

# debate_index_can_continue DIR: compatibility gate, called under the writer
# lock before any transcript or metadata is changed. Sidecars are inspected
# only to refuse incomplete legacy histories, never as completion evidence.
# A partially indexed debate is just as unsafe as one with no ledger: even a
# single old completed round could otherwise be overwritten by the pre-touch.
debate_index_can_continue() {
  local dir="$1" idx f base n rest role completed
  idx="$(debate_index_file "$dir")"
  if [ ! -f "$idx" ] || [ ! -r "$idx" ] || ! jq -Rn 'inputs | empty' "$idx" >/dev/null 2>&1; then
    echo "debate: $dir needs a readable attempt ledger; start a fresh debate instead of continuing" >&2
    return 2
  fi
  for f in "$dir"/.round-*.done; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    rest="${base#.round-}"
    n="${rest%%-*}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt 0 ] || continue
    rest="${rest#"$n-"}"
    case "$rest" in
      gen.done|gen-*.done) role=gen ;;
      crit.done|crit-*.done) role=crit ;;
      *) continue ;;
    esac
    # Decimal normalization also accepts zero-padded legacy round numbers.
    completed="$(jq -rRn --arg n "$n" --arg role "$role" '
      any(inputs | (fromjson? // empty) | select(type == "object");
          .t == "end" and .rc == 0 and .round == ($n | tonumber) and .role == $role)
    ' "$idx" 2>/dev/null)" || return 2
    if [ "$completed" != true ]; then
      echo "debate: $base has no successful ledger record; start a fresh debate instead of continuing this legacy history" >&2
      return 2
    fi
  done
  return 0
}
