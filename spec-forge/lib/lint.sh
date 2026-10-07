#!/usr/bin/env bash
# lint.sh — `spec-forge lint` (RFC 0005 §7): deterministic checks of a run
# directory's spec.md, BACKLOG.md and report.md. No model is called.
# Sourced by bin/spec-forge; expects common.sh and plugin-deps.sh loaded.
#
# §5 criteria are read with spec-trio's own parse_test_criteria, sourced from
# the resolved spec-trio install, so lint and the spec-trio loop agree on them.
# Everything else is read by the fence- and comment-aware scanners below; the
# S2 rule reports any criterion on which the two readings disagree.

SF_LINT_FILES="spec.md BACKLOG.md report.md"

sf_lint_usage() {
  cat <<'EOF'
Usage: spec-forge lint --run DIR

Checks DIR/spec.md, DIR/BACKLOG.md and DIR/report.md (a run directory made by
`spec-forge gate`) against the RFC 0005 §7 rules and writes DIR/lint.json.
Violations print as `file:line: RULE message`.

Needs spec-trio (on PATH, installed for this host, or SPEC_TRIO_BIN=<spec-trio>/bin).

Exit: 0 clean · 5 violations · 2 usage error or missing dependency · 6 I/O failure
EOF
}

# Records from spec.md, one per line, tab-separated:
#   H2   line N            "## §N" heading outside fences and comments
#   H3   line id parent    "### §N.M" heading; parent is the enclosing §N or ""
#   CMD  line id           a command (inline code or fenced block) in §5.N body
#   RAW3 line id           every "### §5." line, as spec-trio's parser sees it
sf_lint_scan_spec() {
  LC_ALL=C awk '
    function strip_comments(s,    out, i, j) {
      out = ""
      while (s != "") {
        if (in_comment) {
          j = index(s, "-->")
          if (j == 0) return out
          s = substr(s, j + 3); in_comment = 0
        } else {
          i = index(s, "<!--")
          if (i == 0) return out s
          out = out substr(s, 1, i - 1); s = substr(s, i + 4); in_comment = 1
        }
      }
      return out
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^###[[:space:]]+§5\./) {
        raw = line
        sub(/^###[[:space:]]+/, "", raw)
        k = match(raw, /[[:space:]]/)
        if (k > 0) raw = substr(raw, 1, k - 1)
        sub(/\.$/, "", raw)
        print "RAW3\t" NR "\t" raw
      }
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      if (in_fence) {
        if (substr(trimmed, 1, 3) == fence) { in_fence = 0; next }
        if (sec5 != "" && trimmed != "") print "CMD\t" NR "\t" sec5
        next
      }
      if (!in_comment && (substr(trimmed, 1, 3) == "```" || substr(trimmed, 1, 3) == "~~~")) {
        in_fence = 1; fence = substr(trimmed, 1, 3); next
      }
      text = strip_comments(line)
      if (text ~ /^##[[:space:]]/) {
        h2 = ""; sec5 = ""
        if (text ~ /^##[[:space:]]+§[0-9]+([[:space:].]|$)/) {
          n = text
          sub(/^##[[:space:]]+§/, "", n)
          sub(/[^0-9].*$/, "", n)
          h2 = n
          print "H2\t" NR "\t" n
        }
        next
      }
      if (text ~ /^###[[:space:]]/) {
        sec5 = ""
        if (text ~ /^###[[:space:]]+§[0-9]+(\.[0-9]+)+\.?([[:space:]]|$)/) {
          id = text
          sub(/^###[[:space:]]+/, "", id)
          sub(/[[:space:]].*$/, "", id)
          sub(/\.$/, "", id)
          print "H3\t" NR "\t" id "\t" h2
          if (h2 == "5" && id ~ /^§5\./) sec5 = id
        }
        next
      }
      if (sec5 != "" && text ~ /`[^`]*[^`[:space:]][^`]*`/) print "CMD\t" NR "\t" sec5
    }
  ' "$1"
}

# Records from BACKLOG.md:
#   TASK  line cites   a pending task spec-trio would pick (cites: space-separated §ids)
#   FENCED line        a pending-task line inside a code fence
#   NEAR  line         a line that looks like a task but spec-trio skips it
sf_lint_scan_backlog() {
  LC_ALL=C awk '
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      pending = (line ~ /^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+/)
      if (in_fence) {
        if (substr(trimmed, 1, 3) == fence) in_fence = 0
        else if (pending) print "FENCED\t" NR
        next
      }
      if (substr(trimmed, 1, 3) == "```" || substr(trimmed, 1, 3) == "~~~") {
        in_fence = 1; fence = substr(trimmed, 1, 3); next
      }
      if (!pending) {
        if (line ~ /^[[:space:]]*[-*+][[:space:]]*\[[[:space:]]*\]/) print "NEAR\t" NR
        next
      }
      cites = ""; rest = line
      while (match(rest, /\([^()]*\)/)) {
        group = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        while (match(group, /§[0-9]+(\.[0-9]+)*/)) {
          cites = cites (cites == "" ? "" : " ") substr(group, RSTART, RLENGTH)
          group = substr(group, RSTART + RLENGTH)
        }
      }
      print "TASK\t" NR "\t" cites
    }
  ' "$1"
}

# Records from report.md:
#   PROVSEC line             the "## Provenance" heading
#   PROV    line id labels   a table row; labels joined by \037
sf_lint_scan_report() {
  LC_ALL=C awk '
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      if (in_fence) { if (substr(trimmed, 1, 3) == fence) in_fence = 0; next }
      if (substr(trimmed, 1, 3) == "```" || substr(trimmed, 1, 3) == "~~~") {
        in_fence = 1; fence = substr(trimmed, 1, 3); next
      }
      if (line ~ /^##[[:space:]]/) {
        in_prov = (line ~ /^##[[:space:]]+Provenance[[:space:]]*$/)
        if (in_prov) print "PROVSEC\t" NR
        next
      }
      if (!in_prov || line !~ /^[[:space:]]*\|/) next
      n = split(line, cell, "|")
      if (n < 4) next
      id = cell[2]; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id !~ /^§/) next
      labels = ""
      m = split(cell[3], part, ",")
      for (i = 1; i <= m; i++) {
        l = part[i]; gsub(/^[ \t]+|[ \t]+$/, "", l)
        if (l != "") labels = labels (labels == "" ? "" : "\037") l
      }
      print "PROV\t" NR "\t" id "\t" labels
    }
  ' "$1"
}

