#!/usr/bin/env bash
# selection.sh — team-wide debate selection. The JSON rename is the commit point; panes read
# sequence and directory from that one snapshot, never from two mutable files.
# latest-debate remains the compatibility link for callers choosing a debate.
# Requires bash 3.2 and jq (already required by the model registry).

# Set SELECTION_DIR and SELECTION_SEQ. An empty sequence means a legacy link.
# Return 1 for invalid state, 2 for an initial publication in progress, 3 for jq failure.
debate_selection_read() {
  local log_dir="$1" state="$1/latest-debate.json" snapshot jq_rc=0
  SELECTION_DIR=""
  SELECTION_SEQ=""
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -f "$state" ] && [ ! -L "$state" ] || return 1
    snapshot=$(jq -ers '
      select(length == 1) | .[0]
      | select(type == "object" and .v == 1)
      | select(.sequence | type == "number")
      | select(.sequence >= 1 and .sequence <= 9007199254740991
               and .sequence == (.sequence | floor))
      | select(.debate_dir | type == "string")
      | select(.debate_dir | startswith("/") and (test("[\u0000\r\n]") | not))
      | "\(.sequence | floor)\n\(.debate_dir)"
    ' "$state" 2>/dev/null) || jq_rc=$?
    if [ "$jq_rc" != 0 ]; then
      # Distinguish malformed data from an unavailable/broken executable.
      if [ "$jq_rc" = 126 ] || [ "$jq_rc" = 127 ]; then
        hash -r
        return 3
      fi
      jq -n 'null' >/dev/null 2>&1 || return 3
      return 1
    fi
    SELECTION_SEQ="${snapshot%%$'\n'*}"
    SELECTION_DIR="${snapshot#*$'\n'}"
  else
    # Do not sample the compatibility link halfway through the *first*
    # managed publication. Once JSON exists it is always authoritative.
    [ ! -L "$log_dir/.latest-debate.lock" ] && [ ! -e "$log_dir/.latest-debate.lock" ] || return 2
    SELECTION_DIR=$(cd "$log_dir/latest-debate" 2>/dev/null && pwd -P) || SELECTION_DIR=""
    [ ! -e "$state" ] && [ ! -L "$state" ] || return 2
    [ ! -L "$log_dir/.latest-debate.lock" ] && [ ! -e "$log_dir/.latest-debate.lock" ] || return 2
  fi
  return 0
}

# publish LOG_DIR DEBATE_DIR. A short, independently trapped subshell owns the
# team lock; the caller continues to hold its separate per-debate writer lock.
# Never reclaim a stranded lock automatically (even a dead parent may have a
# live child). An interrupted rename is resolved by reading the committed JSON.
debate_selection_publish() (
  # Subshell variables deliberately are not local: bash 3.2 unwinds a
  # function's local scope before running EXIT after an explicit exit.
  tmp=""
  old_link=""
  restore=0
  payload=""
  log_dir=$(cd "$1" && pwd -P) || exit 1
  dir=$(cd "$2" && pwd -P) || exit 1
  [ "${dir%/*}" = "$log_dir" ] || { echo "debate: selection must belong to $log_dir" >&2; exit 1; }
  state="$log_dir/latest-debate.json"
  latest="$log_dir/latest-debate"
  lock="$log_dir/.latest-debate.lock"
  target="${dir##*/}"
  owner="host=${HOSTNAME:-unknown} pid=$$ child=${BASHPID:-$$} run=$RANDOM$RANDOM"

  selection_cleanup() {
    local rc=$? committed=""
    trap '' INT TERM HUP
    if [ "$(readlink "$lock" 2>/dev/null || true)" = "$owner" ]; then
      if [ "$restore" = 1 ]; then
        committed=$(cat "$state" 2>/dev/null) || committed=""
        # A signal can arrive after mv succeeded but before the shell returned.
        if [ "$committed" != "$payload" ] || [ "$(readlink "$latest" 2>/dev/null || true)" != "$target" ]; then
          rollback_rc=0
          if [ -n "$old_link" ]; then
            ln -sfn "$old_link" "$latest" || rollback_rc=$?
          else
            rm -f "$latest" || rollback_rc=$?
          fi
          if [ "$rollback_rc" != 0 ]; then
            [ -z "$tmp" ] || rm -f "$tmp" || echo "debate: remove temporary snapshot after recovery: $tmp" >&2
            echo "debate: selection rollback failed; retained $lock for manual recovery" >&2
            return 1
          fi
        fi
      fi
      [ -z "$tmp" ] || rm -f "$tmp"
      rm -f "$lock"
    fi
    return "$rc"
  }
  trap 'selection_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  started=$SECONDS
  while :; do
    if [ ! -e "$lock" ] && [ ! -L "$lock" ] && ln -s "$owner" "$lock" 2>/dev/null; then break; fi
    if [ "$((SECONDS - started))" -ge 5 ]; then
      if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
        echo "debate: cannot create selection lock $lock" >&2
        exit 1
      fi
      printf 'debate: selection lock busy (%s): %s\n' "$(readlink "$lock" 2>/dev/null || echo unknown-owner)" "$lock" >&2
      printf 'debate: if its owner and all children have stopped, remove the lock and retry: rm -f -- %q\n' "$lock" >&2
      exit 2
    fi
    # A failed ln followed by an absent lock can mean the winner already
    # released it. Retry instead of mistaking that race for a permission error.
    sleep 0.1
  done

  # Read committed state under the lock. A missing JSON is a legacy baseline;
  # read its link directly because our own lock deliberately blocks readers.
  if [ -e "$latest" ] && [ ! -L "$latest" ]; then
    echo "debate: latest-debate is not a symlink: $latest" >&2
    exit 1
  fi
  if [ -L "$latest" ]; then old_link=$(readlink "$latest") || exit 1; fi
  if [ -e "$state" ] || [ -L "$state" ]; then
    snapshot_rc=0
    debate_selection_read "$log_dir" || snapshot_rc=$?
    [ "$snapshot_rc" != 3 ] || { echo "debate: jq unavailable or failed; restore jq and retry" >&2; exit 1; }
    [ "$snapshot_rc" = 0 ] || { echo "debate: invalid selection state: $state" >&2; exit 1; }
    seq="$SELECTION_SEQ"
    if [ "$SELECTION_DIR" != "$dir" ]; then
      [ "$seq" -lt 9007199254740991 ] || { echo "debate: selection sequence exhausted" >&2; exit 1; }
      seq=$((seq + 1))
    fi
  else
    seq=1
  fi
  payload=$(jq -cn --arg dir "$dir" --argjson seq "$seq" '{v:1,sequence:$seq,debate_dir:$dir}') || exit 1
  # Validate path encoding with the same constraints the reader applies.
  printf '%s\n' "$payload" | jq -e '.debate_dir | test("[\u0000\r\n]") | not' >/dev/null || exit 1
  tmp=$(mktemp "$log_dir/.latest-debate.json.XXXXXX") || exit 1
  # Match ordinary log artifacts while retaining restrictive caller umasks.
  printf -v snapshot_mode '%03o' "$((0666 & ~$(umask)))"
  chmod "$snapshot_mode" "$tmp" || exit 1
  printf '%s\n' "$payload" > "$tmp" || exit 1
  restore=1
  ln -sfn "$target" "$latest" || { echo "debate: cannot publish latest-debate" >&2; exit 1; }
  mv -f "$tmp" "$state" || { echo "debate: cannot commit selection state" >&2; exit 1; }
)
