#!/usr/bin/env bash
# ralph-debate.sh — wrap debate.sh (from the debate-conductor plugin) in a
# Ralph outer loop.
#
# Each outer iteration:
#   1. Pop one task (= one debate topic) from BACKLOG.md
#   2. Run debate.sh -n $ROUNDS "$topic"
#   3. Parse the LAST round's critic verdict:
#        STRENGTHEN  → log SHIP to fix_plan.md (proposal accepted as-is)
#        RECONSIDER  → re-queue to BACKLOG with note
#        OVERTURN    → log to fix_plan.md, do not re-queue (human attention)
#
# Note: this variant produces *text artifacts* (proposals + critiques), not
# code diffs. It does NOT auto-apply or auto-commit code.
#
# Usage:
#   ralph-debate.sh --max-iter N --backlog PATH [--rounds N] [--prompt PATH]
#                   [--fix-plan PATH] [--max-runtime SPEC] [--worktree]
#                   [--base-branch BR] [--dry-run]
#
# Prerequisites: debate-conductor plugin (debate.sh via DEBATE_CONDUCTOR_BIN, PATH or `claude plugin list`).
#
# Logs:
#   $RALPH_TRIO_WORKSPACE/log/<team>/ralph-debate-<TS>.log              per-run summary
#   $DEBATE_LOG_DIR/<team>/debate-<TS>/round-N-{gen,crit}[-MODEL].md    via debate.sh
#   (DEBATE_LOG_DIR defaults to $PWD/.debate-conductor/log)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$PLUGIN_ROOT/lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/plugin-deps.sh
. "$PLUGIN_ROOT/lib/plugin-deps.sh" || { echo "ralph-debate: failed to load lib/plugin-deps.sh" >&2; exit 2; }

MAX_ITER=""
MAX_RUNTIME_SPEC="0"
ROUNDS=3
BACKLOG_FILE=""
PROMPT_FILE=""
FIX_PLAN_FILE=""
USE_WORKTREE=0
BASE_BRANCH=""
NO_VALIDATE=0
MAX_DIFF_LINES=10000
DRY_RUN=0

usage() { sed -n '2,25p' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-iter)        MAX_ITER="$2"; shift 2 ;;
    --max-runtime)     MAX_RUNTIME_SPEC="$2"; shift 2 ;;
    --rounds)          ROUNDS="$2"; shift 2 ;;
    --backlog)         BACKLOG_FILE="$2"; shift 2 ;;
    --prompt)          PROMPT_FILE="$2"; shift 2 ;;
    --fix-plan)        FIX_PLAN_FILE="$2"; shift 2 ;;
    --worktree)        USE_WORKTREE=1; shift ;;
    --base-branch)     BASE_BRANCH="$2"; shift 2 ;;
    --no-validate)     NO_VALIDATE=1; shift ;;
    --max-diff-lines)  MAX_DIFF_LINES="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -z "$MAX_ITER" ]    && { echo "--max-iter is required" >&2; exit 2; }