# sf_lint_placeholders TEMPLATE — the "<…>" placeholders a spec-trio template
# carries outside its HTML comments, one per line.
sf_lint_placeholders() {
  LC_ALL=C awk '
    {
      s = $0; out = ""
      while (s != "") {
        if (in_comment) {
          j = index(s, "-->"); if (j == 0) { s = ""; break }
          s = substr(s, j + 3); in_comment = 0
        } else {
          i = index(s, "<!--"); if (i == 0) { out = out s; break }
          out = out substr(s, 1, i - 1); s = substr(s, i + 4); in_comment = 1
        }
      }
      while (match(out, /<[^<>!]+>/)) {
        print substr(out, RSTART, RLENGTH)
        out = substr(out, RSTART + RLENGTH)
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

# sf_lint_judge DIR — read the record files in DIR and print violations as
#   file\tline\trule\tmessage
sf_lint_judge() {
  local d="$1"
  LC_ALL=C awk -F'\t' '
    function v(file, line, rule, msg) { print file "\t" line "\t" rule "\t" msg }
    FILENAME == ARGV[1] { if (FNR > 1) { known[$1] = 1; known[$2] = 1 }; next }
    FILENAME == ARGV[2] {
      if ($1 == "H2") {
        h2n++; h2line[h2n] = $2; h2num[h2n] = $3
        if (!(("§" $3) in specline)) specline["§" $3] = $2
      } else if ($1 == "H3") {
        if (!($3 in specline)) specline[$3] = $2
        if ($4 == "5" && $3 ~ /^§5\./) { f5n++; f5id[f5n] = $3; f5line[f5n] = $2; infence5[$3] = 1 }
      } else if ($1 == "CMD") {
        hascmd[$3] = 1
      } else if ($1 == "RAW3") {
        rawn++; rawid[rawn] = $3; rawline[rawn] = $2
      }
      next
    }
    FILENAME == ARGV[3] { pn++; pid[pn] = $1; inparser[$1] = 1; next }
    FILENAME == ARGV[4] {
      if ($1 == "TASK") {
        tasks++
        if ($3 == "") v("BACKLOG.md", $2, "B2", "pending task cites no spec section; add (§N.M)")
        c = split($3, cite, " ")
        for (i = 1; i <= c; i++) {
          cited[cite[i]] = 1
          if (!(cite[i] in specline)) v("BACKLOG.md", $2, "B3", "cites " cite[i] ", which spec.md does not define")
        }
      } else if ($1 == "FENCED") {
        v("BACKLOG.md", $2, "B1", "task line inside a code fence; spec-trio would still pick it up")
      } else if ($1 == "NEAR") {
        v("BACKLOG.md", $2, "B1", "looks like a task but spec-trio skips it; write \"- [ ] (§N.M) ...\"")
      }
      next
    }
    FILENAME == ARGV[5] {
      if ($1 == "PROVSEC") provsec = $2
      else if ($1 == "PROV") {
        provn++; provid[provn] = $3; provline[provn] = $2; provlabels[provn] = $4
        if (!($3 in provat)) provat[$3] = $2
      }
      next
    }
    END {
      # S1: ## §1 … ## §6, once each, in order.
      prev = 0
      for (i = 1; i <= h2n; i++) {
        n = h2num[i] + 0
        if (n < 1 || n > 6) { v("spec.md", h2line[i], "S1", "unexpected section ## §" h2num[i]); continue }
        seen[n]++
        if (seen[n] > 1) v("spec.md", h2line[i], "S1", "duplicate section ## §" n)
        else if (n < prev) v("spec.md", h2line[i], "S1", "section ## §" n " is out of order")
        if (n > prev) prev = n
      }
      for (n = 1; n <= 6; n++) if (!seen[n]) v("spec.md", 1, "S1", "missing section ## §" n)

      # S2/S3: spec-trio parser output against the fence-aware reading.
      line5 = ("§5" in specline) ? specline["§5"] : 1
      if (pn == 0) v("spec.md", line5, "S2", "spec-trio finds no ### §5.N test criteria")
      for (i = 1; i <= pn; i++) {
        id = pid[i]; ln = line5
        for (j = 1; j <= rawn; j++) if (rawid[j] == id && !rawused[j]) { rawused[j] = 1; ln = rawline[j]; break }
        if (id !~ /^§5\.[0-9]+$/) { v("spec.md", ln, "S2", "malformed criterion id \"" id "\"; use ### §5.N"); continue }
        if (!(id in infence5)) { v("spec.md", ln, "S2", "spec-trio counts " id ", but it is inside a code fence or comment"); continue }
        pseen[id]++
        if (pseen[id] > 1) v("spec.md", ln, "S3", "duplicate criterion " id)
      }
      for (i = 1; i <= f5n; i++) {
        id = f5id[i]
        if (!(id in inparser)) { v("spec.md", f5line[i], "S2", "spec-trio does not see " id "; a fenced or commented ## heading ends its §5 block"); continue }
        if (!(id in hascmd)) v("spec.md", f5line[i], "S4", id " has no command; quote at least one check in backticks")
        if (!(id in cited) && !(id in b4done)) { b4done[id] = 1; v("spec.md", f5line[i], "B4", id " is not cited by any pending task in BACKLOG.md") }
      }
      if (tasks == 0) v("BACKLOG.md", 1, "B1", "no pending task in spec-trio form \"- [ ] (§N.M) ...\"")

      # P1: provenance covers every section and names known decision fields.
      if (!provsec) v("report.md", 1, "P1", "missing \"## Provenance\" table")
      else {
        for (id in specline) if (!(id in provat)) v("report.md", provsec, "P1", "no provenance row for " id)
        for (i = 1; i <= provn; i++) {
          if (!(provid[i] in specline)) v("report.md", provline[i], "P1", "row " provid[i] " names a section spec.md does not define")
          if (provlabels[i] == "") { v("report.md", provline[i], "P1", "row " provid[i] " names no decision field"); continue }
          m = split(provlabels[i], lab, "\037")
          for (k = 1; k <= m; k++) if (!(lab[k] in known)) v("report.md", provline[i], "P1", "unknown decision field \"" lab[k] "\"")
        }
      }
    }
  ' "$SPEC_FORGE_ROOT/lib/decision-fields.tsv" "$d/spec.rec" "$d/parser.rec" "$d/backlog.rec" "$d/report.rec"
}

sf_lint() {
  local run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) sf_lint_usage; return 0 ;;
      --run)
        if [ $# -lt 2 ] || [ -z "$2" ]; then sf_err "--run needs a value"; return "$SF_RC_USAGE"; fi
        run="$2"; shift 2 ;;
      *) sf_err "lint: unknown argument: $1"; sf_lint_usage >&2; return "$SF_RC_USAGE" ;;
    esac
  done
  if [ -z "$run" ]; then sf_err "lint: --run is required"; return "$SF_RC_USAGE"; fi
  sf_require_jq || return
  if [ ! -d "$run" ] || [ ! -f "$run/run.json" ] || [ -L "$run/run.json" ]; then
    sf_err "lint: $run is not a spec-forge run directory (no run.json); create one with 'spec-forge gate'"
    return "$SF_RC_USAGE"
  fi
  run=$(sf_abs "$run") || return "$SF_RC_IO"

  sf_resolve SPEC_TRIO_BIN spec-trio@pandas-studio spec-coverage.sh || return
  local spec_trio_root
  spec_trio_root=$(CDPATH='' cd -- "$(dirname -- "$RESOLVED_SCRIPT")/.." && pwd -P) || return "$SF_RC_USAGE"
  if [ ! -f "$spec_trio_root/lib/spec-helpers.sh" ] || [ ! -f "$spec_trio_root/prompts/spec.md.template" ]; then
    sf_err "lint: $spec_trio_root lacks lib/spec-helpers.sh or prompts/spec.md.template"
    return "$SF_RC_USAGE"
  fi
  # shellcheck source=/dev/null
  . "$spec_trio_root/lib/spec-helpers.sh" || { sf_err "lint: cannot load spec-helpers.sh"; return "$SF_RC_USAGE"; }

  local work rc=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/spec-forge-lint.XXXXXX") || return "$SF_RC_IO"
  sf_lint_run "$run" "$spec_trio_root" "$work" || rc=$?
  rm -rf -- "$work"
  return "$rc"
}

# sf_lint_run RUN SPEC_TRIO_ROOT WORK — the checks proper.
sf_lint_run() {
  local run="$1" spec_trio_root="$2" work="$3" f missing=0
  : > "$work/violations.tsv" || return "$SF_RC_IO"
  for f in $SF_LINT_FILES; do
    if [ ! -f "$run/$f" ] || [ -L "$run/$f" ]; then
      printf '%s\t1\tF1\tmissing %s (a regular file)\n' "$f" "$f" >> "$work/violations.tsv"
      missing=1
    fi
  done

  if [ "$missing" = 0 ]; then
    sf_lint_scan_spec "$run/spec.md" > "$work/spec.rec" &&
      parse_test_criteria "$run/spec.md" | cut -f1 > "$work/parser.rec" &&
      sf_lint_scan_backlog "$run/BACKLOG.md" > "$work/backlog.rec" &&
      sf_lint_scan_report "$run/report.md" > "$work/report.rec" &&
      sf_lint_judge "$work" >> "$work/violations.tsv" || return "$SF_RC_IO"

    sf_lint_placeholders "$spec_trio_root/prompts/spec.md.template" > "$work/placeholders" || return "$SF_RC_IO"
    printf '%s\n' '(replace this)' >> "$work/placeholders"
    for f in $SF_LINT_FILES; do
      { LC_ALL=C grep -n -o -E '__[A-Z][A-Z0-9_]*__' "$run/$f" || true
        LC_ALL=C grep -n -o -F -f "$work/placeholders" "$run/$f" || true
      } | while IFS= read -r hit; do
        printf '%s\t%s\tP2\tunfilled placeholder %s\n' "$f" "${hit%%:*}" "${hit#*:}"
      done >> "$work/violations.tsv" || return "$SF_RC_IO"
    done
  fi

  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3 -u "$work/violations.tsv" > "$work/sorted.tsv" || return "$SF_RC_IO"
  awk -F'\t' '{ print $1 ":" $2 ": " $3 " " $4 }' "$work/sorted.tsv"

  local hashes="{}" sha
  for f in $SF_LINT_FILES; do
    if [ -f "$run/$f" ] && [ ! -L "$run/$f" ]; then
      sha=$(sf_sha256 "$run/$f") || return "$SF_RC_IO"
      hashes=$(jq -c --arg f "$f" --arg s "$sha" '. + {($f): $s}' <<<"$hashes") || return "$SF_RC_IO"
    fi
  done
  jq -R -s --arg at "$(sf_now)" --argjson files "$hashes" '
    [split("\n")[] | select(length > 0) | split("\t")
     | {file: .[0], line: (.[1] | tonumber), rule: .[2], message: .[3]}] as $v
    | {schema_version: 1, ok: ($v | length == 0), checked_at: $at, files: $files, violations: $v}
  ' "$work/sorted.tsv" | ( umask 077 && sf_write_atomic "$run/lint.json" ) || {
    sf_err "lint: cannot write $run/lint.json"; return "$SF_RC_IO"; }

  if [ -s "$work/sorted.tsv" ]; then
    sf_err "lint: $(wc -l < "$work/sorted.tsv" | tr -d ' ') violation(s)"
    return "$SF_RC_LINT"
  fi
  sf_err "lint: clean"
}
