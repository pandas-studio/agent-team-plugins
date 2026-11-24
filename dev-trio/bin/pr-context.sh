#!/usr/bin/env bash
# pr-context.sh — resolve a pull request into a review range and a context file.
#
# Usage:
#   pr-context.sh 55                         # pull request number
#   pr-context.sh '#55'
#   pr-context.sh https://github.com/o/r/pull/55
#   pr-context.sh 55 --with-context notes.md # append a file to the context
#   pr-context.sh -h | --help                # usage; runs nothing, exit 0
#
# It asks gh once for the pull request's commits, checks that both are in this
# repository, takes their merge base, writes a context file and prints one JSON
# line naming that file and a range focus:
#
#   ask-reviewer.sh --with-context <context_file> -- "<focus>"
#
# It starts no review and never fetches. A commit that is missing locally is
# reported (exit 4) with the fetch command to run; nothing is fetched here,
# and in a partial clone the probes run with lazy fetching switched off.
#
# Arguments are parsed before anything is loaded, so --help and a usage error
# (exit 2) run nothing. Only a token shaped like an option is one, as in
# ask-reviewer.sh.
#
# gh runs in the foreground with no timeout of its own: the caller's limit, or
# Ctrl-C, bounds it. No signal is trapped. A run that is signalled while it
# writes may leave a partly written context file in the log directory.
#
# Each failure this script detects ends with its own marker line on stderr.
# A tool that fails where no check expects it (a library that vanishes after
# its check, an rm that cannot remove) ends the run under set -e with that
# tool's status and no marker; any status other than 0 means discard stdout.
set -euo pipefail
# What this script makes is private, here-string temporaries included: under a
# caller's mask of 0400 Bash 3.2 cannot reopen its own. gh gets the caller's.
CALLER_UMASK=$(umask)
umask 077
# Every pattern below is ASCII. Bash 3.2 matches a bracket range by the
# locale's collation, so under a UTF-8 locale [A-Za-z] would take an é.
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: pr-context.sh [--with-context FILE] <N | #N | PR URL>
       pr-context.sh -h | --help

Resolves a pull request for a review: asks gh for its head and base commits,
checks that both are in this repository, takes their merge base, writes a
context file and prints one JSON line on stdout:

  {"pr_context_version":1,"number":55,"url":"...","head":"<oid>","base":"<oid>",
   "merge_base":"<oid>","context_file":"/abs/path","focus":"review <mb>..<head> (PR #55)"}

Pass it on as:  ask-reviewer.sh --with-context <context_file> -- "<focus>"

It starts no review and never fetches. The repository is the one gh selects in
this directory (GH_REPO and `gh repo set-default` apply). A PR URL must name
that same repository.

Options:
  --with-context FILE  text to append to the context file (read once, before gh)
  --                   end of options
  -h, --help           show this help and exit

Environment:
  DEV_TRIO_LOG_DIR      log root (default: $PWD/.dev-trio/log)
  DEV_TRIO_GIT_TIMEOUT  seconds for each git probe (default: 10.0)
  DEV_TRIO_GH_CLI       gh binary (default: gh)

gh runs with no timeout of its own; the caller's limit bounds it.

Exit: 0 resolved; 4 the head or base commit is missing locally (what to fetch
is printed, nothing is fetched) or the two share no history here; 2 a usage
error or any other failure. After a usage error the last stderr line is the
--help hint; after a failure the script detects it is "(pr: N, missing: ...,
rc=4)" or "(pr: N, failed: ..., rc=2)". A signal, or a tool failing where no
check expects it, ends it with that status and no marker. Discard stdout
whenever the exit status is not 0.
EOF
}

usage_error() {
  echo "error: $1" >&2
  echo "Try 'pr-context.sh --help'." >&2
  exit 2
}

# -name or --name[=value], where name is a letter then [A-Za-z0-9_-]. Anything
# else — including prose that merely starts with a dash — is a positional.
is_option_shaped() {
  _opt_name="${1%%=*}"
  case "$_opt_name" in
    --[A-Za-z]*) _opt_name="${_opt_name#--}" ;;
    -[A-Za-z]*)  _opt_name="${_opt_name#-}" ;;
    *) return 1 ;;
  esac
  case "$_opt_name" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

