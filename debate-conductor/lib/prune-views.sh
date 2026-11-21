#!/usr/bin/env bash
# prune-views.sh — `team-3pane.sh --prune`: report which detached debate views
# can be removed, and print the command that removes each one.
#
# Report-only. It sends tmux nothing but query commands and only reads the log
# tree; it never kills, sets, creates or locks anything. Whatever it reports is
# a snapshot, so the person running a printed command reruns this first.
#
# A view is removable only when every check below passes; any check that fails,
# or cannot be made, keeps it:
#   - the session is this plugin's own, complete, unmodified detached view
#     (owner tag, one window, its record, its name, its nonce, its panes, and
#     each pane's start command is this view's own viewer);
#   - no client is attached to it and its window is not linked elsewhere;
#   - no debate holds (or left) a writer lock in the view's log directory;
#   - its window has had no activity for an hour.
# One tmux server per run: the one a view would be prepared on from here.
set -euo pipefail
set +f   # the lock scan globs; a noglob inherited through SHELLOPTS would hide every lock
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/view.sh"

IDLE_SECONDS=3600

if [ "$#" != 1 ] || [ "$1" != --prune ]; then
  view_error 'usage: team-3pane.sh --prune   (report-only; it takes no other option)'
  exit 2
fi
command -v jq >/dev/null || { view_error 'jq is required'; exit 2; }
VIEW_TMUX=$(command -v tmux) || { view_error 'tmux is not installed'; exit 1; }
VIEW_SOCKET=$(view_resolve_socket) || exit 1

# absent_proven PATH — rc 0 only when PATH does not exist and that is known:
# its nearest existing ancestor is a directory this user can search. A path
# that cannot be looked up proves nothing.
absent_proven() {
  local p="$1"
  [ ! -e "$p" ] && [ ! -L "$p" ] || return 1
  while [ "$p" != / ]; do
    p=${p%/*}
    [ -n "$p" ] || p=/
    if [ -e "$p" ]; then
      [ -d "$p" ] && [ -x "$p" ]
      return
    fi
    [ ! -L "$p" ] || return 1   # a dangling link: unresolved, not absent
  done
  return 1
}

nothing_to_prune() {
  printf 'no tmux server at %s; nothing to prune\n' "$VIEW_SOCKET"
  exit 0
}

absent_proven "$VIEW_SOCKET" && nothing_to_prune
# stderr only: tmux names a socket file whose server is gone this way.
if ! probe=$(view_tmux list-sessions -F '#{session_id}' 2>&1 >/dev/null); then
  if [ -S "$VIEW_SOCKET" ] && [ "$probe" = "no server running on $VIEW_SOCKET" ]; then
    nothing_to_prune
  fi
  view_error "cannot list the sessions on $VIEW_SOCKET: $probe"
  exit 1
fi
SESSIONS=$(view_tmux list-sessions -F '#{session_id}	#{session_name}	#{session_windows}') || {
  view_error "cannot list the sessions on $VIEW_SOCKET"; exit 1; }
NOW=$(date +%s)

# Inside tmux, the session running this must be known, or it could be reported
# as removable. Only TMUX_PANE names it: an untargeted lookup picks tmux's own
# choice of session, which need not be this one.
SELF=""
if [ -n "${TMUX:-}" ]; then
  if [ -n "${TMUX_PANE:-}" ]; then
    SELF=$(view_tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null) || SELF=""
  fi
  [ -n "$SELF" ] || { view_error "cannot identify the tmux session running --prune on $VIEW_SOCKET (TMUX_PANE ${TMUX_PANE:-is not set})"; exit 1; }
fi

# shown — PATH for display in one TSV field: control characters become '?'.
shown() { printf '%s' "${1//[[:cntrl:]]/?}"; }

# viewer_command_matches START ROLE NONCE TEAM BASE — is START (tmux's
# #{pane_start_command}) the command view_start_pane gives this view's ROLE
# viewer? tmux shows it in double quotes with \ $ " escaped; the viewer path
# may be any installed copy of this plugin, so only its tail is fixed. Any
# other escape (\t, an octal byte) is not decoded: it fails the match.
viewer_command_matches() {
  local s="$1" out="" rest c prefix suffix middle inner q="'\\''"
  case "$s" in \"*\") s=${s#\"}; s=${s%\"} ;; *) return 1 ;; esac
  while [[ $s == *\\* ]]; do
    out="$out${s%%\\*}"
    rest=${s#*\\}
    c=${rest:0:1}
    case "$c" in \\|\$|\") ;; *) return 1 ;; esac
    out="$out$c"
    s=${rest:1}
  done
  out="$out$s"
  prefix="exec env AGENT_TEAM=$(view_quote "$4") DEBATE_LOG_DIR=$(view_quote "$5") DEBATE_VIEW_NONCE=$(view_quote "$3") "
  suffix=" $(view_quote "$2")"
  [[ $out == "$prefix"* ]] && [[ $out == *"$suffix" ]] || return 1
  middle=${out#"$prefix"}
  middle=${middle%"$suffix"}
  # Exactly one POSIX single-quoted word (view_quote's output) naming tail-role.sh.
  case "$middle" in \'*\') ;; *) return 1 ;; esac
  inner=${middle#\'}
  inner=${inner%\'}
  case "${inner//"$q"/}" in *\'*) return 1 ;; esac
  case "$inner" in */bin/tail-role.sh) return 0 ;; *) return 1 ;; esac
}

