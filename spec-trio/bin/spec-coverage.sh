#!/usr/bin/env bash
# spec-coverage.sh — RFC 0003 PR 6 standalone coverage checker.
#
# Reads `### §5.N` Test-criteria subsections from a spec.md and classifies
# each one against the commits in a reference range:
#
#   COVERED      — at least one commit message contains the literal `§5.N`
#                  (mirrors the worker.md commit convention:
#                  `git commit -m "spec §N.M: <one-line summary>"`).
#   PARTIAL      — no `§5.N` citation, but the criterion heading's
#                  distinctive keyword(s) appear in some commit's message
#                  or diff. Useful for "did the work, forgot to cite".
#   NOT-COVERED  — neither.
#
# Usage:
#   spec-coverage.sh --spec PATH
#       [--since-ref REF]      # default: scan all reachable commits on HEAD
#       [--repo PATH]          # default: cwd
#       [--requeue BACKLOG]    # append NOT-COVERED criteria as new tasks
#       [--quiet]              # suppress progress lines (report only)
#       [--no-partial]         # skip the keyword pass; binary classify only
#       [--manifest-history DIR]  # roll up spec-review manifest verdicts per §5.N
#                                 # (RFC 0004 PR 5). DIR holds *.manifest.json files
#                                 # emitted by spec-trio. Time-agnostic: every
#                                 # manifest in DIR contributes regardless of when
#                                 # it was emitted (manifests are evidence-of-attempt;
#                                 # conflating with --since-ref's git range would
#                                 # silently drop runs that produced no commits).
#
# Exit codes:
#   0  ok (regardless of coverage outcome — coverage gaps don't fail the run)
#   2  usage error / missing spec / invalid since-ref / no §5.N criteria
#
# Standalone use:
#   spec-coverage.sh --spec spec.md --since-ref HEAD~10
#
# Driver use (called from spec-trio.sh --coverage-check):
#   spec-coverage.sh --spec spec.md --since-ref "$START_HEAD" \
#                    [--requeue BACKLOG.md]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$PLUGIN_ROOT/lib/spec-helpers.sh" ] || {
  echo "ERROR: $PLUGIN_ROOT/lib/spec-helpers.sh missing" >&2; exit 2; }
# shellcheck disable=SC1091
. "$PLUGIN_ROOT/lib/spec-helpers.sh"

SPEC=""
SINCE_REF=""
REPO="."
REQUEUE=""
QUIET=0
NO_PARTIAL=0
MANIFEST_HISTORY=""

usage() { sed -n '2,38p' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec)              SPEC="$2"; shift 2 ;;
    --since-ref)         SINCE_REF="$2"; shift 2 ;;
    --repo)              REPO="$2"; shift 2 ;;
    --requeue)           REQUEUE="$2"; shift 2 ;;
    --quiet)             QUIET=1; shift ;;
    --no-partial)        NO_PARTIAL=1; shift ;;
    --manifest-history)  MANIFEST_HISTORY="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -z "$SPEC" ] && { echo "--spec is required" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "spec not found: $SPEC" >&2; exit 2; }
