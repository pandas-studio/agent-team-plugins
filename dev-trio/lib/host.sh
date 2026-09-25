#!/usr/bin/env bash
# Host defaults are local to dev-trio; the shared registry remains unchanged.
# Source registry.sh before calling these functions.
_DEV_TRIO_OS=$(uname -s) || _DEV_TRIO_OS=unknown

dev_trio_host() {
  case "${DEV_TRIO_PM_HOST:-claude}" in
    claude|codex) printf '%s\n' "${DEV_TRIO_PM_HOST:-claude}" ;;
    *) echo 'dev-trio: DEV_TRIO_PM_HOST must be claude or codex' >&2; return 2 ;;
  esac
}

dev_trio_resolve_role() {
  local host
  host="$(dev_trio_host)" || return $?
  if [ "$host" = codex ] && [ "$1" = reviewer ] &&
     [ -z "${DEV_TRIO_REVIEWER_MODEL:-}" ] &&
     [ -z "$(registry_config_role dev-trio.reviewer)" ]; then
    printf 'claude\n'
  else
    registry_resolve_role dev-trio "$1" ""
  fi
}

# Check availability and, for Claude, login. Authentication and billing stay
# under Claude Code's own configuration; both subscription and API auth work.
dev_trio_check_cli() {
  local model="$1" bin auth host
  host="$(dev_trio_host)" || return $?
  [ "$host" = codex ] || return 0
  bin="$(registry_resolve_command "$model")" || return $?
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "dev-trio: CLI not found: $bin (model=$model)" >&2
    return 2
  fi
  case "$model:${bin##*/}" in
    claude:*|claude-write:*|*:claude|*:claude.exe) ;;
    *) return 0 ;;
  esac
  if ! auth="$("$bin" auth status --json 2>/dev/null)"; then
    echo 'dev-trio: could not check Claude login; no invocation started' >&2
    return 2
  fi
  if ! printf '%s' "$auth" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    echo 'dev-trio: Claude login not confirmed; check claude auth status in a terminal (sandbox keychain access may be restricted)' >&2
    return 2
  fi
}

# Keep input-bearing artifacts in a directory another user cannot replace.
# Existing directories are inspected, never chmodded. A root/current-user-owned
# sticky ancestor (such as /tmp) is safe for a caller-owned child directory.
_dev_trio_dir_mode_owner() {
  if [ "$_DEV_TRIO_OS" = Darwin ]; then
    /usr/bin/stat -L -f '%Mp%Lp %u %g' "$1"
  else
    stat -L -c '%a %u %g' "$1"
  fi
}

_dev_trio_symlink_owner() {
  if [ "$_DEV_TRIO_OS" = Darwin ]; then
    /usr/bin/stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

# macOS ACL allow entries can grant writes independently of mode bits. ls may
# print a UUID instead of a username; resolve the caller's UUID through the
# directory service rather than assuming its form from the numeric UID.
_dev_trio_darwin_acl_safe() {
  local listing caller_uuid=""
  listing=$(LC_ALL=C /bin/ls -lde "$1" 2>/dev/null) || return 1
  case "$listing" in
    *" allow "*) caller_uuid=$(/usr/bin/dsmemberutil getuuid -U "$2" 2>/dev/null) || caller_uuid="" ;;
  esac
  printf '%s\n' "$listing" | /usr/bin/awk -v caller="$2" -v caller_uuid="$caller_uuid" '
    BEGIN { caller_uuid = toupper(caller_uuid) }
    NR == 1 { next }
    /^[[:space:]]*[0-9]+:/ {
      ace = $0
      sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "", ace)
      if (ace ~ /[[:space:]]allow[[:space:]]/) {
        sub(/[[:space:]]allow[[:space:]].*$/, "", ace)
        sub(/[[:space:]]inherited$/, "", ace)
        if (ace != "user:" caller && toupper(ace) != caller_uuid) bad = 1
      } else if (ace !~ /[[:space:]]deny[[:space:]]/) bad = 1
      next
    }
    NF { bad = 1 }
    END { exit bad }
  '
}

# A matching user/group name alone does not establish that a group is private.
# Only macOS uses this exception. Linux account enumeration cannot establish
# exclusive access to a group-writable ancestor across all local NSS sources.
_dev_trio_private_group_gid() {
  local user_name group_name gid group_record user_records
  [ "$_DEV_TRIO_OS" = Darwin ] || return 1
  user_name=$(id -un) && group_name=$(id -gn) && gid=$(id -g) || return 1
  [ -n "$user_name" ] && [ "$user_name" = "$group_name" ] || return 1
  group_record=$(dscacheutil -q group -a gid "$gid") || return 1
  user_records=$(dscacheutil -q user) || return 1
  printf '%s\n' "$group_record" | awk -v user="$user_name" -v gid="$gid" '
    $1 == "name:" { names++; if ($2 != user) bad = 1 }
    $1 == "gid:" { gids++; if ($2 != gid) bad = 1 }
    $1 == "users:" { for (i = 2; i <= NF; i++) if ($i != user) bad = 1 }
    END { exit (bad || names != 1 || gids != 1) }
  ' || return 1
  printf '%s\n' "$user_records" | awk -v user="$user_name" -v gid="$gid" '
    $1 == "name:" { name = $2 }
    $1 == "gid:" && $2 == gid { if (name == user) own = 1; else bad = 1 }
    END { exit (bad || !own) }
  ' || return 1
  printf '%s\n' "$gid"
}

