#!/usr/bin/env bash
# gate.sh — `spec-forge gate` (RFC 0005 §5): refuse a decision record that is
# not ready, otherwise open a fresh private run directory holding a snapshot of
# it. Sourced by bin/spec-forge; expects common.sh and plugin-deps.sh loaded.

sf_gate_usage() {
  cat <<'EOF'
Usage: spec-forge gate --decision FILE [--debate-receipt FILE] [--workspace DIR]

Checks that FILE is a confirmed design-decision record (status starts with
확정, no __PLACEHOLDER__ left, required fields filled) and creates
<workspace>/runs/<run_id>/ with decision.md and run.json. Prints the run
directory. The workspace defaults to ./.spec-forge.

--debate-receipt reads a debate-conductor receipt with debate_receipt_read
(needs the debate-conductor plugin, or DEBATE_CONDUCTOR_BIN).

Exit: 0 run created · 2 usage error or refusal · 6 I/O failure
EOF
}

# sf_decision_fields FILE — one line per known field found in FILE:
#   <line>\t<key>\t<label>\t<filled 0|1>\t<first value line>
# A field is a column-0 bullet "- <label>: <value>". Its value is the rest of
# that line plus any following indented, non-blank lines.
sf_decision_fields() {
  LC_ALL=C awk -F'\t' '
    FNR == NR { if (FNR > 1) key[$2] = $1; next }
    function flush() {
      if (cur != "") print cur_line "\t" key[cur] "\t" cur "\t" (filled ? 1 : 0) "\t" first
      cur = ""
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^-[ \t]+[^:]+:/) {
        flush()
        label = line
        sub(/^-[ \t]+/, "", label)
        value = substr(label, index(label, ":") + 1)
        label = substr(label, 1, index(label, ":") - 1)
        sub(/[ \t]+$/, "", label)
        sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
        if (label in key) {
          cur = label; cur_line = FNR; first = value; filled = (value != "")
        }
        next
      }
      if (cur != "" && line ~ /^[ \t]+[^ \t]/) { filled = 1; next }
      flush()
    }
    END { flush() }
  ' "$SPEC_FORGE_ROOT/lib/decision-fields.tsv" "$1"
}

