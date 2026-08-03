#!/usr/bin/env bash
# ralph-meta.sh — single-shot post-run audit for a previous Ralph session.
#
# Inspects ralph-*-<TS>.log files + git history since a given timestamp, calls
# ask-codex.sh once with a focused review brief, and writes a categorized
# audit Markdown. Optionally re-queues retry candidates into a BACKLOG.md.
#
# This is NOT a loop — it's a one-pass audit you run after Ralph finishes
# (or the next morning after an overnight run). Run from inside your repo.
#
# Usage:
#   ralph-meta.sh --since "2026-05-04 06:00"  [options]
#   ralph-meta.sh --since "2 hours ago"       [options]
#   ralph-meta.sh --since-latest-run          # auto-detect from latest-ralph.log
#
# Options:
#   --variant solo|trio|debate    narrow log scan to one variant (default: any)
#   --rewrite-backlog PATH        if set, append "retry: ..." lines to that BACKLOG.md
#   --base-ref REF                git ref to compare against (default: HEAD's
#                                 first commit before SINCE; falls back to HEAD~10)
#
# Prerequisites: dev-trio plugin installed (provides ask-codex.sh on PATH).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$PLUGIN_ROOT/lib/common.sh"

SINCE=""
SINCE_LATEST=0
VARIANT=""
REWRITE_BACKLOG=""
BASE_REF=""

usage() { sed -n '2,22p' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)            SINCE="$2"; shift 2 ;;
    --since-latest-run) SINCE_LATEST=1; shift ;;
    --variant)          VARIANT="$2"; shift 2 ;;
    --rewrite-backlog)  REWRITE_BACKLOG="$2"; shift 2 ;;
    --base-ref)         BASE_REF="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Cross-plugin dependency check: ask-codex.sh comes from the dev-trio plugin.
command -v ask-codex.sh >/dev/null 2>&1 || { echo "ERROR: ralph-meta requires the dev-trio plugin (ask-codex.sh not on PATH). Install: /plugin install dev-trio@pandas-studio" >&2; exit 2; }

TEAM=$(detect_team) || exit 2
LOG_DIR=$(init_log_dir)

# Resolve --since-latest-run
if [ "$SINCE_LATEST" = "1" ]; then
  if [ -L "$LOG_DIR/latest-ralph.log" ]; then
    LATEST="$LOG_DIR/$(readlink "$LOG_DIR/latest-ralph.log")"
    if [ -f "$LATEST" ]; then
      # Extract the @ TS line from the summary
      TS_LINE=$(grep -m1 -E '@ [0-9]{8}-[0-9]{6}' "$LATEST" || true)
      if [ -n "$TS_LINE" ]; then
        TS_RAW=$(echo "$TS_LINE" | sed -nE 's/.*@ ([0-9]{8})-([0-9]{6}).*/\1 \2/p')
        # Convert YYYYMMDD HHMMSS → "YYYY-MM-DD HH:MM:SS"
        D="${TS_RAW% *}"; T="${TS_RAW#* }"
        SINCE="${D:0:4}-${D:4:2}-${D:6:2} ${T:0:2}:${T:2:2}:${T:4:2}"
        ralph_log "auto-detected --since '$SINCE' from $LATEST"
      fi
    fi
  fi
  if [ -z "$SINCE" ]; then
    echo "could not auto-detect --since (no latest-ralph.log); pass --since manually" >&2
    exit 2
  fi
fi

[ -z "$SINCE" ] && { echo "--since (or --since-latest-run) is required" >&2; exit 2; }

TS=$(date +%Y%m%d-%H%M%S)
META_LOG="$LOG_DIR/ralph-meta-$TS.log"
AUDIT_MD="$LOG_DIR/ralph-meta-$TS.md"

# Find ralph log files since the cutoff. Bash 3.2 + BSD find on macOS lack
# `mapfile` and `find -newermt`, so we drive the filter through python3 (which
# we already require for the Stop-hook) and accumulate with while-read.
PATTERN_GLOB="ralph-*-*.log"
[ -n "$VARIANT" ] && PATTERN_GLOB="ralph-$VARIANT-*-*.log"

# Parse $SINCE to an epoch cutoff. Supports:
#   absolute: "YYYY-MM-DD [HH:MM[:SS]]"
#   relative: "N {seconds,minutes,hours,days,weeks} ago"
# (--since-latest-run already normalises to the absolute form upstream.)
CUTOFF=$(python3 - "$SINCE" <<'PY'
import re, sys
from datetime import datetime, timedelta
spec = sys.argv[1].strip()
now = datetime.now()
m = re.match(r'^(\d+)\s+(second|minute|hour|day|week)s?\s+ago$', spec)
if m:
    n, unit = int(m.group(1)), m.group(2)
    delta = {'second': timedelta(seconds=n), 'minute': timedelta(minutes=n),
             'hour':   timedelta(hours=n),   'day':    timedelta(days=n),
             'week':   timedelta(weeks=n)}[unit]
    cutoff = now - delta
else:
    for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
        try:
            cutoff = datetime.strptime(spec, fmt)
            break
        except ValueError:
            continue
    else:
        sys.exit(2)
print(int(cutoff.timestamp()))
PY
) || { echo "ralph-meta: could not parse --since '$SINCE' (expected 'YYYY-MM-DD [HH:MM[:SS]]' or 'N {minutes,hours,days,weeks} ago')" >&2; exit 2; }