ATTACH_FILE=""
HAVE_ATTACH=0
REF=""
POSITIONAL_SEEN=0
take_positional() {
  [ "$POSITIONAL_SEEN" -eq 0 ] || usage_error "unexpected extra positional argument: $1"
  POSITIONAL_SEEN=1
  REF="$1"
}
# One left-to-right scan. --help wins where it is met; the number of
# positionals and the reference's form are checked only after the scan.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --with-context)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || usage_error "$1 requires a file path"
      ATTACH_FILE="$2"; HAVE_ATTACH=1; shift 2 ;;
    --) shift
        while [ $# -gt 0 ]; do take_positional "$1"; shift; done ;;
    *)
      ! is_option_shaped "$1" || usage_error "unknown option: $1"
      take_positional "$1"; shift ;;
  esac
done
[ "$POSITIONAL_SEEN" -eq 1 ] || usage_error "a pull request number or URL is required"

# N, #N, or https://<host>/<owner>/<repo>/pull/<N> with at most one trailing
# slash. gh itself reads 0263 as 263, so leading zeros are dropped; a URL with
# anything after the number is refused rather than guessed at.
bad_ref() { usage_error "not a pull request number or URL: $REF"; }
GIVEN_REPO=""
case "$REF" in
  ""|*[!A-Za-z0-9._/:#-]*) bad_ref ;;
esac
case "$REF" in
  https://*)
    _rest="${REF#https://}"
    _rest="${_rest%/}"
    case "$_rest" in */) bad_ref ;; esac
    IFS=/ read -r _host _owner _repo _pull N _extra <<<"$_rest"
    [ "$_pull" = pull ] && [ -z "$_extra" ] || bad_ref
    for _seg in "$_host" "$_owner" "$_repo"; do
      case "$_seg" in ""|*[!A-Za-z0-9._-]*) bad_ref ;; esac
    done
    GIVEN_REPO="$_host/$_owner/$_repo"
    ;;
  \#*) N="${REF#\#}" ;;
  *) N="$REF" ;;
esac
case "$N" in ""|*[!0-9]*) bad_ref ;; esac
[ "${#N}" -le 12 ] || bad_ref
while [ "${N#0}" != "$N" ]; do N="${N#0}"; done
[ -n "$N" ] && [ "${#N}" -le 9 ] || bad_ref

say() { printf '[pr-context] %s\n' "$1" >&2; }
# stop "failed: setup" 2 — the marker is always the last stderr line.
stop() {
  printf '(pr: %s, %s, rc=%s)\n' "$N" "$1" "$2" >&2
  exit "$2"
}

# ---- 2 · setup: nothing is created here ------------------------------------
# dev_trio_git_bounded reads DEV_TRIO_SNAPSHOT_DEADLINE as its deadline; an
# inherited, expired one would stop every probe. GIT_CONFIG redirects
# `git config` only, so with it set the partial-clone check below would read a
# different file than the object lookups use (measured: rc 1 in a partial
# clone). GIT_NO_LAZY_FETCH covers every git started from here, gh's included.
unset DEV_TRIO_SNAPSHOT_DEADLINE GIT_CONFIG
export GIT_NO_LAZY_FETCH=1

# CDPATH would make cd print the directory it found, a second line in the path.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || stop "failed: setup" 2
PLUGIN_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd) || stop "failed: setup" 2
for _lib in host.sh namespace.sh; do
  { [ -f "$PLUGIN_ROOT/lib/$_lib" ] && [ -r "$PLUGIN_ROOT/lib/$_lib" ]; } ||
    { say "$_lib is not a readable file at $PLUGIN_ROOT/lib/$_lib"; stop "failed: setup" 2; }
done
# shellcheck source=../lib/host.sh
. "$PLUGIN_ROOT/lib/host.sh"
dev_trio_check_platform || stop "failed: setup" 2
# dev_trio_prepare_log_dir refuses any other system, but only at the write
# step; refuse here, before gh is called.
case "$_DEV_TRIO_OS" in
  Darwin|Linux) ;;
  *) say "unsupported platform: $_DEV_TRIO_OS"; stop "failed: setup" 2 ;;
esac
# shellcheck source=../lib/namespace.sh
. "$PLUGIN_ROOT/lib/namespace.sh"
command -v jq >/dev/null 2>&1 || { say "jq not found"; stop "failed: setup" 2; }
# The git probes run through python3 (dev_trio_git_bounded).
command -v python3 >/dev/null 2>&1 || { say "python3 not found"; stop "failed: setup" 2; }
TEAM=$(agent_team_detect_team) || stop "failed: setup" 2
LOG_ROOT="${DEV_TRIO_LOG_DIR:-$PWD/.dev-trio/log}/$TEAM"

