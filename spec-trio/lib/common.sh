#!/usr/bin/env bash
# common.sh — shared helpers for spec-trio (and ralph-{solo,trio,debate,meta}.sh).
#
# Vendored from the ralph-trio plugin's canonical post-port common.sh
# (Antigravity-era; carries the commit_worktree_changes SHIP-durability fix).
# Re-sync with:  cp ../ralph-trio/lib/common.sh ./lib/common.sh
# then re-append the spec_workspace_root / spec_init_log_dir overrides at the
# bottom and restore this header. spec-trio carries its own snapshot so it has
# no cross-plugin sourcing dependency; tests/smoke-pr5.sh catches breakage on
# re-sync. Drift is acceptable — the workspace/team/promise/worktree helpers are
# a stable interface.
#
# Workspace-root note: spec-trio defaults to $PWD/.spec-trio (see
# spec_workspace_root at the bottom of this file). The ralph-trio variants that
# share this lib keep using $PWD/.ralph-trio. Both honor an explicit
# RALPH_TRIO_WORKSPACE / SPEC_TRIO_WORKSPACE env var if set.
#
# Usage from a bin/ script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   . "$PLUGIN_ROOT/lib/common.sh"
#
# Provides:
#   ralph_workspace_root       -> echo $RALPH_TRIO_WORKSPACE (default $PWD/.ralph-trio)
#   detect_team                -> echo team name
#   init_log_dir               -> create + echo log dir for current $TEAM
#   ralph_state_dir            -> echo state dir for current $TEAM
#   check_promise FILE         -> rc=0 if <promise>COMPLETE</promise> present
#   enforce_max_iter CUR MAX   -> rc=0 to continue, rc=1 if cap reached
#   parse_runtime SPEC         -> echo seconds (accepts 6h / 30m / 120s / 7200)
#   enforce_max_runtime DEADLINE_TS  -> rc=0 to continue, rc=1 if past deadline
#   with_worktree ITER BASE    -> echo new worktree path
#   merge_or_discard_worktree WT ITER PASSED_FLAG ORIGINAL_DIR
#   ralph_log MSG              -> stderr, prefixed with [ralph TS]

set -uo pipefail

_NAMESPACE_LIB="$PLUGIN_ROOT/lib/namespace.sh"
[ -f "$_NAMESPACE_LIB" ] || { echo "spec-trio: namespace.sh not found at $_NAMESPACE_LIB" >&2; return 1 2>/dev/null || exit 1; }
# shellcheck source=namespace.sh
. "$_NAMESPACE_LIB"
unset _NAMESPACE_LIB

# ralph_workspace_root — resolve the workspace artifact root.
#
# Plugin context: the plugin itself is installed read-only (under
# ~/.claude/plugins/...), so logs and state must live in the user's workspace.
# Default: $PWD/.ralph-trio (mirrors dev-trio's $PWD/.dev-trio).
# Override: set RALPH_TRIO_WORKSPACE to point anywhere else (e.g., on a fast
# disk for heavy worktree runs). Add .ralph-trio/ to .gitignore.
ralph_workspace_root() {
  echo "${RALPH_TRIO_WORKSPACE:-$PWD/.ralph-trio}"
}

# Team namespace — same priority used by .agents-dev/ and .agents-debate/ wrappers:
# $AGENT_TEAM env > tmux @team-name window option > tmux session name > "default"
#
# Defense: the team name flows directly into a filesystem path
# ($WORKSPACE/log/$TEAM, $WORKSPACE/state/$TEAM). We strip everything except
# [a-zA-Z0-9_-] to prevent path traversal (../../etc) and shell-special chars.
# A loud stderr warning fires when the sanitize actually changes the value, so
# typos / accidents don't fail silently.
detect_team() {
  agent_team_detect_team
}

# init_log_dir — requires TEAM in env. Echoes the workspace-scoped path.
init_log_dir() {
  : "${TEAM:?init_log_dir: TEAM not set}"
  local d
  d="$(ralph_workspace_root)/log/$TEAM"
  mkdir -p "$d"
  echo "$d"
}

# ralph_state_dir — requires TEAM in env. Echoes the workspace-scoped state dir.
ralph_state_dir() {
  : "${TEAM:?ralph_state_dir: TEAM not set}"
  local d
  d="$(ralph_workspace_root)/state/$TEAM"
  mkdir -p "$d"
  echo "$d"
}

# check_promise FILE — rc=0 if completion marker present.
check_promise() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q '<promise>COMPLETE</promise>' "$f"
}

