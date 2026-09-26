#!/usr/bin/env bash
# shellcheck disable=SC2034  # RESOLVED_* are results read by the caller
# plugin-deps.sh — find a script shipped by a sibling plugin (dev-trio,
# debate-conductor) without relying on PATH.
#
# A plugin's bin/ is on PATH only inside a Claude Code session with the plugin
# enabled, so a driver started from a plain terminal, launchd or cron must look
# elsewhere. Kept byte-identical in ralph-trio/lib and spec-trio/lib (each plugin
# ships on its own; tests/test_plugin_discovery.py compares the two copies).
#
# Usage:
#   . "$PLUGIN_ROOT/lib/plugin-deps.sh"
#   rc=0; resolve_plugin_script DEV_TRIO_BIN dev-trio@pandas-studio ask-reviewer.sh || rc=$?
#
# Lookup order, first hit wins:
#   1. $<override-var> — the plugin's bin/ directory (relative to the current
#      directory if relative). Set but lacking the script is an error (rc 2):
#      an explicit choice is never silently replaced by another copy.
#   2. PATH (`command -v`) — what a Claude Code session provides.
#   3. The active host's plugin list: Codex's installed version cache, or
#      `claude plugin list --json`, run in the
#      current directory. Never CLAUDE_CLI: that is the planner/coder model
#      override, and a wrapper there may take any argv as a prompt.
#      Claude Code decides whether the plugin is enabled here; its `enabled`
#      flag is per plugin id, not per install entry, so project/local entries
#      count only when their projectPath is this directory. Remaining entries
#      rank local > project > user > other, then by installPath (an installPath
#      holding a tab, newline or backslash never matches: @tsv escapes it). No
#      timeout: macOS ships none, and this step runs only when PATH has no copy.
#
# Results (globals, reset on every call — never call this inside $(...)):
#   RESOLVED_SCRIPT  absolute path of the script
#   RESOLVED_SOURCE  where it came from: the variable name, PATH, or
#                    "plugin list: <id> <version> (<scope>)"
#   RESOLVED_WHY     why each step missed ("; "-separated), for error messages
# Returns 0 found, 1 not found, 2 the override is set but unusable.

# _plugin_deps_absolute PATH — set RESOLVED_SCRIPT to PATH with its directory
# made absolute, so the script can still be run after the caller changes directory.
_plugin_deps_absolute() {
  local dir
  dir=$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  RESOLVED_SCRIPT="$dir/$(basename -- "$1")"
}

