#!/usr/bin/env bash
# spec-helpers.sh — RFC 0003 PR 3 helpers for --strict-scope.
#
# Sourced by core/spec/scripts/spec-trio.sh. Provides:
#   parse_allowed_paths <plan_log>      — echo allowlist lines, one per stdout line
#   normalize_path      <raw>           — strip ./, reject absolute and ..,
#                                         echo cleaned path or empty on reject
#   path_in_allowlist   <path> <list>   — 0 if path matches any list entry
#                                         (file = exact, "<dir>/" = prefix)
#   collect_changed_paths <work_dir>    — echo every changed path under work_dir,
#                                         covering uncommitted + committed +
#                                         untracked (mirrors reviewer scope)
#   check_scope <work_dir> <list> <log> — write a deterministic scope-violation
#                                         report to <log>; rc=0 if all changed
#                                         paths are inside <list>, rc=1 if any
#                                         path is out, rc=2 if list is empty.
#
# All helpers are pure shell (no python/perl). Path comparison is literal
# string match after normalization — no glob expansion.

# Extract the contents of <allowed-paths>...</allowed-paths> from the plan log,
# split on whitespace and commas, normalize each entry, drop empties and
# duplicates while preserving first-seen order. Echoes one path per line.
parse_allowed_paths() {
  local plan_log="$1"
  [ -f "$plan_log" ] || return 0
  awk '
    /<allowed-paths>/  { in_b = 1; sub(/.*<allowed-paths>/, ""); }
    in_b {
      line = $0
      if (sub(/<\/allowed-paths>.*/, "", line)) { in_b = 0 }
      n = split(line, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
    }
  ' "$plan_log" | awk '
    NF { if (!seen[$0]++) print $0 }
  '
}

# Normalize a raw allowlist entry. Returns the cleaned path on stdout, or
# empty string with rc=1 if the entry is rejected (absolute, contains ..,
# or empty after strip).
normalize_path() {
  local p="$1"
  [ -z "$p" ] && return 1
  # strip leading ./
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  # reject absolute paths
  case "$p" in /*) return 1 ;; esac
  # reject any segment that is ".." (path traversal)
  case "/$p/" in */../*) return 1 ;; esac
  [ -z "$p" ] && return 1
  printf '%s\n' "$p"
}

# Test whether <path> is allowed by <allowlist> (newline-separated).
# A list entry ending in "/" is a directory prefix and admits any descendant.
# A list entry without a trailing "/" must match the path exactly.
# rc=0 if allowed, rc=1 otherwise.
path_in_allowlist() {
  local path="$1" list="$2" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      */)
        case "$path/" in
          "$entry"*) return 0 ;;
          *)
            # also allow exact match without trailing slash (the dir itself)
            [ "$path/" = "$entry" ] && return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$entry" ] && return 0 ;;
    esac
  done <<< "$list"
  return 1
}

# Enumerate changed paths under <work_dir> the same way the reviewer would
# inspect them: tracked modifications, staged changes, untracked-and-not-
# ignored files, and committed-but-not-yet-on-base diffs. De-duplicated.
#
# <base_ref> (optional, but strongly preferred): SHA recorded at the start of
# this iteration. When supplied, the committed-diff scan walks $base_ref..HEAD
# so EVERY commit the coder made during the iteration is inspected — not just
# the last commit's diff to its parent. Without it, a coder that makes two
# commits in one iter could land an out-of-scope path in the first commit and
# slip past the gate (the second commit's diff hides it from git status). The
# legacy HEAD~1..HEAD fallback only fires when no base_ref is supplied (kept
# for standalone-test invocations of this helper).
collect_changed_paths() {
  local work_dir="$1"
  local base_ref="${2:-}"
  {
    # Uncommitted (staged + unstaged) via porcelain v1.
    # Format: "XY path" where XY is two-char status, path may contain "->" for renames.
    # --untracked-files=all expands untracked directories to their files so the
    # scope check matches the reviewer's "read every untracked file" view.
    git -C "$work_dir" status --porcelain=v1 --untracked-files=all 2>/dev/null | awk '
      {
        line = substr($0, 4)
        idx = index(line, " -> ")
        if (idx > 0) {
          print substr(line, 1, idx - 1)
          print substr(line, idx + 4)
        } else {
          print line
        }
      }
    '
    # Committed-but-not-yet-on-base. Prefer the iter-base ref so all commits
    # made during this iteration are caught; fall back to HEAD~1..HEAD only
    # when no base was supplied. Empty output is fine (e.g. no commits yet,
    # or HEAD == base_ref).
    if [ -n "$base_ref" ]; then
      git -C "$work_dir" diff --name-only "$base_ref" HEAD 2>/dev/null
    else
      git -C "$work_dir" diff --name-only HEAD~1 HEAD 2>/dev/null
    fi
  } | awk 'NF { gsub(/^"|"$/, "", $0); if (!seen[$0]++) print }'
}