RALPH_LOGS=()
while IFS= read -r f; do
  [ -n "$f" ] && RALPH_LOGS+=("$f")
done < <(
  for f in "$LOG_DIR"/$PATTERN_GLOB; do
    [ -f "$f" ] || continue
    # mtime in epoch seconds, portable across BSD (-f) and GNU (-c).
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
    [ -n "$mtime" ] || continue
    [ "$mtime" -ge "$CUTOFF" ] && printf '%s\n' "$f"
  done | sort
)

# Find ralph commits in git history since the cutoff (uses cwd's repo). git's
# own --since parser is liberal enough to consume the same forms above.
# --base-ref scopes the walk to $BASE_REF..HEAD; without it, all ancestors of
# HEAD reachable within --since are considered (legacy behavior).
if [ -n "$BASE_REF" ]; then
  git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || {
    echo "ralph-meta: --base-ref does not resolve in cwd repo: $BASE_REF" >&2; exit 2;
  }
  GIT_RANGE_ARGS=( "$BASE_REF..HEAD" )
else
  GIT_RANGE_ARGS=()
fi
RALPH_COMMITS=()
while IFS= read -r line; do
  [ -n "$line" ] && RALPH_COMMITS+=("$line")
done < <(git log "${GIT_RANGE_ARGS[@]}" --since="$SINCE" --pretty=format:'%h %s' --grep='^ralph' 2>/dev/null)

ralph_log "scope: $TEAM, since=$SINCE, variant=${VARIANT:-any}, base-ref=${BASE_REF:-<none>}"
ralph_log "  ralph logs found: ${#RALPH_LOGS[@]}"
ralph_log "  ralph commits found: ${#RALPH_COMMITS[@]}"