resolve_plugin_script() {
  local var="$1" id="$2" script="$3"
  local dir p out rc cwd cwd_phys cands path version scope tab
  RESOLVED_SCRIPT=""; RESOLVED_SOURCE=""; RESOLVED_WHY=""

  dir="${!var:-}"
  if [ -n "$dir" ]; then
    p="$dir/$script"
    if [ -f "$p" ] && [ -x "$p" ] && _plugin_deps_absolute "$p"; then
      RESOLVED_SOURCE="$var"
      return 0
    fi
    RESOLVED_WHY="$var=$dir has no executable $script"
    return 2
  fi
  RESOLVED_WHY="$var unset or empty"

  # bash 3.2 returns a non-executable match when no executable one exists.
  p=$(command -v -- "$script" 2>/dev/null) || p=""
  if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] && _plugin_deps_absolute "$p"; then
    RESOLVED_SOURCE="PATH"
    return 0
  fi
  RESOLVED_WHY="$RESOLVED_WHY; not on PATH"

  # Codex does not guarantee plugin bin/ aliases on PATH. Resolve the enabled,
  # installed exact version; a marketplace snapshot may be newer than the
  # installed cache and must not be used as a silent substitute.
  if [ "${RALPH_TRIO_PM_HOST:-${SPEC_TRIO_PM_HOST:-claude}}" = codex ]; then
    if ! command -v codex >/dev/null 2>&1; then
      RESOLVED_WHY="$RESOLVED_WHY; no codex on PATH to inspect plugins"
      return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      RESOLVED_WHY="$RESOLVED_WHY; jq not found"
      return 1
    fi
    out=$(codex plugin list --json </dev/null 2>/dev/null) || rc=$?
    if [ "${rc:-0}" -ne 0 ] || ! jq -e '.installed | type == "array"' >/dev/null 2>&1 <<<"$out"; then
      RESOLVED_WHY="$RESOLVED_WHY; codex plugin list --json failed"
      return 1
    fi
    version=$(jq -r --arg id "$id" '.installed[] | select(.pluginId == $id and .installed == true and .enabled == true) | .version' <<<"$out" | head -1)
    if [ -z "$version" ]; then
      RESOLVED_WHY="$RESOLVED_WHY; $id is not enabled in Codex"
      return 1
    fi
    case "$version" in *[!A-Za-z0-9.+_-]*|.|..)
      RESOLVED_WHY="$RESOLVED_WHY; unsafe plugin version from Codex"; return 1 ;;
    esac
    local plugin="${id%@*}" marketplace="${id#*@}" cache_root
    cache_root="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$marketplace/$plugin/$version"
    p="$cache_root/bin/$script"
    if [ -f "$p" ] && [ -x "$p" ] && _plugin_deps_absolute "$p"; then
      RESOLVED_SOURCE="codex plugin cache: $id $version"
      return 0
    fi
    RESOLVED_WHY="$RESOLVED_WHY; exact Codex cache lacks $p"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    RESOLVED_WHY="$RESOLVED_WHY; no claude on PATH to ask for its plugin list"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    RESOLVED_WHY="$RESOLVED_WHY; jq not found, so 'claude plugin list' was not read"
    return 1
  fi
  rc=0
  out=$(claude plugin list --json </dev/null 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    RESOLVED_WHY="$RESOLVED_WHY; 'claude plugin list --json' failed (rc=$rc)"
    return 1
  fi
  if ! jq -e --arg id "$id" 'any(.[]; type == "object" and .id == $id)' >/dev/null 2>&1 <<<"$out"; then
    RESOLVED_WHY="$RESOLVED_WHY; $id is not installed ('claude plugin list')"
    return 1
  fi
  cwd=$(pwd)
  cwd_phys=$(pwd -P)
  tab=$(printf '\t')
  if ! jq -e --arg id "$id" 'any(.[]; type == "object" and .id == $id and .enabled == true)' >/dev/null 2>&1 <<<"$out"; then
    RESOLVED_WHY="$RESOLVED_WHY; $id is installed but not enabled for $cwd"
    return 1
  fi
  cands=$(jq -r --arg id "$id" --arg cwd "$cwd" --arg phys "$cwd_phys" '
    [ .[]
      | select(type == "object" and .id == $id and .enabled == true)
      | select((.scope != "project" and .scope != "local")
               or .projectPath == $cwd or .projectPath == $phys)
      | { rank: ({"local": 0, "project": 1, "user": 2}[(.scope // "") | tostring] // 3),
          path: ((.installPath // "") | tostring),
          version: ((.version // "?") | tostring | if . == "" then "?" else . end),
          scope: ((.scope // "?") | tostring | if . == "" then "?" else . end) } ]
    | sort_by(.rank, .path)
    | .[] | [.path, .version, .scope] | @tsv' 2>/dev/null <<<"$out") || cands=""
  while IFS="$tab" read -r path version scope; do
    [ -n "$path" ] || continue
    p="$path/bin/$script"
    if [ -f "$p" ] && [ -x "$p" ] && _plugin_deps_absolute "$p"; then
      RESOLVED_SOURCE="plugin list: $id $version ($scope)"
      return 0
    fi
  done <<<"$cands"
  RESOLVED_WHY="$RESOLVED_WHY; no $id install that applies to $cwd has bin/$script"
  return 1
}

# plugin_deps_error DRIVER PLUGIN SCRIPT VAR RC [HINT] — print the standard
# message for a failed resolve_plugin_script call to stderr.
plugin_deps_error() {
  if [ "$5" = "2" ]; then
    echo "ERROR: $1: $RESOLVED_WHY (it must name the $2 plugin's bin/ directory)${6:+  $6}" >&2
  else
    echo "ERROR: $1 requires $3 from the $2 plugin — $RESOLVED_WHY. Install the sibling plugin for this host, or set $4=<$2 plugin>/bin${6:+  $6}" >&2
  fi
}
