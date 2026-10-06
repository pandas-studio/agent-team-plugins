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
# reader never sees a partial file.
sf_write_atomic() {
  local dest="$1" tmp
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
  SPEC_TRIO_PM_HOST="${SPEC_FORGE_PM_HOST:-${SPEC_TRIO_PM_HOST:-claude}}"
  resolve_plugin_script "$1" "$2" "$3" || rc=$?
  if [ "$rc" -ne 0 ]; then
    plugin_deps_error spec-forge "${2%@*}" "$3" "$1" "$rc"
    return "$SF_RC_USAGE"
  fi
}

sf_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  sf_err "jq is required"
  return "$SF_RC_USAGE"
}