sf_gate() {
  local decision="" receipt="" workspace=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) sf_gate_usage; return 0 ;;
      --decision|--debate-receipt|--workspace)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          sf_err "$1 needs a value"; return "$SF_RC_USAGE"
        fi
        case "$1" in
          --decision) decision="$2" ;;
          --debate-receipt) receipt="$2" ;;
          --workspace) workspace="$2" ;;
        esac
        shift 2 ;;
      *) sf_err "gate: unknown argument: $1"; sf_gate_usage >&2; return "$SF_RC_USAGE" ;;
    esac
  done
  if [ -z "$decision" ]; then
    sf_err "gate: --decision is required"; return "$SF_RC_USAGE"
  fi
  sf_require_jq || return
  if [ ! -f "$decision" ] || [ -L "$decision" ] || [ ! -r "$decision" ]; then
    sf_err "gate: decision record is not a readable regular file: $decision"
    return "$SF_RC_USAGE"
  fi

  local refusals=0 fields placeholders row line key label filled first
  placeholders=$(LC_ALL=C grep -n -o -E '__[A-Z][A-Z0-9_]*__' "$decision") || true
  if [ -n "$placeholders" ]; then
    while IFS= read -r row; do
      sf_err "gate: $decision:${row%%:*}: placeholder ${row#*:} is not filled"
    done <<<"$placeholders"
    refusals=1
  fi

  fields=$(sf_decision_fields "$decision") || { sf_err "gate: cannot read $decision"; return "$SF_RC_IO"; }
  local status_seen=0 required_key required_label
  while IFS="$(printf '\t')" read -r required_key required_label _ ; do
    [ "$required_key" = key ] && continue
    local count
    count=$(printf '%s\n' "$fields" | LC_ALL=C awk -F'\t' -v k="$required_key" '$2 == k { n++ } END { print n + 0 }')
    if [ "$count" -gt 1 ]; then
      sf_err "gate: $decision: field '$required_label' appears $count times"
      refusals=1
    fi
  done < "$SPEC_FORGE_ROOT/lib/decision-fields.tsv"

  while IFS="$(printf '\t')" read -r required_key required_label required ; do
    [ "$required" = yes ] || continue
    row=$(printf '%s\n' "$fields" | LC_ALL=C awk -F'\t' -v k="$required_key" '$2 == k { print; exit }')
    if [ -z "$row" ]; then
      sf_err "gate: $decision: required field '$required_label' is missing"
      refusals=1; continue
    fi
    IFS="$(printf '\t')" read -r line key label filled first <<<"$row"
    if [ "$filled" != 1 ]; then
      sf_err "gate: $decision:$line: required field '$label' is empty"
      refusals=1; continue
    fi
    if [ "$key" = status ]; then
      status_seen=1
      case "$first" in
        확정*) ;;
        *) sf_err "gate: $decision:$line: status is '$first'; it must start with 확정 (the user's choice is confirmed)"
           refusals=1 ;;
      esac
    fi
  done < "$SPEC_FORGE_ROOT/lib/decision-fields.tsv"
  [ "$status_seen" = 1 ] || refusals=1

  local debate_json=null receipt_abs data
  if [ -n "$receipt" ]; then
    sf_resolve DEBATE_CONDUCTOR_BIN debate-conductor@pandas-studio debate.sh || return
    # shellcheck source=/dev/null
    . "$(dirname -- "$RESOLVED_SCRIPT")/../lib/debate-result.sh" || {
      sf_err "gate: cannot load debate-result.sh next to $RESOLVED_SCRIPT"; return "$SF_RC_USAGE"; }
    if ! data=$(debate_receipt_read "$receipt"); then
      sf_err "gate: debate receipt is not valid, or its transcripts moved: $receipt"
      refusals=1
    else
      receipt_abs=$(sf_abs "$receipt") || return "$SF_RC_IO"
      debate_json=$(jq -c --arg receipt "$receipt_abs" \
        '{receipt: $receipt, debate_dir, critic_round, critic_file}' <<<"$data") || return "$SF_RC_IO"
      if [ "$(jq -r '.critic_round' <<<"$debate_json")" = null ]; then
        sf_err "gate: warning: the debate has no completed critic round"
      fi
    fi
  fi

  [ "$refusals" = 0 ] || return "$SF_RC_USAGE"

  local runs run_id run_dir decision_abs sha rand
  workspace="${workspace:-$PWD/.spec-forge}"
  runs="$workspace/runs"
  ( umask 077 && mkdir -p -- "$runs" ) || { sf_err "gate: cannot create $runs"; return "$SF_RC_IO"; }
  chmod 700 -- "$workspace" "$runs" 2>/dev/null || true
  rand=$(LC_ALL=C od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || rand=""
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${rand:-0}"
  run_dir="$runs/$run_id"
  ( umask 077 && mkdir -- "$run_dir" ) || { sf_err "gate: cannot create a fresh run directory $run_dir"; return "$SF_RC_IO"; }
  run_dir=$(sf_abs "$run_dir") || return "$SF_RC_IO"
  decision_abs=$(sf_abs "$decision") || return "$SF_RC_IO"

  ( umask 077 && sf_write_atomic "$run_dir/decision.md" < "$decision" ) || {
    sf_err "gate: cannot snapshot the decision record"; return "$SF_RC_IO"; }
  sha=$(sf_sha256 "$run_dir/decision.md") || return "$SF_RC_IO"
  jq -n --arg run_id "$run_id" --arg created_at "$(sf_now)" --arg path "$decision_abs" \
    --arg sha "$sha" --argjson debate "$debate_json" \
    '{schema_version: 1, run_id: $run_id, created_at: $created_at,
      decision: {path: $path, sha256: $sha}, debate: $debate}' \
    | ( umask 077 && sf_write_atomic "$run_dir/run.json" ) || {
      sf_err "gate: cannot write run.json"; return "$SF_RC_IO"; }
  printf '%s\n' "$run_dir"
}
