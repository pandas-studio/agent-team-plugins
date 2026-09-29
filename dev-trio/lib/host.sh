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
  local host bound=""
  host="$(dev_trio_host)" || return $?
  if [ "$host" = codex ] && [ "$1" = reviewer ] && [ -z "${DEV_TRIO_REVIEWER_MODEL:-}" ]; then
    # A malformed config is rc 3 here, not "no binding" (#133).
    bound="$(registry_config_role dev-trio.reviewer)" || return 3
    if [ -z "$bound" ]; then
      printf 'claude\n'
      return 0
    fi
  fi
  registry_resolve_role dev-trio "$1" ""
}

# Check availability and, for Claude, login. Authentication and billing stay
# under Claude Code's own configuration; both subscription and API auth work.
dev_trio_check_cli() {
  local model="$1" bin host out rc=0 seen
  # Set to "failed" only by a failed login probe; cleared first so an inherited
  # value never outlives an earlier return. Read in the caller's shell (the
  # function must not run in a subshell), e.g. by ask-researcher.sh.
  DEV_TRIO_LOGIN_CHECK=
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
  out="$("$bin" auth status --json 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" |
       jq -se 'length == 1 and (.[0] | type) == "object" and .[0].loggedIn == true' >/dev/null 2>&1; then
    return 0
  fi
  # A sandbox that hides Keychain makes a logged-in Claude report exactly what a
  # logged-out one does (loggedIn: false, rc 1), so report what was observed and
  # leave the verdict to whoever knows whether this ran with host approval (#127).
  # CODEX_SANDBOX is printed as a fact, never branched on: it is a hint, not proof.
  seen="$(printf '%s' "$out" | jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0] | has("loggedIn"))
    then "loggedIn=\(.[0].loggedIn | tojson)" else "no login status" end' 2>/dev/null)" || seen=""
  [ -n "$seen" ] || seen="no login status"
  DEV_TRIO_LOGIN_CHECK=failed
  printf 'dev-trio: Claude login unverified in this environment (auth status: %s, rc=%s%s); no invocation started\n' \
    "$seen" "$rc" "${CODEX_SANDBOX:+, CODEX_SANDBOX=$CODEX_SANDBOX}" >&2
  echo 'dev-trio: a sandbox can hide the login (for example macOS Keychain); rerun this same command once with host approval. If an approved run still fails, check claude auth status in your own terminal.' >&2
  return 2
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
# print a UUID instead of a username. Parse either representation and reject a
# UUID allow entry if directory services cannot resolve the caller's UUID.
_dev_trio_darwin_acl_listing_safe() {
  /usr/bin/awk -v caller="$1" -v caller_uuid="$2" '
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

_dev_trio_darwin_acl_safe() {
  local listing caller_uuid=""
  listing=$(LC_ALL=C /bin/ls -lde "$1" 2>/dev/null) || return 1
  case "$listing" in
    *" allow "*) caller_uuid=$(/usr/bin/dsmemberutil getuuid -U "$2" 2>/dev/null) || caller_uuid="" ;;
  esac
  printf '%s\n' "$listing" | _dev_trio_darwin_acl_listing_safe "$2" "$caller_uuid"
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

# Execute a git probe command bounded by DEV_TRIO_GIT_TIMEOUT and, inside the
# snapshot block, by DEV_TRIO_SNAPSHOT_DEADLINE (#138): the same rule as
# call_timeout in workspace_snapshot.py. Once the deadline has passed, Git is
# not started and the probe returns 124, as a timed-out one does.
dev_trio_git_bounded() {
  local repo="$1"; shift
  python3 -c '
import math, os, signal, subprocess, sys, time
def main():
    repo = sys.argv[1]
    args = sys.argv[2:]
    try:
        timeout = float(os.environ.get("DEV_TRIO_GIT_TIMEOUT", "10.0"))
    except ValueError:
        timeout = 10.0
    if not math.isfinite(timeout) or timeout <= 0:
        timeout = 10.0
    try:
        deadline = float(os.environ.get("DEV_TRIO_SNAPSHOT_DEADLINE", ""))
    except ValueError:
        deadline = math.nan
    if math.isfinite(deadline):
        timeout = min(timeout, deadline - time.clock_gettime(time.CLOCK_MONOTONIC))
        if timeout <= 0:
            sys.exit(124)
    cmd = ["git", "-c", "core.fsmonitor=false", "-C", repo] + args
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    try:
        # This helper is for small rev-parse probes; do not use it for diffs.
        data, _ = proc.communicate(timeout=timeout)
        if proc.returncode == 0 and data:
            if len(data) > 8192:
                sys.exit(125)
            sys.stdout.buffer.write(data)
        sys.exit(proc.returncode)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            proc.kill()
        sys.exit(124)
try:
    main()
except Exception:
    # A probe that cannot run is 125, never 1 ("not a commit").
    sys.exit(125)
' "$repo" "$@" 2>/dev/null
}

# The directory handed to --add-dir and named in the prompt.
dev_trio_workspace_root() {
  local root="" bounded_rc=0
  root="$(dev_trio_git_bounded . rev-parse --show-toplevel 2>/dev/null)" || bounded_rc=$?
  # Never repeat a failed bounded probe with an unbounded Git command.
  # A non-repository has no root; another helper failure is diagnosed so a
  # subdirectory cannot silently masquerade as a verified repository root.
  if [ "$bounded_rc" -ne 0 ]; then
    [ "$bounded_rc" -eq 128 ] || echo "dev-trio: bounded workspace root unavailable (rc=$bounded_rc); using cwd" >&2
    pwd
    return 0
  fi
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
  else
    pwd
  fi
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
# exists is offered. In a paired agy 1.2.11 run, a full-volume log reached its
# allocated block limit; agy exited 2 without stderr. With agy 1.2.12, the
# same ask-researcher prompt completed on writable storage but exited 2 on a
# full volume, without an allow-list match in the private transcript. The
# failing syscall was not traced; see docs/agy-open-log-write-failure-149.md.
dev_trio_agy_cli_log() {
  local path
  path="$(dev_trio_agy_home)/log/cli-dev-trio-$1.log"
  ( umask 077 && set -C && : > "$path" ) 2>/dev/null || return 0
  [ -f "$path" ] && [ -w "$path" ] || return 0
  printf '%s\n' "$path"
}

# The fallback when agy's own log directory cannot take that file (a host
# sandbox that blocks agy home, #193): a new private directory under TMPDIR
# holding cli-dev-trio-TAG.log, created empty. Prints the directory, or nothing.
# Without a --log-file, agy writes its whole log — the user's allow list
# included — to stderr, which is the wrapper's transcript (measured with agy
# 1.2.13: all 41 allow rules). The log still holds that list, so it never goes
# in the workspace's log directory; the caller removes the directory when the
# run ends. The directory gets the same checks as a log directory
# (dev_trio_prepare_log_dir: caller-owned, no group/other write, trusted
# ancestors, no foreign ACL entry). A refusal is silent, since it leaves the
# behavior the wrapper had before this fallback. The allocated path is kept
# apart from the validated one so a refusal can still remove what it made.
# The body is its own subshell with its own traps, so the caller's are left
# alone. Until mkdir has decided, HUP/INT/TERM only record a pending exit code
# (#195): mktemp -u names the directory without creating it, and `allocated`
# is set only once mkdir -m 700 has made it, so the abort never removes a
# path this call did not create — not a name another process took first, not
# a symlink. A pending signal is honoured as soon as the abort traps are set.
dev_trio_agy_cli_log_private() (
  allocated=""
  pending=""
  _dev_trio_agy_private_abort() {
    if [ -n "$allocated" ] && [ ! -L "$allocated" ] && [ -d "$allocated" ]; then
      rm -f "$allocated/cli-dev-trio-$1.log" 2>/dev/null
      rmdir "$allocated" 2>/dev/null
    fi
    return 0
  }
  trap 'pending=129' HUP
  trap 'pending=130' INT
  trap 'pending=143' TERM
  candidate=$(mktemp -u -d "${TMPDIR:-/tmp}/dev-trio-agy.XXXXXX" 2>/dev/null) || candidate=""
  # mkdir runs with the three signals ignored, so a process-group signal
  # cannot kill it between creating the directory and reporting success; the
  # helper records the signal meanwhile and honours it right after.
  if [ -n "$candidate" ] && [ -z "$pending" ] \
     && ( trap '' HUP INT TERM; exec mkdir -m 700 "$candidate" ) 2>/dev/null; then
    allocated="$candidate"
  fi
  trap '_dev_trio_agy_private_abort "$1"; exit 129' HUP
  trap '_dev_trio_agy_private_abort "$1"; exit 130' INT
  trap '_dev_trio_agy_private_abort "$1"; exit 143' TERM
  if [ -n "$pending" ]; then
    _dev_trio_agy_private_abort "$1"
    exit "$pending"
  fi
  [ -n "$allocated" ] || exit 0
  dir=$(dev_trio_prepare_log_dir "$allocated" 2>/dev/null) || dir=""
  if [ -n "$dir" ] \
     && ( umask 077 && set -C && : > "$dir/cli-dev-trio-$1.log" ) 2>/dev/null \
     && [ -f "$dir/cli-dev-trio-$1.log" ] && [ -w "$dir/cli-dev-trio-$1.log" ]; then
    printf '%s\n' "$dir"
    exit 0
  fi
  _dev_trio_agy_private_abort "$1"
  exit 0
)

# Prompt section for a workspace-aware model. Kept outside the untrusted tags.
# dev_trio_replace_first TEXT FROM TO: set DEV_TRIO_REPLACED to TEXT with its
# first FROM replaced by TO, matching bytes under a function-local LC_ALL=C.
# ask-reviewer.sh swaps its default focus (ASCII but for one em dash) in a
# prompt that holds the whole snapshot. In a UTF-8 locale bash 3.2 took 0.56 s
# for that swap at 64 KB with one multibyte character in the text, and one
# wrapper run 120 s; under C it took 0.07 s and the run 1.6 s, with the same
# prompt bytes (#142). A FROM that starts with an ASCII byte cannot match
# inside a multibyte character, so the first match is the one UTF-8 finds;
# tests/test_dev_trio_hosts.py compares the two over invalid UTF-8 as well.
dev_trio_replace_first() {
  local LC_ALL=C
  DEV_TRIO_REPLACED="${1/"$2"/$3}"
}

dev_trio_agy_exec_note() {
  cat <<EOF_NOTE
# Execution environment
The repository root is \`$1\`; your working directory is \`$PWD\`. The root is also added to your workspace with --add-dir.
Tool commands run in headless mode, where a command that no allow-rule matches is denied and ends this run with no answer at all. Keep shell commands to these read-only git forms, one simple command per tool call: \`git status\`, \`git diff\`, \`git log\` and \`git show\`, with arguments as needed. When the task requires untracked files, use \`git status --short --untracked-files=all\` instead of \`git ls-files\` to list them (plain \`git status --short\` folds an untracked directory into one line). Read files relevant to the requested scope with your built-in file viewer. No \`cd\`, no \`&&\`, \`||\` or \`;\`, no pipes, and no redirections such as \`2>/dev/null\`. Read and search files with your built-in file viewer and search tools, not with shell commands such as \`cat\`, \`grep\`, \`git grep\` or \`find\`. A test runner, build, interpreter such as \`python3\` or \`node\`, or script counts as a command you cannot run here: if confirming something would need one, name the command and record the gap in your answer instead. If a command is denied, do not retry a variant of it.
EOF_NOTE
  # Default reviews already have the full working-tree checklist in their role
  # and focus. A named target should not inherit a whole-tree sweep, while a
  # targetless reviewer focus still uses the role's default checklist.
  if [ "${2:-0}" != 1 ]; then
    cat <<'EOF_NOTE'
Stay within the requested focus. If it names a file or revision range, inspect that target and only files with a concrete dependency needed to understand it. Limit git commands to the named file or range when possible. Do not open another file merely because a status, diff summary, or commit history lists it. In that case, do not run `git status` or sweep other changed or untracked files unless the task explicitly asks about the working tree. If no file or revision range is named, follow the role's default inspection checklist.
EOF_NOTE
  fi
}

# Scan focus string for an explicit revision range A..B or A...B.
# Verifies both endpoints as commits in git before accepting. Returns 0 with the
# range, 1 when there is no single verified range, 124 when a probe timed out,
# and 3 when a probe failed (anything but 0, 1 for "not a commit", or 124).
dev_trio_extract_git_range() {
  local focus="$1"
  local repo="${2:-.}"
  local token left right op candidate left_rc right_rc
  local restore_f=0
  local matched_range=""
  local probe_count=0
  case "$-" in *f*) restore_f=1 ;; esac
  set -f
  for token in $focus; do
    case "$token" in
      *...*)
        op="..."
        left="${token%%...*}"
        right="${token#*...}"
        ;;
      *..*)
        op=".."
        left="${token%%..*}"
        right="${token#*..}"
        ;;
      *) continue ;;
    esac
    left="${left#[(\"\'\`]}"
    left="${left#[(\"\'\`]}"
    right="${right%[.,;:)\"\'\`]}"
    right="${right%[.,;:)\"\'\`]}"
    right="${right%[.,;:)\"\'\`]}"
    case "$left" in -*|""|*[!A-Za-z0-9_.~^/-]*) continue ;; esac
    case "$right" in -*|""|*[!A-Za-z0-9_.~^/-]*) continue ;; esac
    candidate="${left}${op}${right}"
    # Repeated mentions of the accepted range need no new Git probes.
    [ "$candidate" = "$matched_range" ] && continue
    probe_count=$((probe_count + 1))
    if [ "$probe_count" -gt 4 ]; then
      [ "$restore_f" = 1 ] || set +f
      return 1
    fi
    left_rc=0
    right_rc=0
    dev_trio_git_bounded "$repo" rev-parse --verify --quiet "$left^{commit}" >/dev/null 2>&1 || left_rc=$?
    if [ "$left_rc" -eq 0 ]; then
      dev_trio_git_bounded "$repo" rev-parse --verify --quiet "$right^{commit}" >/dev/null 2>&1 || right_rc=$?
    fi
    if [ "$left_rc" -eq 124 ] || [ "$right_rc" -eq 124 ]; then
      # A timed-out probe is not "no range"; the caller records a timeout.
      [ "$restore_f" = 1 ] || set +f
      return 124
    fi
    if [ "$left_rc" -gt 1 ] || [ "$right_rc" -gt 1 ]; then
      [ "$restore_f" = 1 ] || set +f
      return 3
    fi
    if [ "$left_rc" -eq 0 ] && [ "$right_rc" -eq 0 ]; then
      if [ -n "$matched_range" ]; then
        if [ "$matched_range" != "$candidate" ]; then
          # Multiple distinct ranges detected; ambiguous, do not precompute snapshot
          [ "$restore_f" = 1 ] || set +f
          return 1
        fi
      fi
      matched_range="$candidate"
    fi
  done
  [ "$restore_f" = 1 ] || set +f
  if [ -n "$matched_range" ]; then
    printf '%s\n' "$matched_range"
    return 0
  fi
  return 1
}

# The deadline for the whole snapshot block (#138): CLOCK_MONOTONIC now plus
# DEV_TRIO_SNAPSHOT_TIMEOUT seconds (default 30; an invalid or non-positive
# value means 30). The clock is system-wide, so every later process in the
# block compares against the same value. Prints nothing when python3 fails.
dev_trio_snapshot_deadline() {
  python3 -c '
import math, os, time
try:
    budget = float(os.environ.get("DEV_TRIO_SNAPSHOT_TIMEOUT", "30"))
except ValueError:
    budget = 30.0
if not math.isfinite(budget) or budget <= 0:
    budget = 30.0
print(repr(time.clock_gettime(time.CLOCK_MONOTONIC) + budget))
' 2>/dev/null
}

# Succeeds only while DEV_TRIO_SNAPSHOT_DEADLINE is set and still ahead. Any
# failure to tell counts as passed, so a snapshot is never injected on a guess.
dev_trio_snapshot_in_time() {
  [ -n "${DEV_TRIO_SNAPSHOT_DEADLINE:-}" ] || return 1
  python3 -c '
import sys, time
sys.exit(0 if time.clock_gettime(time.CLOCK_MONOTONIC) < float(sys.argv[1]) else 1)
' "$DEV_TRIO_SNAPSHOT_DEADLINE" 2>/dev/null
}

# Invoke python workspace snapshot helper.
dev_trio_workspace_snapshot() {
  local repo="$1" scope="$2" target="$3" budget="$4" log_dir="$5"
  local plugin_root
  plugin_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  python3 "$plugin_root/lib/workspace_snapshot.py" "$repo" "$scope" "$target" "$budget" "${log_dir:-}" 2>/dev/null
}