# Compare collected paths against the allowlist. Writes a scope report to
# <scope_log>. rc=0 on full match, rc=1 on any out-of-scope path, rc=2 if
# the allowlist is empty (planner contract failure).
#
# <ignore_list> (optional) is newline-separated paths the caller knows are
# harness-managed (e.g. BACKLOG.md, fix_plan.md, spec.md) and not worker
# output. Those paths are excluded from the change set before the allowlist
# check, so harness bookkeeping doesn't trip the scope gate.
check_scope() {
  local work_dir="$1" allowlist="$2" scope_log="$3" ignore_list="${4:-}" base_ref="${5:-}"
  local changed normalized_list
  changed="$(collect_changed_paths "$work_dir" "$base_ref")"

  # Drop harness-managed paths from the change set (after newline-split) so
  # the allowlist check only sees worker output.
  local filtered=""
  if [ -n "$changed" ]; then
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      if [ -n "$ignore_list" ] && grep -qxF "$path" <<< "$ignore_list"; then
        continue
      fi
      filtered="${filtered:+$filtered$'\n'}$path"
    done <<< "$changed"
  fi

  # Normalize the allowlist; drop entries that fail validation (logged below).
  local entry norm_entry rejected=""
  normalized_list=""
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if norm_entry="$(normalize_path "$entry")"; then
      normalized_list="${normalized_list:+$normalized_list$'\n'}$norm_entry"
    else
      rejected="${rejected:+$rejected$'\n'}$entry"
    fi
  done <<< "$allowlist"

  {
    echo "=== spec-trio scope check @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "work_dir: $work_dir"
    echo
    echo "--- allowlist (parsed from plan) ---"
    if [ -z "$normalized_list" ]; then
      echo "(empty — planner contract failure)"
    else
      printf '%s\n' "$normalized_list"
    fi
    if [ -n "$rejected" ]; then
      echo
      echo "--- rejected allowlist entries (absolute, contained .., or empty) ---"
      printf '%s\n' "$rejected"
    fi
    if [ -n "$ignore_list" ]; then
      echo
      echo "--- ignored (harness-managed) ---"
      printf '%s\n' "$ignore_list"
    fi
    echo
    echo "--- changed paths under inspection ---"
    if [ -z "$filtered" ]; then
      echo "(none)"
    else
      printf '%s\n' "$filtered"
    fi
    echo
  } > "$scope_log"

  if [ -z "$normalized_list" ]; then
    {
      echo "--- verdict ---"
      echo "OUT-OF-SCOPE (plan-invalid: allowlist missing or empty)"
    } >> "$scope_log"
    return 2
  fi

  local rc=0 violations=""
  if [ -n "$filtered" ]; then
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      if ! path_in_allowlist "$path" "$normalized_list"; then
        rc=1
        violations="${violations:+$violations$'\n'}$path"
      fi
    done <<< "$filtered"
  fi

  {
    echo "--- verdict ---"
    if [ "$rc" = 0 ]; then
      echo "in-scope (all changed paths are within allowlist)"
    else
      echo "OUT-OF-SCOPE (scope-violation)"
      echo
      echo "--- offending paths ---"
      printf '%s\n' "$violations"
    fi
  } >> "$scope_log"
  return $rc
}

# parse_test_criteria <spec_file>
#
# Read spec.md and emit one tab-separated record per `### §5.N` subsection
# under the `## §5` heading:
#
#   §5.N<TAB><criterion name>
#
# The §5 heading is matched as `## §5` with an optional period/space after
# the digit, mirroring the canonical template (`## §5 Test criteria`) and
# the looser inline form (`## §5. Test criteria`). Subsection IDs accept
# multi-digit minor numbers (`§5.10` is valid) and an optional trailing
# period (`### §5.1.`). Anything outside the §5 block is ignored.
parse_test_criteria() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    # H2 heading: toggle in_5 based on whether this is §5.
    /^##[[:space:]]/ && !/^###/ {
      if ($0 ~ /^##[[:space:]]+§5([[:space:].]|$)/) in_5 = 1
      else in_5 = 0
      next
    }
    in_5 && /^###[[:space:]]+§5\./ {
      # Strip the leading "### "
      sub(/^###[[:space:]]+/, "")
      # Split id and name on first whitespace run
      idx = match($0, /[[:space:]]/)
      if (idx > 0) {
        id = substr($0, 1, idx - 1)
        name = substr($0, idx + 1)
        sub(/^[[:space:]]+/, "", name)
        sub(/[[:space:]]+$/, "", name)
      } else {
        id = $0
        name = ""
      }
      # Drop trailing period from id (so "§5.1." → "§5.1")
      sub(/\.$/, "", id)
      print id "\t" name
    }
  ' "$spec"
}

# criterion_keywords <criterion name>
#
# Emit space-separated distinctive keywords from a criterion's heading
# name, suitable for fuzzy "PARTIAL coverage" detection when no explicit
# §5.N citation exists. Drops short tokens (< 4 chars), a small English
# stopword set, and obvious filler like the literal word "criterion".
# The first 3 surviving tokens (in order) are emitted to keep grep
# patterns tight.
criterion_keywords() {
  local name="$1"
  printf '%s\n' "$name" | tr 'A-Z' 'a-z' | tr -c '[:alnum:]_' ' ' | awk '
    BEGIN {
      # generic English noise + spec-vocabulary noise; if a criterion is
      # described only in these terms, fall through to NOT-COVERED rather
      # than match any commit that happens to mention "case" or "input".
      stop["the"]=1; stop["and"]=1; stop["for"]=1; stop["with"]=1
      stop["that"]=1; stop["this"]=1; stop["from"]=1; stop["into"]=1
      stop["when"]=1; stop["then"]=1; stop["case"]=1; stop["check"]=1
      stop["test"]=1; stop["tests"]=1; stop["criterion"]=1
      stop["input"]=1; stop["output"]=1; stop["value"]=1; stop["values"]=1
      stop["name"]=1; stop["names"]=1; stop["edge"]=1; stop["error"]=1
    }
    {
      n = 0
      for (i = 1; i <= NF; i++) {
        t = $i
        if (length(t) < 4) continue
        if (t in stop) continue
        if (seen[t]++) continue
        printf "%s%s", (n > 0 ? " " : ""), t
        n++
        if (n >= 3) break
      }
      print ""
    }
  '
}