# ---- 3 · attachment: read once, as text, before gh -------------------------
# The path is opened by redirection, never passed to cat: `cat -- -` reads
# stdin. The wrapper reads a context file the same way (command substitution),
# so trailing newlines and NUL bytes would not survive it either.
ATTACH=""
if [ "$HAVE_ATTACH" -eq 1 ]; then
  if [ ! -f "$ATTACH_FILE" ] || [ ! -r "$ATTACH_FILE" ]; then
    say "attachment is not a readable regular file: $ATTACH_FILE"
    stop "failed: attachment" 2
  fi
  ATTACH=$(cat <"$ATTACH_FILE") || {
    say "attachment could not be read: $ATTACH_FILE"
    stop "failed: attachment" 2
  }
fi

# ---- 4 · partial clone: decided once, before gh ----------------------------
# Any of these three keys makes object lookups fetch what is missing
# (measured: the filter key alone is enough). Git 2.45.0 added
# --no-lazy-fetch; an older Git answers 129 to it, and in a partial clone that
# is where this stops, since a probe there would be a fetch. A repository that
# becomes a partial clone while this runs is not covered on such a Git.
git_probe() { dev_trio_git_bounded . "$@"; }
probe_failed() {
  say "git $1 failed (rc=$2)"
  stop "failed: git-probe" 2
}
NOLAZY=()
_rc=0
git_probe config --get-regexp '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$' >/dev/null || _rc=$?
case "$_rc" in
  1) ;;
  0)
    _rc=0
    git_probe --no-lazy-fetch version >/dev/null || _rc=$?
    case "$_rc" in
      0) NOLAZY=(--no-lazy-fetch) ;;
      129)
        say "this Git does not accept --no-lazy-fetch; a partial clone needs Git 2.45.0 or newer"
        stop "failed: git-probe" 2 ;;
      *) probe_failed version "$_rc" ;;
    esac ;;
  *) probe_failed config "$_rc" ;;
esac

# ---- 5 · gh, once ----------------------------------------------------------
# The number is passed even when a URL was given: gh resolves a URL in the
# repository the URL names, not in this one. With `number` as the only field
# gh answers without asking the API, so the field list is part of the check.
GH_BIN="${DEV_TRIO_GH_CLI:-gh}"
command -v "$GH_BIN" >/dev/null 2>&1 || { say "gh not found: $GH_BIN"; stop "failed: gh-missing" 2; }
FIELDS=number,url,title,baseRefName,baseRefOid,headRefName,headRefOid
_rc=0
GH_OUT=$(umask "$CALLER_UMASK"; GH_PROMPT_DISABLED=1 "$GH_BIN" pr view "$N" --json "$FIELDS" </dev/null) || _rc=$?
[ "$_rc" -eq 0 ] || { say "gh exited $_rc"; stop "failed: gh-failed" 2; }