# Build a focus brief for codex
{
  echo "# Ralph audit brief"
  echo
  echo "Team: $TEAM"
  echo "Since: $SINCE"
  echo "Base-ref: ${BASE_REF:-<none>}"
  echo "Variant filter: ${VARIANT:-any}"
  echo
  echo "## Ralph commits in this window"
  if [ "${#RALPH_COMMITS[@]}" -eq 0 ]; then
    echo "(none)"
  else
    for c in "${RALPH_COMMITS[@]}"; do echo "- $c"; done
  fi
  echo
  echo "## Ralph log summaries (per-run)"
  if [ "${#RALPH_LOGS[@]}" -eq 0 ]; then
    echo "(no ralph logs found in $LOG_DIR since $SINCE)"
  else
    # RFC 0004 PR 3: prefer the typed sibling manifest. log scrape is the
    # legacy fallback and emits a deprecation marker so the auditor can see
    # which logs are still on the old contract.
    for l in "${RALPH_LOGS[@]}"; do
      echo
      echo "### $(basename "$l")"
      CAND_MANIFEST="${l%.log}.manifest.json"
      if [ -f "$CAND_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
        jq -r '
          "- run_id:        " + .run_id,
          "- variant:       " + .variant,
          "- parent_run_id: " + (.parent_run_id // "null"),
          "- verdict:       " + (.verdict // "null"),
          "- roles:         " + (if (.roles | length) == 0 then "(none)" else (.roles | map(.name + "=" + .model) | join(", ")) end),
          "- started_at:    " + .started_at,
          "- ended_at:      " + (.ended_at // "<in-flight>")
        ' "$CAND_MANIFEST"
      else
        echo "(legacy: no manifest at $CAND_MANIFEST — falling back to log scrape)"
        head -30 "$l" 2>/dev/null
        echo "..."
        tail -20 "$l" 2>/dev/null
      fi
    done
  fi
  echo
  echo "## Your task (Codex)"
  echo
  echo "Review the ralph commits above. For each commit decide:"
  echo "1. **shipped** — looks correct, keep as-is"
  echo "2. **revert** — should be reverted (state which one and why)"
  echo "3. **retry-with-context** — task was attempted but incomplete or poorly done; suggest"
  echo "   what additional context the next ralph attempt should have"
  echo
  echo "Output format (Markdown):"
  echo
  echo '```'
  echo "## Verdict"
  echo "<one-line summary>"
  echo
  echo "## Shipped"
  echo "- <commit-hash> <subject> — <one-line why>"
  echo
  echo "## Revert"
  echo "- <commit-hash> <subject> — <reason>"
  echo
  echo "## Retry-with-context"
  echo "- <task description> — <what context to add for retry>"
  echo '```'
} > "$META_LOG"

ralph_log "audit brief written: $META_LOG"
ralph_log "calling ask-codex.sh ..."

# Pass the brief as a focus argument (codex reads the file via the focus text)
FOCUS="Audit ralph run since $SINCE for team $TEAM. Read this brief: $(cat "$META_LOG"). Inspect the actual commits via git show, then categorize each into shipped / revert / retry-with-context per the format in the brief."

CODEX_OUT="$LOG_DIR/ralph-meta-$TS-codex.log"
# ask-codex.sh writes the authoritative final review verbatim to a
# codex-<ts>.final.md (via `--output-last-message`) and the full streamed
# transcript — bracketed by `=== RESPONSE ===` / `=== END (rc=N) ===` markers —
# to codex-<ts>.log, both under the dev-trio plugin's workspace log dir (e.g.
# $PWD/.dev-trio/log/<team>/). Neither lands on stdout, so we capture ask-codex's
# stderr and scrape the `(log: <path>, final: <path>, rc=<n>)` line it prints
# there. Prefer the .final.md (clean, and empty when codex died before emitting
# its review — which is exactly when the streamed transcript degrades into the
# echoed role prompt); fall back to the === RESPONSE === section of the log.
CODEX_STDERR=$(mktemp -t ralph-meta-stderr.XXXXXX)
( AGENT_TEAM="$TEAM" ask-codex.sh "$FOCUS" 2>"$CODEX_STDERR" ) | tee "$CODEX_OUT" >/dev/null || true
cat "$CODEX_STDERR" >> "$CODEX_OUT"
DEV_CODEX_LOG=$(awk -F'[(),]' '/^\(log: / { for (i=1; i<=NF; i++) { if ($i ~ /log: /) { sub(/^[[:space:]]*log:[[:space:]]*/, "", $i); print $i; exit } } }' "$CODEX_STDERR")
DEV_CODEX_FINAL=$(awk -F'[(),]' '/^\(log: / { for (i=1; i<=NF; i++) { if ($i ~ /final: /) { sub(/^[[:space:]]*final:[[:space:]]*/, "", $i); print $i; exit } } }' "$CODEX_STDERR")
rm -f "$CODEX_STDERR"

RESPONSE_BODY=""
if [ -n "$DEV_CODEX_FINAL" ] && [ -s "$DEV_CODEX_FINAL" ]; then
  RESPONSE_BODY=$(cat "$DEV_CODEX_FINAL")
elif [ -n "$DEV_CODEX_LOG" ] && [ -f "$DEV_CODEX_LOG" ]; then
  RESPONSE_BODY=$(awk '/^=== RESPONSE ===/{flag=1; next} /^=== END/{flag=0} flag' "$DEV_CODEX_LOG" 2>/dev/null)
fi

{
  echo "# Ralph meta audit — $TEAM @ $TS"
  echo
  echo "Source: \`$META_LOG\`"
  echo "Codex output: \`$CODEX_OUT\`"
  if [ -n "$DEV_CODEX_LOG" ]; then
    echo "ask-codex log: \`$DEV_CODEX_LOG\`"
  fi
  if [ -n "$DEV_CODEX_FINAL" ] && [ -s "$DEV_CODEX_FINAL" ]; then
    echo "ask-codex final: \`$DEV_CODEX_FINAL\`"
  fi
  echo
  echo "---"
  echo
  if [ -n "$RESPONSE_BODY" ]; then
    printf '%s\n' "$RESPONSE_BODY"
  else
    echo "_(no response body extracted — could not locate ask-codex.sh's log file. Inspect \`$CODEX_OUT\` for raw output.)_"
  fi
} > "$AUDIT_MD"

ralph_log "audit MD: $AUDIT_MD"

# Optional: rewrite backlog
if [ -n "$REWRITE_BACKLOG" ]; then
  if [ ! -f "$REWRITE_BACKLOG" ]; then
    echo "warning: --rewrite-backlog target does not exist: $REWRITE_BACKLOG" >&2
  else
    ralph_log "appending retry items to $REWRITE_BACKLOG"
    # Pull the "## Retry-with-context" section from the audit
    RETRIES=$(awk '/^## Retry-with-context/{flag=1; next} /^## /{flag=0} flag' "$AUDIT_MD" 2>/dev/null | grep -E '^- ' || true)
    if [ -z "$RETRIES" ]; then
      ralph_log "  no retry-with-context items found in audit"
    else
      printf '\n## meta-audit retries (added %s by ralph-meta)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REWRITE_BACKLOG"
      while IFS= read -r line; do
        text="${line#- }"
        append_to_backlog "$REWRITE_BACKLOG" "$text"
      done <<< "$RETRIES"
      ralph_log "  appended $(echo "$RETRIES" | wc -l | tr -d ' ') items"
    fi
  fi
fi

echo "audit:    $AUDIT_MD" >&2
echo "summary:  $META_LOG" >&2