[ -d "$REPO" ] || { echo "repo not a directory: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "repo is not a git repo: $REPO" >&2; exit 2; }
if [ -n "$SINCE_REF" ]; then
  git -C "$REPO" rev-parse --verify "$SINCE_REF" >/dev/null 2>&1 || {
    echo "since-ref does not resolve in $REPO: $SINCE_REF" >&2; exit 2; }
fi
if [ -n "$REQUEUE" ]; then
  [ -f "$REQUEUE" ] || { echo "requeue target not found: $REQUEUE" >&2; exit 2; }
fi
if [ -n "$MANIFEST_HISTORY" ]; then
  [ -d "$MANIFEST_HISTORY" ] || { echo "manifest-history not a directory: $MANIFEST_HISTORY" >&2; exit 2; }
fi

log() { [ "$QUIET" = "1" ] || printf '%s\n' "$*" >&2; }

# Build commit range. Empty SINCE_REF means "all of HEAD" — useful for
# auditing legacy work, but slow on large repos. The driver always
# provides --since-ref, so the slow path is opt-in.
if [ -n "$SINCE_REF" ]; then
  RANGE="$SINCE_REF..HEAD"
else
  RANGE=""
fi

CRITERIA="$(parse_test_criteria "$SPEC")"
if [ -z "$CRITERIA" ]; then
  echo "spec coverage: no §5.N criteria found in $SPEC" >&2
  echo "  (expected ### §5.1, ### §5.2, ... subsections under ## §5)" >&2
  exit 2
fi

log "spec coverage check"
log "  spec:      $SPEC"
log "  repo:      $(cd "$REPO" && pwd)"
log "  range:     ${RANGE:-<all reachable commits on HEAD>}"
log "  requeue:   ${REQUEUE:-<none>}"
log "  partial:   $([ "$NO_PARTIAL" = 1 ] && echo "off" || echo "on")"
log "  manifest:  ${MANIFEST_HISTORY:-<none>}"
log

# count_manifest_verdicts <id>
#   Echo "<ship>\t<needs-fix>\t<discuss>\t<oos>" — verdict tallies for each
#   spec-review manifest in $MANIFEST_HISTORY whose kind=task value cites $id.
#   Anchored regex (§5\.N(?![0-9])) prevents §5.3 from also matching §5.30.
#   Manifests with verdict=null (UNKNOWN reviewer / parse miss) are silently
#   dropped from the 4-bucket rollup — they're not evidence of any closed-vocab
#   outcome. RFC 0004 PR 5.
count_manifest_verdicts() {
  local id="$1"
  # id looks like §5.3 — extract the numeric suffix for regex anchoring
  local num="${id#§5.}"
  if [ -z "$(ls "$MANIFEST_HISTORY"/*.manifest.json 2>/dev/null)" ]; then
    printf '0\t0\t0\t0'
    return 0
  fi
  jq -rs --arg num "$num" '
    [ .[]
      | select(.variant == "spec-review")
      | select(
          [.inputs[]?
           | select(.kind == "task")
           | select((.value // "") | test("§5\\." + $num + "(?![0-9])"))
          ] | length > 0
        )
      | (.verdict // "null")
    ]
    | reduce .[] as $v ({}; .[$v] = (.[$v] // 0) + 1)
    | [(.SHIP // 0), (."NEEDS-FIX" // 0), (.DISCUSS // 0), (."OUT-OF-SCOPE" // 0)]
    | @tsv
  ' "$MANIFEST_HISTORY"/*.manifest.json 2>/dev/null || printf '0\t0\t0\t0'
}

# classify_one <id> <name>
#   stdout: <STATUS>\t<short shas (space-sep, may be empty)>
classify_one() {
  local id="$1" name="$2"
  local hits
  # Pass 1: literal §5.N in commit messages within range.
  if [ -n "$RANGE" ]; then
    hits="$(git -C "$REPO" log --format='%h' --fixed-strings --grep="$id" "$RANGE" 2>/dev/null)"
  else
    hits="$(git -C "$REPO" log --format='%h' --fixed-strings --grep="$id" 2>/dev/null)"
  fi
  if [ -n "$hits" ]; then
    printf 'COVERED\t%s\n' "$(printf '%s' "$hits" | tr '\n' ' ' | sed 's/ *$//')"
    return 0
  fi
  # Pass 2: keyword fallback for PARTIAL detection (skipped if --no-partial
  # or the criterion has no usable keywords).
  if [ "$NO_PARTIAL" = "1" ] || [ -z "$name" ]; then
    printf 'NOT-COVERED\t\n'; return 0
  fi
  local kws kw partial=""
  kws="$(criterion_keywords "$name")"
  [ -z "$kws" ] && { printf 'NOT-COVERED\t\n'; return 0; }
  for kw in $kws; do
    local m d
    if [ -n "$RANGE" ]; then
      m="$(git -C "$REPO" log --format='%h' --fixed-strings --grep="$kw" "$RANGE" 2>/dev/null)"
      d="$(git -C "$REPO" log --format='%h' -G"$kw" "$RANGE" 2>/dev/null)"
    else
      m="$(git -C "$REPO" log --format='%h' --fixed-strings --grep="$kw" 2>/dev/null)"
      d="$(git -C "$REPO" log --format='%h' -G"$kw" 2>/dev/null)"
    fi
    if [ -n "$m$d" ]; then
      partial="$(printf '%s\n%s\n' "$m" "$d" | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//')"
      break
    fi
  done
  if [ -n "$partial" ]; then
    printf 'PARTIAL\t%s\n' "$partial"
  else
    printf 'NOT-COVERED\t\n'
  fi
}

# Run classification, then render the report. Two passes so the report
# layout is fixed once we know how wide the longest id is.
RESULTS=""
MAX_ID_LEN=0
COUNT_COVERED=0
COUNT_PARTIAL=0
COUNT_MISSING=0
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  [ "${#id}" -gt "$MAX_ID_LEN" ] && MAX_ID_LEN=${#id}
  classified="$(classify_one "$id" "$name")"
  status="${classified%%$'\t'*}"
  shas="${classified#*$'\t'}"
  case "$status" in
    COVERED)     COUNT_COVERED=$((COUNT_COVERED + 1)) ;;
    PARTIAL)     COUNT_PARTIAL=$((COUNT_PARTIAL + 1)) ;;
    NOT-COVERED) COUNT_MISSING=$((COUNT_MISSING + 1)) ;;
  esac
  RESULTS="${RESULTS}${id}"$'\t'"${name}"$'\t'"${status}"$'\t'"${shas}"$'\n'
done <<< "$CRITERIA"

# Report
printf 'spec coverage report (%s):\n' "$SPEC"
while IFS=$'\t' read -r id name status shas; do
  [ -z "$id" ] && continue
  pad=$(printf '%-*s' "$MAX_ID_LEN" "$id")
  # RFC 0004 PR 5: when --manifest-history is set, append reviewer verdict
  # counts as an inline tail. Tail is omitted when the flag is unset so the
  # report shape is unchanged for legacy invocations.
  tail=""
  if [ -n "$MANIFEST_HISTORY" ]; then
    counts="$(count_manifest_verdicts "$id")"
    IFS=$'\t' read -r c_ship c_nfix c_disc c_oos <<< "$counts"
    tail="$(printf ' [reviewer: %d SHIP, %d NEEDS-FIX, %d DISCUSS, %d OUT-OF-SCOPE]' \
        "$c_ship" "$c_nfix" "$c_disc" "$c_oos")"
  fi
  case "$status" in
    COVERED)     printf '  %s  COVERED      (%s) — %s%s\n' "$pad" "$shas" "$name" "$tail" ;;
    PARTIAL)     printf '  %s  PARTIAL      (%s) — %s%s\n' "$pad" "$shas" "$name" "$tail" ;;
    NOT-COVERED) printf '  %s  NOT-COVERED         — %s%s\n' "$pad" "$name" "$tail" ;;
    *)           printf '  %s  %-12s        — %s%s\n' "$pad" "$status" "$name" "$tail" ;;
  esac
done <<< "$RESULTS"
printf '  ─\n'
printf '  totals: %d covered · %d partial · %d not-covered\n' \
  "$COUNT_COVERED" "$COUNT_PARTIAL" "$COUNT_MISSING"

# Optional re-queue. Append one BACKLOG line per NOT-COVERED criterion.
# The line is popper-friendly (`- [ ] ...`) and tagged so a human reader
# can see where it came from. We do *not* append PARTIAL items — by
# definition the work was attempted; a coverage gap there is a citation
# discipline issue, not a missing feature.
if [ -n "$REQUEUE" ] && [ "$COUNT_MISSING" -gt 0 ]; then
  appended=0
  while IFS=$'\t' read -r id name status shas; do
    [ "$status" = "NOT-COVERED" ] || continue
    [ -z "$id" ] && continue
    printf -- '- [ ] (spec coverage gap %s) %s\n' "$id" "$name" >> "$REQUEUE"
    appended=$((appended + 1))
  done <<< "$RESULTS"
  log
  log "appended $appended NOT-COVERED criteria to $REQUEUE"
fi