# enforce_max_iter CUR MAX — rc=0 ok, rc=1 cap reached.
enforce_max_iter() {
  local cur="$1" max="$2"
  [ "$max" -le 0 ] && return 0   # 0 = unlimited
  [ "$cur" -le "$max" ]
}

# parse_runtime SPEC — accepts "6h", "30m", "120s", or bare integer (seconds).
parse_runtime() {
  local spec="$1"
  case "$spec" in
    *h) echo $(( ${spec%h} * 3600 )) ;;
    *m) echo $(( ${spec%m} * 60 )) ;;
    *s) echo "${spec%s}" ;;
    *)  echo "$spec" ;;
  esac
}

# enforce_max_runtime DEADLINE_TS — rc=0 ok, rc=1 past deadline.
# Caller computes DEADLINE_TS = $(date +%s) + parsed seconds at start.
enforce_max_runtime() {
  local deadline="$1"
  [ "$deadline" -le 0 ] && return 0   # 0 = unlimited
  [ "$(date +%s)" -lt "$deadline" ]
}

# with_worktree ITER BASE — creates /tmp/ralph-${TEAM}-iter-${ITER} on a new
# branch ralph/${TEAM}-iter-${ITER} from BASE, echoes the worktree path.
# Caller must `cd` into it.
with_worktree() {
  local iter="$1" base="$2"
  : "${TEAM:?with_worktree: TEAM not set}"
  local wt="/tmp/ralph-${TEAM}-iter-${iter}"
  local br="ralph/${TEAM}-iter-${iter}"
  if [ -d "$wt" ]; then
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
  git branch -D "$br" 2>/dev/null || true
  git worktree add -b "$br" "$wt" "$base" >&2
  echo "$wt"
}

# commit_worktree_changes WT ITER — stage+commit any uncommitted worktree edits
# onto the current iteration branch. The coder may leave its changes uncommitted
# in the working tree (the reviewer inspects `git diff HEAD`), so a SHIP verdict
# approves the working-tree state, not just committed history. Committing here —
# BEFORE pre_merge_validate and the ff-merge — ensures those reviewed changes are
# (a) covered by validation's `base...HEAD` diff and (b) preserved by the
# ff-merge, instead of being silently destroyed by the post-merge
# `git worktree remove --force`. No-op when the tree is clean (coder committed
# normally). An explicit ralph identity keeps the commit working even when git
# user.* is unconfigured (e.g. CI / fresh checkout).
commit_worktree_changes() {
  local wt="$1" iter="$2"
  [ -d "$wt" ] || return 0
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 0
  git -C "$wt" add -A >&2 || { ralph_log "ERROR: git add -A failed in worktree (iter $iter); preserving worktree"; return 1; }
  git -C "$wt" -c user.name='ralph' -c user.email='ralph@localhost' \
    commit --no-verify -m "ralph iter ${iter}: coder changes (auto-committed at SHIP)" >&2 \
    || { ralph_log "ERROR: failed to auto-commit worktree changes (iter $iter); preserving worktree"; return 1; }
}

# merge_or_discard_worktree WT ITER PASSED_FLAG ORIGINAL_DIR
# PASSED_FLAG=1 → fast-forward merge into ORIGINAL_DIR's current HEAD; remove worktree.
# PASSED_FLAG=0 → leave branch deleted, remove worktree.
merge_or_discard_worktree() {
  local wt="$1" iter="$2" passed="$3" orig="$4"
  : "${TEAM:?merge_or_discard_worktree: TEAM not set}"
  local br="ralph/${TEAM}-iter-${iter}"
  if [ "$passed" = "1" ]; then
    if ! git -C "$orig" merge --ff-only "$br" >&2; then
      ralph_log "merge --ff-only failed for $br; leaving branch in place for inspection"
      git worktree remove --force "$wt" 2>/dev/null || true
      return 1
    fi
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
  if [ "$passed" != "1" ]; then
    git -C "$orig" branch -D "$br" 2>/dev/null || true
  fi
}

