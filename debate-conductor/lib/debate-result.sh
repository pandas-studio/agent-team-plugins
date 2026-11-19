#!/usr/bin/env bash
# debate-result.sh — the receipt that binds a caller to one debate.sh run.
#
# A caller reserves a fresh, absolute receipt path for each dispatch and passes
# it as DEBATE_RECEIPT. It never parses stdout and never consults the
# `latest-debate` symlink to discover what its own invocation produced: that
# symlink is team-wide, so a debate started by anyone else between the run
# returning and the caller looking retargets it, and the caller then reads
# another run's verdict as its own. (dev-trio/lib/review-result.sh states the
# same rule for reviews; this is the debate half of it.)
#
# Schema, one object:
#
#   {"schema_version":1,
#    "debate_dir":"/abs/resolved/.../debate-20260918-120000",
#    "last_round":4, "critic_round":4, "critic_file":"round-4-crit-codex.md"}
#
#   debate_dir    resolved absolute path. A relative DEBATE_LOG_DIR leaves
#                 DEBATE_DIR relative, and the consumer runs from another cwd.
#   last_round    highest *completed* round, not the scheduled cap.
#   critic_round  last completed critic round, or null.
#   critic_file   that round's transcript, basename only, or null. Paired with
#                 critic_round: both null, or neither.
#
# The fields describe the **whole debate**, not one dispatch: a
# `--continue-from … -n 1` that runs a generator round still reports the critic
# round an earlier dispatch completed.
#
# Receipts are published on success only. Publication sits after the round loop,
# so a failed round never reaches it, and `on_signal` drops the EXIT trap before
# re-raising — a failure receipt would mean widening signal handling for nothing,
# since a caller must gate on the invocation's exit code anyway. It must: a
# signal arriving after an atomic publication can leave a receipt behind for an
# invocation that then exited nonzero.
#
# Requires jq (a hard dependency of the plugin through lib/registry.sh).

# debate_receipt_write RECEIPT DIR LAST_ROUND CRITIC_ROUND CRITIC_FILE
# Empty CRITIC_ROUND/CRITIC_FILE mean "no critic round completed" and are
# written as JSON null. Atomic: built in a temp file beside the receipt,
# validated through the same reader a consumer uses, then renamed into place.
debate_receipt_write() {
  local receipt="$1" dir="$2" last="$3" round="${4:-}" file="${5:-}" tmp
  case "$receipt" in
    /*) ;;
    *) echo "debate-result: receipt path must be absolute: $receipt" >&2; return 1 ;;
  esac
  tmp="$(mktemp "$receipt.tmp.XXXXXX")" || return 1
  if ! jq -n --arg dir "$dir" --arg file "$file" \
      --argjson last "$last" \
      --argjson round "${round:-null}" \
      '{schema_version: 1, debate_dir: $dir, last_round: $last,
        critic_round: $round,
        critic_file: (if $round == null then null else $file end)}' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Never publish a receipt this plugin's own reader would reject.
  if ! debate_receipt_read "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "debate-result: refusing to publish a receipt that fails validation" >&2
    return 1
  fi
  mv -f "$tmp" "$receipt" || { rm -f "$tmp"; return 1; }
}

# debate_receipt_read RECEIPT: echo the validated object, or fail.
#
# Strict, because this is the consumer's authoritative input. `has()` rather
# than ordinary field access: `.critic_round` cannot tell a missing key from an
# explicit null, and a receipt that simply forgot the field must not read as
# "no critic round completed".
#
# Every rule about the *text* of a path is checked inside jq, on the JSON
# string. A shell check would run on a value command substitution has already
# transformed — it strips trailing newlines and drops NUL bytes — so
# "round-2-crit.md\n" and "round-2-crit\u0000.md" would both arrive as the
# legitimate name and pass (measured).
#
# jq decodes before any of that runs, and it *replaces* malformed UTF-8 rather
# than refusing it: a raw 0xFF byte in a name becomes U+FFFD, and a receipt
# naming `round-2-crit-<0xFF>.md` was accepted whenever a file called
# `round-2-crit-<U+FFFD>.md` existed (measured). So the bytes are checked before
# jq sees them, and U+FFFD is rejected afterwards as well — a real path is not
# expected to carry the replacement character, and failing closed on one costs
# nothing.
debate_receipt_read() {
  local receipt="$1" data dir file round
  [ -f "$receipt" ] || return 1
  # Reject malformed UTF-8 in the file as a whole, before jq can paper over it.
  # iconv ships with glibc and with macOS; when it is absent the U+FFFD rule
  # below still covers the two fields that name a path.
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 < "$receipt" >/dev/null 2>&1 || return 1
  fi
  data="$(jq -sce '
    select(length == 1) | .[0] |
    select(type == "object") |
    select(has("schema_version") and has("debate_dir") and has("last_round")
           and has("critic_round") and has("critic_file")) |
    select(.schema_version == 1) |
    select(.debate_dir | type == "string" and startswith("/")
           and (explode | map(select(. < 32 or . == 127 or . == 65533)) | length == 0)) |
    select(.last_round | type == "number" and . > 0 and . == floor) |
    select((.critic_round == null and .critic_file == null)
           or ((.critic_round | type == "number" and . > 0 and . == floor
                and . % 2 == 0)
               and (.critic_file | type == "string" and (explode | map(select(. < 32 or . == 127 or . == 65533)) | length == 0))))
  ' "$receipt" 2>/dev/null)" || return 1
  [ -n "$data" ] || return 1

  dir="$(printf '%s\n' "$data" | jq -r '.debate_dir')" || return 1
  [ -d "$dir" ] || return 1

  round="$(printf '%s\n' "$data" | jq -r '.critic_round // ""')" || return 1
  if [ -n "$round" ]; then
    file="$(printf '%s\n' "$data" | jq -r '.critic_file')" || return 1
    # A basename, and only that: no directory part, and not a directory entry
    # that means somewhere else. `..` *inside* a name escapes nothing once no
    # slash is allowed, and a model id is caller-defined — rejecting it outright
    # refused `round-2-crit-critic..v2.md` after both rounds had completed, and
    # took debate.sh down with it (measured).
    case "$file" in
      ''|*/*|.|..) return 1 ;;
    esac
    # It must name this round's critic transcript, not an arbitrary file.
    case "$file" in
      "round-$round-crit.md"|"round-$round-crit-"*.md) ;;
      *) return 1 ;;
    esac
    # A regular file inside the debate directory. Not a symlink, which could
    # point out of it, and not a FIFO, which would hang a reader on open.
    [ -L "$dir/$file" ] && return 1
    [ -f "$dir/$file" ] || return 1
    [ -r "$dir/$file" ] || return 1
    [ "$round" -le "$(printf '%s\n' "$data" | jq -r '.last_round')" ] || return 1
  fi
  printf '%s\n' "$data"
}