[ -z "$BACKLOG_FILE" ] && { echo "--backlog is required" >&2; exit 2; }
[ -f "$BACKLOG_FILE" ] || { echo "BACKLOG not found: $BACKLOG_FILE" >&2; exit 2; }
BACKLOG_FILE="$(cd "$(dirname "$BACKLOG_FILE")" && pwd)/$(basename "$BACKLOG_FILE")"
# debate.sh reads the prompt from inside the worktree subshell (`cd "$WORK_DIR"`),
# so a relative --prompt must be anchored here, before any cd.
if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || { echo "PROMPT not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
fi

# Cross-plugin dependency check (skipped in dry-run; we don't actually invoke it).
# The shared receipt library doubles as the capability check: a debate-conductor
# too old to publish run receipts does not ship it. Probing the executable
# instead would miss a forwarding wrapper, and running a sample debate would tie
# detection to model configuration.
DEBATE_SH=""
if [ "$DRY_RUN" != "1" ]; then
  DEP_RC=0
  resolve_plugin_script DEBATE_CONDUCTOR_BIN debate-conductor@pandas-studio debate.sh || DEP_RC=$?
  [ "$DEP_RC" -eq 0 ] || { plugin_deps_error ralph-debate debate-conductor debate.sh DEBATE_CONDUCTOR_BIN "$DEP_RC"; exit 2; }
  DEBATE_SH="$RESOLVED_SCRIPT"
  DEBATE_BIN_DIR=$(dirname "$DEBATE_SH")
  # shellcheck source=/dev/null
  . "$DEBATE_BIN_DIR/../lib/debate-result.sh" 2>/dev/null || {
    echo "ERROR: update debate-conductor; shared debate-result.sh is required (looked in $DEBATE_BIN_DIR/../lib, debate.sh via $RESOLVED_SOURCE)" >&2
    exit 2
  }
  command -v debate_receipt_read >/dev/null 2>&1 || {
    echo "ERROR: update debate-conductor; debate-result.sh must define debate_receipt_read" >&2
    exit 2
  }
fi
[ "$ROUNDS" -lt 2 ] && { echo "--rounds must be >= 2 (need at least one critic round)" >&2; exit 2; }

if [ -z "$FIX_PLAN_FILE" ]; then
  FIX_PLAN_FILE="$(dirname "$BACKLOG_FILE")/fix_plan.md"
fi
[ -f "$FIX_PLAN_FILE" ] || cp "$PLUGIN_ROOT/prompts/fix_plan.md.template" "$FIX_PLAN_FILE"

ORIGINAL_DIR="$(pwd)"
if [ "$USE_WORKTREE" = "1" ]; then
  git -C "$ORIGINAL_DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "--worktree requires git repo" >&2; exit 2; }
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$(git -C "$ORIGINAL_DIR" rev-parse --abbrev-ref HEAD)"
fi

TEAM=$(detect_team) || exit 2
LOG_DIR=$(init_log_dir)
# The receipt each debate dispatch is bound to must be at an absolute path
# (debate.sh refuses a relative one), and $LOG_DIR is relative whenever
# RALPH_TRIO_WORKSPACE is. Resolved once, here in the parent shell, so it stays
# correct across the cd into a worktree.
LOG_DIR_ABS=$(cd "$LOG_DIR" && pwd -P) || { echo "ERROR: cannot resolve log dir $LOG_DIR" >&2; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
SUMMARY_LOG="$LOG_DIR/ralph-debate-$TS.log"
ln -sfn "ralph-debate-$TS.log" "$LOG_DIR/latest-ralph-debate.log"
ln -sfn "ralph-debate-$TS.log" "$LOG_DIR/latest-ralph.log"

# parse_runtime has already explained a bad spec on stderr.
MAX_RUNTIME_SECS=$(parse_runtime "$MAX_RUNTIME_SPEC") || exit 2
DEADLINE=$([ "$MAX_RUNTIME_SECS" -gt 0 ] && echo $(( $(date +%s) + MAX_RUNTIME_SECS )) || echo 0)

# debate.sh from the debate-conductor plugin writes to its own log root:
# $DEBATE_LOG_DIR (default $PWD/.debate-conductor/log) / $TEAM. We resolve the
# same path here so the transcripts of a --worktree run land in the workspace
# rather than in the throwaway worktree, where they would be discarded with it.
#
# Normalize to absolute path here, BEFORE any cd into a worktree: with
# --worktree the subshell `cd "$WORK_DIR"` would re-anchor a relative
# DEBATE_LOG_BASE to the worktree. The default value embeds $PWD so it's
# already absolute; this branch only kicks in when callers pass a relative
# DEBATE_LOG_DIR override. (Which debate dir *this* run produced comes from its
# receipt, not from this path — see the dispatch below.)
DEBATE_LOG_BASE="${DEBATE_LOG_DIR:-$PWD/.debate-conductor/log}"
case "$DEBATE_LOG_BASE" in
  /*) ;;  # already absolute
  *)  DEBATE_LOG_BASE="$PWD/$DEBATE_LOG_BASE" ;;
esac
DEBATE_TEAM_DIR="$DEBATE_LOG_BASE/$TEAM"

{
  echo "=== ralph-debate.sh @ $TS ==="
  echo "TEAM:            $TEAM"
  echo "BACKLOG:         $BACKLOG_FILE"
  echo "PROMPT:          ${PROMPT_FILE:-<none>}"
  echo "FIX_PLAN:        $FIX_PLAN_FILE"
  echo "ROUNDS:          $ROUNDS"
  echo "MAX_ITER:        $MAX_ITER"
  echo "MAX_RUNTIME:     $MAX_RUNTIME_SPEC ($MAX_RUNTIME_SECS sec)"
  echo "WORKTREE:        $USE_WORKTREE  (base=$BASE_BRANCH)"
  echo "DRY_RUN:         $DRY_RUN"
  echo "DEBATE_TEAM_DIR: $DEBATE_TEAM_DIR"
  echo
} | tee "$SUMMARY_LOG" >&2

trap 'ralph_log "interrupted (Ctrl-C). Last iter=$ITER. Summary: $SUMMARY_LOG"; exit 130' INT TERM

# Returns: STRENGTHEN / RECONSIDER / OVERTURN / (empty if neither found)
# Model-agnostic: prefers the canonical `Verdict: TOKEN` line that critic.md
# mandates as the final output line, then falls back to scanning the
# `## Verdict` section header. The canonical line is checked first because
# different models may format the section header inconsistently
# (e.g. `### Verdict`, `**Verdict**`, missing heading).
parse_critic_verdict() {
  local f="$1"
  awk '
    # Canonical line: matches `Verdict: STRENGTHEN`, `verdict: reconsider`, etc.
    # Allows leading whitespace and optional surrounding markdown emphasis.
    tolower($0) ~ /^[[:space:]]*\**[[:space:]]*verdict[[:space:]]*:[[:space:]]*(strengthen|reconsider|overturn)\**[[:space:]]*$/ {
      v = toupper($0)
      sub(/.*VERDICT[[:space:]]*:[[:space:]]*/, "", v)
      sub(/[^A-Z].*$/, "", v)
      canonical = v
      next
    }
    # Fallback: first token inside `## Verdict` section.
    /^#+[[:space:]]*Verdict/ { in_v = 1; next }
    in_v && /^#+[[:space:]]/  { in_v = 0 }
    in_v && !section_hit && /STRENGTHEN/ { section_hit = "STRENGTHEN" }
    in_v && !section_hit && /RECONSIDER/ { section_hit = "RECONSIDER" }
    in_v && !section_hit && /OVERTURN/   { section_hit = "OVERTURN" }
    END {
      if (canonical)   { print canonical }
      else if (section_hit) { print section_hit }
    }
  ' "$f" 2>/dev/null
}