# ralph_log MSG — stderr with [ralph TS] prefix.
ralph_log() {
  printf '[ralph %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

# pop_top_task BACKLOG_FILE — echoes the first unchecked task line ("- [ ] ...")
# and rewrites the file with that line marked done ("- [x] ..."). Empty echo +
# rc=1 if no pending task remains.
pop_top_task() {
  local f="$1"
  [ -f "$f" ] || { return 1; }
  local task
  task=$(grep -nE '^[[:space:]]*-[[:space:]]*\[[ ]\][[:space:]]+' "$f" | head -1) || true
  [ -z "$task" ] && return 1
  local lineno text
  lineno="${task%%:*}"
  text="${task#*:}"
  # mark as done in-place
  awk -v ln="$lineno" 'NR==ln { sub(/\[ \]/, "[x]"); } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  # strip leading "- [ ] " from text for caller convenience
  echo "$text" | sed -E 's/^[[:space:]]*-[[:space:]]*\[[ x]\][[:space:]]+//'
}

# append_to_backlog FILE LINE — adds a new pending task to the bottom.
append_to_backlog() {
  local f="$1" line="$2"
  printf -- '- [ ] %s\n' "$line" >> "$f"
}

# build_fix_plan_excerpt FILE [TAIL_LINES] — echoes the last TAIL_LINES of
# fix_plan.md with literal closing-tag stripped, ready to be inlined into a
# prompt inside <fix_plan_md> tags. Default tail = 200 lines.
#
# Why an excerpt rather than the whole file: fix_plan grows unboundedly as
# iterations accumulate; injecting the full file every iter blows the context
# window. The agent can still Read the full file via tools if needed — the
# injection just provides a trusted recent-history view.
build_fix_plan_excerpt() {
  local f="$1" tail_lines="${2:-200}"
  [ -f "$f" ] || { echo ""; return 0; }
  local body
  body=$(tail -n "$tail_lines" "$f")
  # Strip our own closing fence so untrusted fix_plan content (possibly written
  # by a prior compromised iteration) can't escape <fix_plan_md> boundary.
  body="${body//<\/fix_plan_md>/[STRIPPED-CLOSING-TAG]}"
  echo "$body"
}

# pre_merge_validate WT BASE_BRANCH ITER_BRANCH MAX_DIFF_LINES
# Runs sanity checks on the worktree branch before fast-forward merging.
# rc=0 → safe to merge, rc=1 → block merge (caller should discard).
# Checks (each failure prints to stderr):
#   1. git diff --check         (whitespace errors, conflict markers)
#   2. forbidden pattern scan   (likely-secret strings introduced by the diff)
#   3. diff line count cap      (default MAX_DIFF_LINES=10000; override per call)
pre_merge_validate() {
  local wt="$1" base="$2" iter_branch="$3" max_lines="${4:-10000}"
  local fail=0

  # 1. whitespace / conflict marker check
  if ! git -C "$wt" diff --check "$base"...HEAD >/dev/null 2>&1; then
    ralph_log "  validate FAIL: git diff --check (whitespace errors or conflict markers)"
    git -C "$wt" diff --check "$base"...HEAD 2>&1 | sed 's/^/    /' >&2 || true
    fail=1
  fi

  # 2. diff size cap
  local n_lines
  n_lines=$(git -C "$wt" diff "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n_lines" -gt "$max_lines" ]; then
    ralph_log "  validate FAIL: diff is $n_lines lines (cap=$max_lines). Likely runaway iter; refusing merge."
    fail=1
  fi

  # 3. forbidden pattern scan (added lines only)
  # Pattern is intentionally narrow: looks for what *looks* like a secret being
  # introduced (added line containing one of these tokens followed by =/: and
  # a long-ish value). False positives are acceptable — operator can override.
  local sus
  sus=$(git -C "$wt" diff "$base"...HEAD 2>/dev/null \
    | grep -E '^\+' \
    | grep -iE '(api[_-]?key|secret[_-]?key|access[_-]?token|aws_secret|private[_-]?key|password)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_/+=-]{16,}' \
    || true)
  if [ -n "$sus" ]; then
    ralph_log "  validate FAIL: suspected secret added in diff:"
    echo "$sus" | head -5 | sed 's/^/    /' >&2
    fail=1
  fi

  return "$fail"
}

# sha256_file FILE — echo hex digest, portable across macOS/Linux.
sha256_file() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return 1; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "" ; return 1
  fi
}

# spec_workspace_root — spec-trio's workspace override, parallel to
# ralph_workspace_root. Default: $PWD/.spec-trio. Override: SPEC_TRIO_WORKSPACE.
# Kept as a separate function (rather than reshaping ralph_workspace_root) so
# ralph-* scripts that source this vendored copy continue to use .ralph-trio.
spec_workspace_root() {
  echo "${SPEC_TRIO_WORKSPACE:-$PWD/.spec-trio}"
}

# spec_init_log_dir — spec-trio variant of init_log_dir.
spec_init_log_dir() {
  : "${TEAM:?spec_init_log_dir: TEAM not set}"
  local d
  d="$(spec_workspace_root)/log/$TEAM"
  mkdir -p "$d"
  echo "$d"
}