# debate_receipt_field RECEIPT FIELD: one validated field, empty for null.
debate_receipt_field() {
  local data
  data="$(debate_receipt_read "$1")" || return 1
  printf '%s\n' "$data" | jq -r --arg f "$2" '.[$f] // "" | tostring'
}

# debate_critic_verdict FILE — print the critic's canonical verdict token
# (STRENGTHEN, RECONSIDER or OVERTURN), or nothing.
#
# critic.md makes `Verdict: TOKEN` the answer's last line, exactly that and
# nothing else, and this is the only reader of it: debate.sh's --until-converged
# and ralph-debate.sh both call it, so one transcript has one verdict. A line
# inside a code fence, indented, quoted or decorated is an example, and text in
# the `## Verdict` section is prose; neither is read as the verdict. The last
# canonical line wins. A leading round marker is skipped, and the Kimi print
# envelope (`• ` first lines, two-space continuations, trailing session notices)
# is unwrapped only when the whole answer has that shape — the rule
# dev-trio/lib/review-result.sh applies. Nothing printed means no verdict: the
# caller decides what that is (debate.sh: not converged; ralph-debate: UNKNOWN).
debate_critic_verdict() {
  [ -f "$1" ] || return 0
  awk '
    # Length of the run of character ch that s starts with.
    function run_of(s, ch,    n) { n = 0; while (substr(s, n + 1, 1) == ch) n++; return n }
    function read_line(line, candidate, ch, n) {
      candidate = line; sub(/^ ? ? ?/, "", candidate)
      if (fence != "") {
        # Only a run of the opening character, at least as long, closes it.
        if (line !~ /^    / && line !~ /^\t/ && substr(candidate, 1, 1) == fence) {
          n = run_of(candidate, fence)
          if (n >= fence_len && substr(candidate, n + 1) ~ /^[[:space:]]*$/) fence = ""
        }
        return
      }
      ch = substr(candidate, 1, 1)
      if (line !~ /^    / && line !~ /^\t/ && (ch == "`" || ch == "~") && run_of(candidate, ch) >= 3 &&
          !(ch == "`" && index(substr(candidate, run_of(candidate, ch) + 1), "`"))) {
        fence = ch
        fence_len = run_of(candidate, ch)
        return
      }
      if (line ~ /^Verdict: (STRENGTHEN|RECONSIDER|OVERTURN)[[:space:]]*$/) {
        v = line
        sub(/^Verdict: /, "", v)
        sub(/[[:space:]]*$/, "", v)
      }
    }
    {
      sub(/\r$/, "")
      if (NR == 1 && $0 ~ /^<!-- debate-round: /) next
      raw[++nraw] = $0
    }
    END {
      bullet = "• "
      for (i = 1; i <= nraw; i++) {
        r = raw[i]
        if (index(r, bullet) == 1) { in_block = 1; blocks++; kimi[++nkimi] = substr(r, length(bullet) + 1) }
        else if (r == "") { if (in_block) kimi[++nkimi] = "" }
        else if (in_block && substr(r, 1, 2) == "  ") kimi[++nkimi] = substr(r, 3)
        else if (r ~ /^(To resume this session: kimi -r [0-9a-f-]+|kimi version [0-9]|Warning: |Session ".*" was updated by another client; reloaded it\.|No sessions to continue under )/) continue
        else not_kimi = 1
      }
      if (!not_kimi && blocks > 0) { for (i = 1; i <= nkimi; i++) read_line(kimi[i]) }
      else { for (i = 1; i <= nraw; i++) read_line(raw[i]) }
      if (v != "") print v
    }
  ' "$1" 2>/dev/null
}