_dev_trio_check_log_ancestors() {
  local path="$1" team_dir="$2" uid="$3" private_gid="$4" caller="${5:-}" mode owner gid details link_owner repair
  if [ "$_DEV_TRIO_OS" = Darwin ] && [ -z "$caller" ]; then
    caller=$(id -un) || return 1
  fi
  while :; do
    if [ -L "$path" ]; then
      link_owner=$(_dev_trio_symlink_owner "$path") || return 1
      if [ "$link_owner" != 0 ] && [ "$link_owner" != "$uid" ]; then
        echo "dev-trio: unsafe log symlink: $path (must be owned by root or the caller)" >&2
        return 1
      fi
    fi
    if [ "$_DEV_TRIO_OS" = Darwin ] && ! _dev_trio_darwin_acl_safe "$path" "$caller"; then
      echo "dev-trio: unsafe log ACL: $path (allow entry for another principal or ACL unreadable)" >&2
      return 1
    fi
    details=$(_dev_trio_dir_mode_owner "$path") || return 1
    read -r mode owner gid <<<"$details"
    mode=$((8#$mode))
    if [ "$path" = "$team_dir" ]; then
      if [ "$owner" != "$uid" ]; then
        echo "dev-trio: unsafe team log directory: $path (must be caller-owned)" >&2
        return 1
      elif (( (mode & 0022) != 0 )); then
        printf 'dev-trio: unsafe team log directory: %s (remove group/other write: chmod go-w %q)\n' "$path" "$path" >&2
        return 1
      fi
    elif [ "$owner" != 0 ] && [ "$owner" != "$uid" ]; then
      echo "dev-trio: unsafe log ancestor: $path (must be owned by root or the caller)" >&2
      return 1
    elif (( (mode & 0022) != 0 )); then
      if (( (mode & 01000) != 0 )); then
        : # Trusted sticky directory such as /tmp.
      elif [ "$_DEV_TRIO_OS" = Darwin ] && (( (mode & 0002) == 0 )) && [ "$owner" = "$uid" ] \
           && [ "$gid" = "$private_gid" ]; then
        : # Caller-owned ancestor in the caller's user-private group.
      else
        if (( (mode & 0022) == 0022 )); then
          repair='chmod go-w'
        elif (( (mode & 0020) != 0 )); then
          repair='chmod g-w'
        else
          repair='chmod o-w'
        fi
        if [ "$owner" = 0 ]; then
          printf 'dev-trio: unsafe log ancestor: %s (owned by root; choose a private log root or ask an administrator to run %s %q)\n' \
            "$path" "$repair" "$path" >&2
        else
          printf 'dev-trio: unsafe log ancestor: %s (remove group/other write: %s %q)\n' \
            "$path" "$repair" "$path" >&2
        fi
        return 1
      fi
    fi
    [ "$path" != / ] || break
    path=$(dirname "$path")
  done
}

# Check the existing path before creating anything, then return the physical
# team directory so artifact paths cannot re-traverse a validated symlink.
dev_trio_prepare_log_dir() {
  local requested="$1" physical uid caller private_gid existing existing_physical team_arg
  case "$requested" in /*) ;; *) requested="$PWD/$requested" ;; esac
  case "$_DEV_TRIO_OS" in Darwin|Linux) ;; *) echo 'dev-trio: unsupported OS for log validation' >&2; return 2 ;; esac
  uid=$(id -u) || return 2
  caller=$(id -un) || caller=""
  if [ -z "$caller" ]; then
    echo 'dev-trio: cannot identify caller for log ACL validation' >&2
    return 2
  fi
  private_gid=-1
  if [ "$_DEV_TRIO_OS" = Darwin ]; then
    private_gid=$(_dev_trio_private_group_gid) || private_gid=-1
  fi
  existing="$requested"
  while [ ! -e "$existing" ] && [ ! -L "$existing" ]; do
    existing=$(dirname "$existing")
  done
  existing_physical=$(cd -P "$existing" && pwd -P) || return 2
  team_arg=""
  [ "$existing" != "$requested" ] || team_arg="$existing"
  _dev_trio_check_log_ancestors "$existing" "$team_arg" "$uid" "$private_gid" "$caller" || return 2
  team_arg=""
  [ "$existing" != "$requested" ] || team_arg="$existing_physical"
  _dev_trio_check_log_ancestors "$existing_physical" "$team_arg" "$uid" "$private_gid" "$caller" || return 2
  (umask 077; mkdir -p "$requested") || return 2
  physical=$(cd -P "$requested" && pwd -P) || return 2
  _dev_trio_check_log_ancestors "$physical" "$physical" "$uid" "$private_gid" "$caller" || return 2
  _dev_trio_check_log_ancestors "$requested" "$requested" "$uid" "$private_gid" "$caller" || return 2
  printf '%s\n' "$physical"
}

dev_trio_fd_size() {
  if [ "$_DEV_TRIO_OS" = Darwin ]; then
    /usr/bin/stat -L -f '%z' "/dev/fd/$1"
  else
    stat -L -c '%s' "/dev/fd/$1"
  fi
}

dev_trio_fd_matches_path() {
  local format path_id fd_id
  if [ "$_DEV_TRIO_OS" = Darwin ]; then
    # devfs reports its own device number for /dev/fd, even with stat -L.
    # The validated team directory keeps this regular path on one filesystem;
    # another user cannot replace it with a path on a different device.
    format='%i %u'
    path_id=$(/usr/bin/stat -L -f "$format" "$1" 2>/dev/null) || return 1
    fd_id=$(/usr/bin/stat -L -f "$format" "/dev/fd/$2" 2>/dev/null) || return 1
  else
    format='%d %i %u'
    path_id=$(stat -L -c "$format" "$1" 2>/dev/null) || return 1
    fd_id=$(stat -L -c "$format" "/dev/fd/$2" 2>/dev/null) || return 1
  fi
  [ "$path_id" = "$fd_id" ]
}

# Check the descriptor before writing even the first input-bearing header.
dev_trio_new_log_fd_is_private() {
  local path="$1" fd="$2" uid="$3" details mode owner gid size
  [ ! -L "$path" ] && [ -f "$path" ] && [ -f "/dev/fd/$fd" ] || return 1
  # Darwin's /dev/fd mode describes the devfs node, not the opened file.
  # Read metadata through the path, then confirm it still names this fd.
  details=$(_dev_trio_dir_mode_owner "$path") || return 1
  read -r mode owner gid <<<"$details"
  size=$(dev_trio_fd_size "$fd") || return 1
  mode=$((8#$mode))
  [ "$owner" = "$uid" ] && [ "$size" = 0 ] && (( (mode & 0077) == 0 )) \
    && dev_trio_fd_matches_path "$path" "$fd"
}

# ---- agy workspace (#103) ---------------------------------------------------
# Headless agy does not know which directory it was started for. Left to guess,
# it builds `cd <repo> && git …` or `lsof -p $$ || pwd`, which no simple
# command(...) allow-rule matches, and print mode auto-denies them. These give
# the wrappers what to tell it; they apply to any model that defines
# workspace_args (registry_has_workspace), not to a binary name.

# The directory handed to --add-dir and named in the prompt.
dev_trio_workspace_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

dev_trio_agy_home() {
  printf '%s\n' "${DEV_TRIO_AGY_HOME:-$HOME/.gemini/antigravity-cli}"
}

# A per-run --log-file path inside agy's own log directory, or nothing. agy
# 1.2.9 given a log path it cannot create still runs, but writes its whole log
# — including the settings' allow list — to stderr, which is the wrapper's
# transcript (measured 2026-09-23: rc 0, 24.8 KB on stderr). A writable
# directory is not enough to know it can (no search permission, a full disk),
# so the file itself is created here, private and new, and only a file that
# exists is offered. agy writes into a file that already exists and leaves its
# mode alone (measured: 0600 kept, nothing on stderr).
dev_trio_agy_cli_log() {
  local path
  path="$(dev_trio_agy_home)/log/cli-dev-trio-$1.log"
  ( umask 077 && set -C && : > "$path" ) 2>/dev/null || return 0
  [ -f "$path" ] && [ -w "$path" ] || return 0
  printf '%s\n' "$path"
}

# Prompt section for a workspace-aware model. Kept outside the untrusted tags.
dev_trio_agy_exec_note() {
  cat <<EOF_NOTE
# Execution environment
The repository root is \`$1\`; your working directory is \`$PWD\`. The root is also added to your workspace with --add-dir.
Tool commands run in headless mode, where a command that no allow-rule matches is denied and ends this run with no answer at all. Keep shell commands to these read-only git forms, one simple command per tool call: \`git status\`, \`git diff\`, \`git log\` and \`git show\`, with arguments as needed. For the list of untracked files, use \`git status --short --untracked-files=all\` instead of \`git ls-files\` (plain \`git status --short\` folds an untracked directory into one line), then read every file it lists. No \`cd\`, no \`&&\`, \`||\` or \`;\`, no pipes, and no redirections such as \`2>/dev/null\`. Read and search files with your built-in file viewer and search tools, not with shell commands such as \`cat\`, \`grep\`, \`git grep\` or \`find\`. A test runner, build, interpreter such as \`python3\` or \`node\`, or script counts as a command you cannot run here: if confirming something would need one, name the command and record the gap in your answer instead. If a command is denied, do not retry a variant of it.
EOF_NOTE
}