# ---- 6 · validate, in one jq call over stdin -------------------------------
# Lines out: head, base, url, base branch (empty unless printable in a
# command), host/owner/repo, the URL comparison, the seven fields rewritten.
_rc=0
VALID=$(jq -rs --argjson n "$N" --arg given "$GIVEN_REPO" '
  def oid: type == "string" and (test("\\A[0-9a-f]{40}\\z") or test("\\A[0-9a-f]{64}\\z"));
  if length != 1 then error("not one value") else .[0] end
  | if type != "object" then error("not an object") else . end
  | if ((.number | type) == "number" and .number == $n
        and (.url | type) == "string"
        and (.url | test("\\Ahttps://[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/" + ($n | tostring) + "\\z"))
        and (.title | type) == "string"
        and (.baseRefName | type) == "string"
        and (.headRefName | type) == "string"
        and (.baseRefOid | oid) and (.headRefOid | oid)
        and (.baseRefOid | length) == (.headRefOid | length))
    then . else error("unexpected fields") end
  | (.url | ltrimstr("https://") | split("/")[0:3] | join("/")) as $repo
  | .headRefOid, .baseRefOid, .url,
    (if (.baseRefName | test("\\A[A-Za-z0-9._/][A-Za-z0-9._/-]*\\z")) then .baseRefName else "" end),
    $repo,
    (if $given == "" or ($given | ascii_downcase) == ($repo | ascii_downcase) then "same" else "other" end),
    ({number, url, title, baseRefName, baseRefOid, headRefName, headRefOid} | tojson)
' 2>/dev/null <<<"$GH_OUT") || _rc=$?
if [ "$_rc" -ne 0 ]; then
  say "gh returned unexpected data for PR #$N"
  stop "failed: gh-data" 2
fi
{
  IFS= read -r HEAD_OID
  IFS= read -r BASE_OID
  IFS= read -r PR_URL
  IFS= read -r BASE_REF
  IFS= read -r REPO_PATH
  IFS= read -r URL_CHECK
  IFS= read -r PR_JSON
} <<<"$VALID"
if [ "$URL_CHECK" != same ]; then
  say "$REF is not $PR_URL"
  stop "failed: url-mismatch" 2
fi

# ---- 7 · the commits -------------------------------------------------------
# Both probes always run, so one report names everything that is missing.
# rc 0 present, 1 absent, anything else the probe itself failed. A present
# object whose commit is another oid (a tag object peels to one) is not what
# gh named.
probe_commit() {
  local out rc=0
  out=$(git_probe ${NOLAZY[@]+"${NOLAZY[@]}"} rev-parse --verify --quiet "$1^{commit}") || rc=$?
  PROBE_RC=$rc
  case "$rc" in
    0) if [ "$out" = "$1" ]; then PROBE=present; else PROBE=other; fi ;;
    1) PROBE=absent ;;
    *) PROBE=error ;;
  esac
}
probe_commit "$HEAD_OID"; HEAD_STATE=$PROBE; HEAD_RC=$PROBE_RC
probe_commit "$BASE_OID"; BASE_STATE=$PROBE; BASE_RC=$PROBE_RC
if [ "$HEAD_STATE" = error ] || [ "$BASE_STATE" = error ]; then
  [ "$HEAD_STATE" != error ] || say "git rev-parse failed (rc=$HEAD_RC)"
  [ "$BASE_STATE" != error ] || say "git rev-parse failed (rc=$BASE_RC)"
  stop "failed: git-probe" 2
fi
if [ "$HEAD_STATE" = other ] || [ "$BASE_STATE" = other ]; then
  [ "$HEAD_STATE" != other ] || say "$HEAD_OID is not a commit"
  [ "$BASE_STATE" != other ] || say "$BASE_OID is not a commit"
  stop "failed: gh-data" 2
fi

# The remote to name in a fetch command: one whose fetch URL, after
# url.<base>.insteadOf, is the pull request's repository. `origin` if it is
# one, else the first by name, else the repository URL. Names that are not
# plain are never put in a command.
pick_remote() {
  local listing name
  REMOTE="https://$REPO_PATH"
  REMOTE_PRINTABLE=1
  listing=$(git_probe remote -v) || return 0
  name=$(printf '%s\n' "$listing" | awk -v want="$REPO_PATH" '
    BEGIN { want = tolower(want) }
    NF == 3 && $3 == "(fetch)" {
      url = tolower($2)
      sub(/\/$/, "", url)
      sub(/\.git$/, "", url)
      if (url ~ /^https:\/\//) path = substr(url, 9)
      else if (url ~ /^ssh:\/\/git@/) path = substr(url, 11)
      else if (url ~ /^git@[^:\/]+:/) { path = substr(url, 5); sub(/:/, "/", path) }
      else next
      if (path != want) next
      if ($1 == "origin") origin = 1
      # Concatenation keeps the comparison a string one: remotes 10 and 2.
      if (!found || ($1 "") < (first "")) first = $1
      found = 1
    }
    END { if (origin) print "origin"; else if (found) print first }
  ') || return 0
  [ -n "$name" ] || return 0
  REMOTE="$name"
  case "$name" in
    -*|*[!A-Za-z0-9._/-]*) REMOTE_PRINTABLE=0 ;;
  esac
}
if [ "$HEAD_STATE" = absent ] || [ "$BASE_STATE" = absent ]; then
  pick_remote
  _missing=""
  if [ "$HEAD_STATE" = absent ]; then
    _missing="head"
    say "head commit $HEAD_OID is not in this repository"
    if [ "$REMOTE_PRINTABLE" -eq 1 ]; then
      say "  git fetch $REMOTE pull/$N/head"
    else
      say "  fetch pull/$N/head from https://$REPO_PATH by hand"
    fi
  fi
  if [ "$BASE_STATE" = absent ]; then
    _missing="${_missing:+$_missing }base"
    say "base commit $BASE_OID is not in this repository"
    if [ "$REMOTE_PRINTABLE" -eq 1 ] && [ -n "$BASE_REF" ]; then
      say "  git fetch $REMOTE $BASE_REF"
    else
      say "  fetch the base branch from https://$REPO_PATH by hand"
    fi
  fi
  stop "missing: $_missing" 4
fi

_rc=0
MERGE_BASE=$(git_probe ${NOLAZY[@]+"${NOLAZY[@]}"} merge-base "$BASE_OID" "$HEAD_OID") || _rc=$?
case "$_rc" in
  0)
    case "$MERGE_BASE" in ""|*[!0-9a-f]*) probe_failed merge-base 0 ;; esac
    [ "${#MERGE_BASE}" -eq "${#HEAD_OID}" ] || probe_failed merge-base 0
    ;;
  1)
    say "$BASE_OID and $HEAD_OID have no common ancestor"
    _shallow=$(git_probe rev-parse --is-shallow-repository) || _shallow=""
    [ "$_shallow" != true ] || say "this is a shallow clone; more history may be needed"
    stop "missing: merge-base" 4
    ;;
  *) probe_failed merge-base "$_rc" ;;