# lock_state LOG_DIR — rc 0: no debate writer lock; 1: LOCK_FOUND holds one
# (debate.sh's debate-<TS>/.lock, live or left behind); 2: cannot inspect.
lock_state() {
  local dir="$1" d
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    absent_proven "$dir" && return 0
    return 2
  fi
  # Readable too: a search-only directory lists as empty and would hide a lock.
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 2
  for d in "$dir"/debate-*; do
    [ -e "$d" ] || [ -L "$d" ] || continue   # the unmatched pattern itself
    [ -e "$d" ] || return 2                  # a link that does not resolve
    if [ -d "$d" ] && { [ ! -r "$d" ] || [ ! -x "$d" ]; }; then return 2; fi
    if [ -L "$d/.lock" ] || [ -e "$d/.lock" ]; then
      LOCK_FOUND="$d/.lock"
      return 1
    fi
  done
  return 0
}

# classify ID NAME WINDOWS — sets ACTION (keep|remove), REASON, ACTIVITY and
# INSPECT (1 when a person should look at the session before removing it).
classify() {
  local id="$1" name="$2" nwin="$3" owner token record team dir type base nonce role pane start
  local clients linked activity rc
  ACTION=keep REASON="" ACTIVITY=- INSPECT=0
  if [ -n "$SELF" ] && [ "$id" = "$SELF" ]; then REASON='this is the session running --prune'; return; fi
  owner=$(view_tmux show-options -qv -t "$id" @debate-view-owner) || { REASON='cannot read its owner tag'; INSPECT=1; return; }
  case "$owner" in
    debate-conductor-v1:?*) token=${owner#debate-conductor-v1:} ;;
    *) REASON='foreign or untagged session'; INSPECT=1; return ;;
  esac
  INSPECT=1
  [ "$nwin" = 1 ] || { REASON="modified: $nwin windows"; return; }
  record=$(view_record "$id:") || { REASON='cannot read its view record'; return; }
  team=$(printf '%s' "$record" | jq -r 'if type == "object" then .team // "" else "" end' 2>/dev/null) || team=""
  dir=$(printf '%s' "$record" | jq -r 'if type == "object" then .log_dir // "" else "" end' 2>/dev/null) || dir=""
  type=$(printf '%s' "$record" | jq -r .type 2>/dev/null) || type=""
  if [ -z "$team" ] || ! view_record_matches "$record" "$team" "$dir" || [ "$type" != detached ]; then
    REASON='incomplete or modified: its view record is missing or not a detached view'; return
  fi
  case "$dir" in /*) ;; *) REASON='modified: its record names a relative log directory'; return ;; esac
  [ "$name" = "$(view_expected_session "$team" "$dir")" ] || {
    REASON='modified: its name does not match its record'; return; }
  nonce=$(printf '%s' "$record" | jq -r .nonce) || { REASON='cannot read its view record'; return; }
  [ "$token" = "$nonce" ] || { REASON='modified: its owner tag does not match its record'; return; }
  view_complete "$id:" "$record" || { REASON='incomplete: its setup never finished'; return; }
  view_geometry_matches "$id:" "$record" || { REASON='modified: its panes are not the recorded viewers'; return; }
  base=${dir%/*}
  [ -n "$base" ] || base=/
  for role in gen crit; do
    pane=$(printf '%s' "$record" | jq -r ".$role") || { REASON='cannot read its view record'; return; }
    start=$(view_tmux display-message -p -t "$pane" '#{pane_start_command}') || {
      REASON="cannot read the start command of pane $pane"; return; }
    viewer_command_matches "$start" "$role" "$nonce" "$team" "$base" || {
      REASON="modified: pane $pane does not run this view's $role viewer"; return; }
  done
  INSPECT=0
  activity=$(view_tmux display-message -p -t "$id:" '#{window_activity}') || activity=""
  ACTIVITY=$(view_tmux display-message -p -t "$id:" '#{t:window_activity}') || ACTIVITY=-
  clients=$(view_tmux list-clients -t "$id" -F '#{client_name}') || { REASON='cannot list its clients'; return; }
  [ -z "$clients" ] || { REASON='a client is attached'; return; }
  linked=$(view_tmux display-message -p -t "$id:" '#{window_linked}') || { REASON='cannot read whether its window is linked'; return; }
  [ "$linked" = 0 ] || { REASON='its window is linked into another session'; return; }
  rc=0
  LOCK_FOUND=""
  lock_state "$dir" || rc=$?
  case "$rc" in
    0) ;;
    1) REASON="a debate holds or left a writer lock: $(shown "$LOCK_FOUND")"; return ;;
    *) REASON="cannot inspect its log directory for a debate lock: $(shown "$dir")"; return ;;
  esac
  case "$activity" in ''|*[!0-9]*) REASON='cannot read its last activity'; return ;; esac
  [ $((NOW - activity)) -ge "$IDLE_SECONDS" ] || { REASON='recently active (within 60 min)'; return; }
  ACTION=remove
  REASON='idle for over 60 min, no client, no debate lock'
}

ROWS="" COMMANDS="" HINTS="" scanned=0 removable=0 total=0
while IFS='	' read -r id name nwin; do
  [ -n "$id" ] || continue
  total=$((total + 1))
  [[ $name =~ ^debate-view-[A-Za-z0-9_-]+$ ]] || continue
  scanned=$((scanned + 1))
  classify "$id" "$name" "$nwin"
  ROWS="$ROWS$ACTION	$name	$ACTIVITY	$REASON
"
  quoted="$(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET")"
  if [ "$ACTION" = remove ]; then
    removable=$((removable + 1))
    COMMANDS="$COMMANDS  $quoted kill-session -t $(view_quote "=$name")
"
  elif [ "$INSPECT" = 1 ]; then
    HINTS="$HINTS  $quoted list-panes -s -t $(view_quote "=$name") -F '#{pane_id} #{pane_start_command}'
"
  fi
done < <(printf '%s\n' "$SESSIONS")   # not a here-document: bash 3.2 writes those to a temp file

printf 'debate views on %s:\n' "$VIEW_SOCKET"
if [ "$scanned" = 0 ]; then
  printf 'none\n'
  exit 0
fi
printf '%s' "$ROWS"
printf '%s of %s views removable, as of %s.\n' "$removable" "$scanned" "$(date)"
if [ "$removable" -gt 0 ]; then
  printf 'This is a snapshot: rerun --prune right before running a command below, and run only those it still lists.\n'
  printf '%s' "$COMMANDS"
  if [ "$removable" = "$total" ] &&
      [ "$(view_tmux show-options -sv exit-empty 2>/dev/null || true)" = on ]; then
    printf 'These are the only sessions on this server; removing them all stops it (exit-empty is on).\n'
  fi
fi
if [ -n "$HINTS" ]; then
  printf 'Kept because they are not verifiably this plugin'"'"'s unmodified views; inspect before removing by hand:\n'
  printf '%s' "$HINTS"
fi