ITER=0
COMPLETED=0
# --dry-run termination ceiling. --max-iter 0 (unlimited) combined with the
# synthetic-topic path below would otherwise run forever (no backlog drain,
# no completion promise on this variant). Count unchecked BACKLOG topics
# up front and stop after that many iters. 0 outside dry-run (unused).
if [ "$DRY_RUN" = "1" ]; then
  # See ralph-trio.sh for the rationale — grep -c rc=1 + "0" stdout +
  # `|| echo 0` produced a non-numeric "0\n0" that broke the cap on
  # empty / fully-checked BACKLOG and reintroduced the infinite loop.
  DRY_RUN_BACKLOG_COUNT=$(grep -E '^[[:space:]]*-[[:space:]]*\[[ ]\][[:space:]]+' "$BACKLOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
  case "$DRY_RUN_BACKLOG_COUNT" in *[!0-9]*|"") DRY_RUN_BACKLOG_COUNT=0 ;; esac
else
  DRY_RUN_BACKLOG_COUNT=0
fi
while :; do
  ITER=$((ITER + 1))
  if ! enforce_max_iter "$ITER" "$MAX_ITER"; then
    ralph_log "max-iter cap reached ($MAX_ITER). Stopping."
    echo "=== STOP (max-iter) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
    break
  fi
  if ! enforce_max_runtime "$DEADLINE"; then
    ralph_log "max-runtime deadline reached. Stopping."
    echo "=== STOP (max-runtime) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
    break
  fi

  if [ "$DRY_RUN" = "1" ]; then
    # Don't mutate the user's BACKLOG under --dry-run; synthesize a topic.
    # Cap iters at DRY_RUN_BACKLOG_COUNT so --max-iter 0 still terminates.
    if [ "$ITER" -gt "$DRY_RUN_BACKLOG_COUNT" ]; then
      ralph_log "dry-run: synthetic backlog drained ($DRY_RUN_BACKLOG_COUNT iters). Stopping."
      echo "=== STOP (dry-run-backlog-empty) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
      break
    fi
    TASK="(dry-run synthetic topic — iter $ITER)"
  else
    TASK=$(pop_top_task "$BACKLOG_FILE") || true
    if [ -z "$TASK" ]; then
      ralph_log "BACKLOG drained. Stopping."
      echo "=== STOP (backlog-empty) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
      break
    fi
  fi

  ralph_log "iter $ITER · topic: $TASK"
  printf '\n--- iter %d @ %s ---\n  topic: %s\n' "$ITER" "$(date +%H:%M:%S)" "$TASK" >> "$SUMMARY_LOG"

  WT=""
  WORK_DIR="$ORIGINAL_DIR"
  if [ "$USE_WORKTREE" = "1" ]; then
    if ! WT=$(with_worktree "$ITER" "$BASE_BRANCH"); then
      ralph_log "could not create the iter $ITER worktree. Stopping."
      # pop_top_task already marked the task done; put it back.
      [ "$DRY_RUN" = "1" ] || append_to_backlog "$BACKLOG_FILE" "$TASK"
      echo "=== STOP (worktree-failed) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
      WORKTREE_FAILED=1
      break
    fi
    WORK_DIR="$WT"
    export RALPH_WT_DIR="$WT"
    printf '  worktree: %s\n' "$WT" >> "$SUMMARY_LOG"
  fi

  # Run the debate
  if [ "$DRY_RUN" = "1" ]; then
    ralph_log "  [dry-run] would run: debate.sh -n $ROUNDS \"$TASK\""
    VERDICT="STRENGTHEN"
    DEBATE_DIR=""
  else
    # Pin DEBATE_LOG_DIR explicitly so it survives the cd into $WORK_DIR. Under
    # --worktree, $WORK_DIR is the throwaway worktree path — without this pin
    # debate.sh would default to $WORK_DIR/.debate-conductor/log and the whole
    # transcript would be discarded with the worktree.
    # One fresh receipt per dispatch, reserved in this shell before the call and
    # under Ralph's own durable log dir — never inside the disposable worktree,
    # and canonicalised because $LOG_DIR is relative when RALPH_TRIO_WORKSPACE
    # is. A receipt that cannot be reserved is not an UNKNOWN verdict: it means
    # this invocation has no way to report what it produced, so the run stops
    # before spending model calls, and the task goes back on the backlog.
    if ! DEBATE_RECEIPT=$(mktemp "$LOG_DIR_ABS/debate-receipt-$TS-iter-$ITER.XXXXXX"); then
      ralph_log "could not reserve a debate receipt under $LOG_DIR_ABS. Stopping."
      [ "$DRY_RUN" = "1" ] || append_to_backlog "$BACKLOG_FILE" "$TASK"
      [ -z "$WT" ] || merge_or_discard_worktree "$WT" "$ITER" 0 "$ORIGINAL_DIR" || true
      echo "=== STOP (receipt-failed) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
      WORKTREE_FAILED=1
      break
    fi
    DEBATE_RC=0
    if [ -n "$PROMPT_FILE" ]; then
      ( cd "$WORK_DIR" && AGENT_TEAM="$TEAM" DEBATE_LOG_DIR="$DEBATE_LOG_BASE" DEBATE_RECEIPT="$DEBATE_RECEIPT" "$DEBATE_SH" -n "$ROUNDS" "$TASK" "$PROMPT_FILE" >&2 ) || DEBATE_RC=$?
    else
      ( cd "$WORK_DIR" && AGENT_TEAM="$TEAM" DEBATE_LOG_DIR="$DEBATE_LOG_BASE" DEBATE_RECEIPT="$DEBATE_RECEIPT" "$DEBATE_SH" -n "$ROUNDS" "$TASK" >&2 ) || DEBATE_RC=$?
    fi
    # What this invocation produced comes from its own receipt, never from the
    # team-wide `latest-debate` symlink: any other debate started in the same
    # team between the call returning and this lookup retargets it, and the
    # verdict read would be another run's. The exit code still gates the read —
    # a signal after the receipt was published can leave one behind for an
    # invocation that then failed.
    # The receipt path goes in the summary next to the exit code, the debate dir
    # and the verdict: a receipt records what the *producer* published, not
    # whether this iteration accepted it, and only the parent log can say which.
    printf '  receipt:    %s (rc=%s)\n' "$DEBATE_RECEIPT" "$DEBATE_RC" >> "$SUMMARY_LOG"
    DEBATE_DIR=""
    LAST_CRIT=""
    if [ "$DEBATE_RC" -ne 0 ]; then
      ralph_log "  WARNING: debate.sh failed (rc=$DEBATE_RC) — not reading its receipt"
    elif ! RECEIPT_DATA=$(debate_receipt_read "$DEBATE_RECEIPT"); then
      ralph_log "  WARNING: debate.sh exited 0 but its receipt is missing or unusable ($DEBATE_RECEIPT)"
    else
      DEBATE_DIR=$(printf '%s\n' "$RECEIPT_DATA" | jq -r '.debate_dir')
      CRIT_FILE=$(printf '%s\n' "$RECEIPT_DATA" | jq -r '.critic_file // ""')
      [ -z "$CRIT_FILE" ] || LAST_CRIT="$DEBATE_DIR/$CRIT_FILE"
    fi
    # Reclaim an untouched reservation — and only that. A receipt with bytes in
    # it is kept whatever happened: when the producer exited 0 and the reader
    # still rejected it, its contents are the evidence of what went wrong, and a
    # complete receipt left by a run that was signalled after publication is a
    # true record of what the producer published. Best effort by nature: a
    # SIGKILL runs no cleanup at all, and the writer's own `.tmp.XXXXXX` can
    # outlive it too.
    [ -s "$DEBATE_RECEIPT" ] || rm -f "$DEBATE_RECEIPT"
    if [ -z "$DEBATE_DIR" ]; then
      VERDICT="UNKNOWN"
    else
      printf '  debate dir: %s\n' "$DEBATE_DIR" >> "$SUMMARY_LOG"
      if [ -n "$LAST_CRIT" ]; then
        printf '  last critic: %s\n' "$LAST_CRIT" >> "$SUMMARY_LOG"
        VERDICT=$(parse_critic_verdict "$LAST_CRIT")
        [ -z "$VERDICT" ] && VERDICT="UNKNOWN"
      else
        ralph_log "  no completed critic round in $DEBATE_DIR"
        VERDICT="UNKNOWN"
      fi
    fi
  fi

  printf '  verdict:  %s\n' "$VERDICT" >> "$SUMMARY_LOG"

  PASSED=0
  case "$VERDICT" in
    STRENGTHEN)
      PASSED=1
      printf '## iter %d · %s · STRENGTHEN\nTopic: %s\n%s\n\n' \
        "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" \
        "$([ -n "${DEBATE_DIR:-}" ] && echo "Transcript: $DEBATE_DIR" || echo "(no transcript dir)")" \
        >> "$FIX_PLAN_FILE"
      ;;
    RECONSIDER)
      append_to_backlog "$BACKLOG_FILE" "retry (iter $ITER RECONSIDER): $TASK"
      printf '## iter %d · %s · RECONSIDER (re-queued)\nTopic: %s\n%s\n\n' \
        "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" \
        "$([ -n "${DEBATE_DIR:-}" ] && echo "Transcript: $DEBATE_DIR" || echo "(no transcript dir)")" \
        >> "$FIX_PLAN_FILE"
      ;;
    OVERTURN)
      printf '## iter %d · %s · OVERTURN (human attention)\nTopic: %s\n%s\n\n' \
        "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" \
        "$([ -n "${DEBATE_DIR:-}" ] && echo "Transcript: $DEBATE_DIR" || echo "(no transcript dir)")" \
        >> "$FIX_PLAN_FILE"
      ;;
    *)
      printf '## iter %d · %s · UNKNOWN verdict\nTopic: %s\n\n' \
        "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" \
        >> "$FIX_PLAN_FILE"
      ;;
  esac

  if [ "$USE_WORKTREE" = "1" ]; then
    if [ "$PASSED" = "1" ] && [ "$NO_VALIDATE" = "0" ]; then
      VAL_LOG="$LOG_DIR/ralph-debate-$TS-iter-$ITER-validate.log"
      if ! pre_merge_validate "$WT" "$BASE_BRANCH" "$(worktree_branch "$WT" "$ITER")" "$MAX_DIFF_LINES" 2>"$VAL_LOG"; then
        ralph_log "  pre_merge_validate FAILED — discarding instead of merging"
        printf '  validate: BLOCKED (see %s)\n' "$VAL_LOG" >> "$SUMMARY_LOG"
        printf '## iter %d · %s · WORKTREE-VALIDATE-BLOCK\nTopic: %s\nValidate log: %s\n\n' \
          "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" "$VAL_LOG" >> "$FIX_PLAN_FILE"
        PASSED=0
      else
        printf '  validate: ok\n' >> "$SUMMARY_LOG"
      fi
    fi
    merge_or_discard_worktree "$WT" "$ITER" "$PASSED" "$ORIGINAL_DIR"
    MERGE_RC=$?
    OUTCOME=$([ "$PASSED" = "1" ] && echo merged || echo discarded)
    if [ "$MERGE_RC" = "0" ]; then
      printf '  worktree: %s\n' "$OUTCOME" >> "$SUMMARY_LOG"
    else
      if [ "$MERGE_RC" = "2" ]; then
        # The change landed (or was dropped); only the cleanup failed.
        BLOCK=WORKTREE-CLEANUP-BLOCK
        printf '  worktree: %s, but cleanup failed: %s\n' "$OUTCOME" "$WT" >> "$SUMMARY_LOG"
      else
        # Refused (worktree off its branch) or ff-merge failed: nothing landed.
        BLOCK=WORKTREE-MERGE-BLOCK
        printf '  worktree: PRESERVED (not merged or discarded: %s)\n' "$WT" >> "$SUMMARY_LOG"
      fi
      printf '## iter %d · %s · %s\nTask: %s\nWorktree: %s\n\n' \
        "$ITER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BLOCK" "$TASK" "$WT" >> "$FIX_PLAN_FILE"
      # Stop here: the next iteration would hit the same obstruction and
      # keep one more full worktree each time.
      ralph_log "worktree for iter $ITER needs attention (blocked). Stopping."
      echo "=== STOP (worktree-blocked) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
      WORKTREE_FAILED=1
      break
    fi
    unset RALPH_WT_DIR
  fi

  COMPLETED=$ITER

  if check_promise "$FIX_PLAN_FILE"; then
    ralph_log "completion promise found in $FIX_PLAN_FILE. Stopping."
    echo "=== STOP (promise) completed=$COMPLETED ===" >> "$SUMMARY_LOG"
    break
  fi
done

echo "=== ralph-debate done (completed=$COMPLETED) ===" | tee -a "$SUMMARY_LOG" >&2
echo "summary: $SUMMARY_LOG" >&2
# A worktree that could not be created, merged or discarded: don't report success.
if [ "${WORKTREE_FAILED:-0}" = "1" ]; then exit 1; fi