esac

# ---- 8 · write, only after everything resolved -----------------------------
FOCUS="review $MERGE_BASE..$HEAD_OID (PR #$N)"
CONTENT="# PR context — written by pr-context.sh

pull request: $PR_URL
head: $HEAD_OID
base: $BASE_OID
merge base: $MERGE_BASE
review range: $MERGE_BASE..$HEAD_OID

## gh pr view $N --json $FIELDS

$PR_JSON"
if [ "$HAVE_ATTACH" -eq 1 ]; then
  CONTENT="$CONTENT

## Additional context (--with-context)"
  # An empty file keeps the heading; the file still ends with one newline.
  [ -z "$ATTACH" ] || CONTENT="$CONTENT

$ATTACH"
fi

write_failed() {
  say "could not write the context file under $LOG_ROOT"
  stop "failed: context-write" 2
}
_rc=0
LOG_DIR=$(dev_trio_prepare_log_dir "$LOG_ROOT") || _rc=$?
[ "$_rc" -eq 0 ] || write_failed
# Taken on its own: inside the mktemp argument a failed date would go unseen
# and leave a name with no time in it.
TS=$(date +%Y%m%d-%H%M%S) || TS=""
case "$TS" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) write_failed ;;
esac
# mktemp makes a new 0600 regular file, as the wrappers' own temporaries in
# this directory are made.
CFILE=$(mktemp "$LOG_DIR/pr-$N-context-$TS.XXXXXX") || write_failed
JSON=$(jq -nc --argjson number "$N" --arg url "$PR_URL" --arg head "$HEAD_OID" \
  --arg base "$BASE_OID" --arg merge_base "$MERGE_BASE" --arg file "$CFILE" --arg focus "$FOCUS" \
  '{pr_context_version: 1, number: $number, url: $url, head: $head, base: $base,
    merge_base: $merge_base, context_file: $file, focus: $focus}') || { rm -f "$CFILE"; write_failed; }
# jq writes a byte that is not UTF-8 as U+FFFD, so such a path would be
# announced as a file that does not exist. The path is the only value that can
# hold one: the others are digits, hex and a URL jq has already matched.
_announced=$(jq -r '.context_file' <<<"$JSON") || { rm -f "$CFILE"; write_failed; }
if [ "$_announced" != "$CFILE" ]; then
  rm -f "$CFILE"
  say "the log directory path is not valid UTF-8: $LOG_ROOT"
  write_failed
fi
{ printf '%s\n' "$CONTENT" >"$CFILE"; } 2>/dev/null || { rm -f "$CFILE"; write_failed; }

# ---- 9 · publish -----------------------------------------------------------
# A file whose path was announced is never removed. In a subshell with SIGPIPE
# ignored a closed reader is an ordinary write error; written from this shell,
# Bash 3.2 keeps the unwritten text buffered and lets it out with the next
# line sent to stderr.
if ( trap '' PIPE; printf '%s\n' "$JSON" ) 2>/dev/null; then
  exit 0
fi
say "the context file is at $CFILE"
stop "failed: output" 2
