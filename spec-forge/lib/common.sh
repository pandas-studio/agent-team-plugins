#!/usr/bin/env bash
# shellcheck disable=SC2034  # SF_RC_* are read by the libraries sourced after this one
# common.sh — helpers shared by the spec-forge subcommands (RFC 0005).
#
# Sourced by bin/spec-forge after SPEC_FORGE_ROOT is set. Pure bash 3.2 + jq.
#
# Exit codes used across subcommands:
#   0 ok · 2 usage, gate refusal or missing dependency · 5 lint violations
#   6 capture or I/O failure

SF_RC_USAGE=2
SF_RC_LINT=5
SF_RC_IO=6

sf_err() { printf 'spec-forge: %s\n' "$*" >&2; }

# sf_sha256 FILE — print the hex digest of FILE.
sf_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum < "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 < "$1") || return 1
  else
    sf_err "neither sha256sum nor shasum is available"
    return 1
  fi
  printf '%s\n' "${out%% *}"
}

# sf_abs PATH — absolute, physical path of an existing file or directory.
sf_abs() {
  local dir base
  if [ -d "$1" ]; then
    (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
    return
  fi
  dir=$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  base=$(basename -- "$1")
  printf '%s/%s\n' "$dir" "$base"
}

# sf_now — UTC timestamp, RFC 3339.
sf_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# sf_write_atomic DEST — copy stdin to DEST through a temporary sibling, so a
# reader never sees a partial file. DEST must be absent or a regular file: mv
# would move the file into a directory, or into the directory a symlink names.
# The check and the rename are not one step, and bash on macOS has no
# exact-destination rename (GNU mv -T). Swapping DEST in between takes a
# process of the same user inside the 0700 run directory (RFC 0005 §10.4).
sf_write_atomic() {
  local dest="$1" tmp
  if [ -L "$dest" ] || [ -d "$dest" ]; then
    sf_err "$dest is a directory or a symbolic link; not replacing it"
    return 1
  fi
  tmp=$(mktemp "$dest.tmp.XXXXXX") || return 1
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# sf_resolve VAR PLUGIN_ID SCRIPT — find a sibling plugin's script through the
# vendored plugin-deps.sh. The helper reads the host from SPEC_TRIO_PM_HOST, so
# SPEC_FORGE_PM_HOST is mapped onto it for this process only (RFC 0005 §14-4).
# On failure prints the standard message and returns SF_RC_USAGE.
sf_resolve() {
  local rc=0
  local SPEC_TRIO_PM_HOST="${SPEC_FORGE_PM_HOST:-${SPEC_TRIO_PM_HOST:-claude}}"
  local RALPH_TRIO_PM_HOST=""
  resolve_plugin_script "$1" "$2" "$3" || rc=$?
  if [ "$rc" -ne 0 ]; then
    plugin_deps_error spec-forge "${2%@*}" "$3" "$1" "$rc"
    return "$SF_RC_USAGE"
  fi
}

# SF_AWK_MD — awk functions that decide which parts of a Markdown line are
# visible: not inside an HTML comment and not inside a code fence. Every reader
# of drafts and decision records prepends this to its program, so they agree.
#
#   md_strip_comments(s)  s without HTML comments; md_in_comment carries an
#                         unclosed comment to the next line.
#   md_line(raw)          classify one line (CR already removed). Sets
#     md_kind         "fence" (a fence delimiter or a line inside a fence) or "text"
#     md_delim        1 for an opening or closing fence delimiter
#     md_text         "text": the line without comments; "fence": the raw line
#     md_was_comment  1 if the line began inside an HTML comment
#     md_fence_indent indentation of the open fence's delimiter
#
# A fence opens with a run of three or more backticks or tildes outside a
# comment, and closes only with a run of the same character, at least as long,
# followed by nothing but blanks (CommonMark).
SF_AWK_MD='
function md_strip_comments(s,    out, i, j) {
  out = ""
  while (s != "") {
    if (md_in_comment) {
      j = index(s, "-->")
      if (j == 0) return out
      s = substr(s, j + 3); md_in_comment = 0
    } else {
      i = index(s, "<!--")
      if (i == 0) return out s
      out = out substr(s, 1, i - 1); s = substr(s, i + 4); md_in_comment = 1
    }
  }
  return out
}
function md_line(raw,    t) {
  md_was_comment = md_in_comment
  t = raw
  sub(/^[ \t]+/, "", t)
  md_delim = 0
  if (md_fence_len) {
    md_kind = "fence"; md_text = raw
    if (substr(t, 1, 1) == md_fence_char && match(t, md_fence_char == "`" ? "^`+" : "^~+") &&
        RLENGTH >= md_fence_len && substr(t, RLENGTH + 1) ~ /^[ \t]*$/) {
      md_fence_len = 0; md_delim = 1
    }
    return
  }
  if (!md_in_comment && match(t, "^(```+|~~~+)") && RLENGTH >= 3) {
    md_fence_char = substr(t, 1, 1); md_fence_len = RLENGTH
    md_fence_indent = length(raw) - length(t)
    md_kind = "fence"; md_delim = 1; md_text = raw
    return
  }
  md_kind = "text"
  md_text = md_strip_comments(raw)
}
'

sf_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  sf_err "jq is required"
  return "$SF_RC_USAGE"
}
