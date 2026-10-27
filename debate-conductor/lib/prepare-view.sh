#!/usr/bin/env bash
# New team-3pane.sh modes; legacy layout guard stays in its original script.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/view.sh"
. "$SCRIPT_DIR/namespace.sh"
MODE=auto FORCE=0 TEAM_OPT="" BASE_OPT="" RAW="" seen=" "
while [ "$#" -gt 0 ]; do
  key=${1%%=*}
  case "$seen" in *" $key "*) view_error "duplicate $key"; exit 2 ;; esac
  seen="$seen$key "
  case "$1" in
    --view=*) MODE=${1#*=} ;;
    --view-only) FORCE=1 ;;
    --team=*) TEAM_OPT=${1#*=}; [ -n "$TEAM_OPT" ] || { view_error '--team must not be empty'; exit 2; } ;;
    --log-base=*) BASE_OPT=${1#*=}; [ -n "$BASE_OPT" ] || { view_error '--log-base must not be empty'; exit 2; } ;;
    --log-dir=*) RAW=${1#*=}; [ -n "$RAW" ] || { view_error '--log-dir must not be empty'; exit 2; } ;;
    *) view_error "invalid or mixed layout option: $1"; exit 2 ;;
  esac
  shift
done
case "$MODE" in auto|tmux|none) ;; *) view_error 'view must be auto, tmux or none'; exit 2 ;; esac
if [ "$FORCE" = 1 ]; then
  case "$seen" in *' --view '*) ;; *) MODE=tmux ;; esac
fi
if { [ -n "$TEAM_OPT" ] && [ -z "$BASE_OPT" ]; } || { [ -z "$TEAM_OPT" ] && [ -n "$BASE_OPT" ]; }; then
  view_error '--team and --log-base must be supplied together'; exit 2
fi
if [ -n "$RAW" ] && { [ -n "$TEAM_OPT" ] || [ -n "$BASE_OPT" ]; }; then
  view_error '--log-dir cannot be combined with team/log-base'; exit 2
fi
command -v jq >/dev/null || { view_error 'jq is required'; exit 2; }
umask 077
CWD=$(pwd -P)
KIND=team TEAM="" BASE=""
if [ -n "$RAW" ]; then
  case "$RAW" in /*) ;; *) view_error '--log-dir must be absolute'; exit 2 ;; esac
  KIND=log-dir
  LOG_DIR=$(view_absolute "$RAW")
  [ "$MODE" != tmux ] || { view_error 'raw log directories support manual viewing only'; exit 2; }
else
  if [ -n "$TEAM_OPT" ]; then
    agent_team_validate_id "$TEAM_OPT" team || exit 2
    TEAM=$TEAM_OPT
    case "$BASE_OPT" in /*) ;; *) view_error '--log-base must be absolute'; exit 2 ;; esac
    BASE=$(view_absolute "$BASE_OPT")
  else
    TEAM=$(agent_team_detect_team) || exit 2
    BASE=$(view_absolute "${DEBATE_LOG_DIR:-$PWD/.debate-conductor/log}")
  fi
  LOG_DIR="${BASE%/}/$TEAM"
fi
# Context path strings must survive JSON -> shell -> receipt without loss.
jq -en --arg cwd "$CWD" --arg dir "$LOG_DIR" '
  [$cwd,$dir] | all(explode | all(. >= 32 and . != 127 and . != 65533))
' >/dev/null || { view_error 'control characters in workspace/log paths are unsupported'; exit 2; }

VIEW_TMUX=$(command -v tmux || true)
VIEW_SOCKET="" SESSION="" STATUS=manual REASON="" REASON_CODE="" RECORD=""
LOCK="" LOCK_TOKEN="$$-$RANDOM-$RANDOM" CREATED="" OWNER="" GEN="" CRIT=""

release_view_lock() {
  if [ -n "$LOCK" ] && [ "$(cat "$LOCK/owner" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
    rm -f "$LOCK/owner"
    rmdir "$LOCK" 2>/dev/null || true
  fi
}
cleanup_view() {
  local panes want clients owner windows complete
  if [ -n "$CREATED" ]; then
    owner=$(view_tmux show-options -qv -t "$CREATED" @debate-view-owner 2>/dev/null || true)
    clients=$(view_tmux list-clients -t "$CREATED" -F '#{client_name}' 2>/dev/null || true)
    windows=$(view_tmux list-windows -t "$CREATED" -F '#{window_id}' 2>/dev/null || true)
    panes=$(view_tmux list-panes -t "$CREATED" -F '#{pane_id}' 2>/dev/null | sort || true)
    want=$(printf '%s\n' "$GEN" "$CRIT" | sed '/^$/d' | sort)
    complete=$(view_tmux show-options -wqv -t "$GEN" @debate-view-complete 2>/dev/null || true)
    if [ "$owner" = "$OWNER" ] && [ -z "$clients" ] &&
       [ -z "$complete" ] &&
       [ "$(printf '%s\n' "$windows" | wc -l | tr -d ' ')" = 1 ] && [ "$panes" = "$want" ]; then
      view_tmux kill-session -t "$CREATED" 2>/dev/null || true
    fi
  fi
  release_view_lock
}
trap cleanup_view EXIT

acquire_view_lock() {
  local key i=0 root mkdir_error owner pid probe
  root=$(cd /tmp && pwd -P)
  key=$(printf '%s\n%s' "$VIEW_SOCKET" "$SESSION" | cksum | cut -d' ' -f1)
  LOCK="$root/debate-view-lock.$(id -u).$key"
  until mkdir_error=$(LC_ALL=C mkdir "$LOCK" 2>&1); do
    # EEXIST can race with the old owner releasing the directory. Retain the
    # bounded retry even if it has disappeared by this check.
    if [[ $mkdir_error != *'File exists'* ]] && [ ! -d "$LOCK" ]; then
      view_error "$mkdir_error"
      LOCK=""
      return 1
    fi
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then
      view_error "view setup lock is busy or incomplete: $LOCK"
      view_error 'Inspect its owner and verify no process is using it before removing it; no automatic stale takeover.'
      if [ ! -L "$LOCK" ] && [ "$(view_private_stat "$LOCK")" = "$(id -u):700" ] &&
          view_private_file "$LOCK/owner"; then
        owner=$(cat "$LOCK/owner")
        if [[ $owner =~ ^([1-9][0-9]*)-[0-9]+-[0-9]+$ ]]; then
          pid=${BASH_REMATCH[1]}
          if probe=$(LC_ALL=C kill -0 "$pid" 2>&1); then
            view_error "owner PID $pid is still running; leave the lock intact."
          elif [[ $probe == *'No such process'* ]]; then
            view_error "owner PID $pid no longer exists. After verifying this lock is unused, cleanup with:"
            view_error "rm -f -- $(view_quote "$LOCK/owner") && rmdir -- $(view_quote "$LOCK")"
          else
            view_error "owner PID $pid cannot be verified; leave the lock intact."
          fi
        fi
      fi
      LOCK=""
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$LOCK_TOKEN" > "$LOCK/owner"
}

prepare_detached() {
  local name hash target live nonce record pane dead count wid
  name=$(printf '%s' "$TEAM" | tr -c 'A-Za-z0-9_-' '_')
  hash=$(printf '%s' "$LOG_DIR" | cksum | cut -d' ' -f1)
  SESSION="debate-view-$name-$hash"
  acquire_view_lock || return 1
  target="=$SESSION"
  if view_tmux has-session -t "$target" 2>/dev/null; then
    owner=$(view_tmux show-options -qv -t "$target:" @debate-view-owner) || return 1
    case "$owner" in debate-conductor-v1:*) ;; *)
      view_error "foreign or untagged session: $SESSION"
      view_error "Inspect with: $(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") list-panes -t $(view_quote "$target:")"
      view_error "Only after verifying this is an abandoned view, remove with: $(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") kill-session -t $(view_quote "$target")"
      return 1 ;;
    esac
    count=$(view_tmux list-windows -t "$target" -F '#{window_id}' | wc -l | tr -d ' ') || return 1
    [ "$count" = 1 ] || { view_error "modified session: $SESSION"; return 1; }
    record=$(view_record "$target:") || return 1
    view_record_matches "$record" "$TEAM" "$LOG_DIR" &&
      [ "$(printf '%s' "$record" | jq -r .type)" = detached ] &&
      view_complete "$target:" "$record" &&
      view_geometry_matches "$target:" "$record" || {
      view_error "incomplete, conflicting or modified view: $SESSION"
      view_error "Inspect first; cleanup only this view with: $(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") kill-session -t $(view_quote "$target")"
      return 1
    }
    nonce=$(printf '%s' "$record" | jq -r .nonce)
    for role in gen crit; do
      pane=$(printf '%s' "$record" | jq -r ".$role")
      dead=$(view_tmux display-message -p -t "$pane" '#{pane_dead}') || return 1
      if [ "$dead" = 1 ]; then
        view_start_pane "$pane" "$role" "$nonce" "$TEAM" "$BASE" "$CWD" "$SCRIPT_DIR/../bin/tail-role.sh" dead || return 1
      fi
    done
    view_wait_ready "$record" || return 1
  else
    GEN=$(view_tmux new-session -d -s "$SESSION" -n debate-view -c "$CWD" -P -F '#{pane_id}' 'exec /bin/sleep 86400') || return 1
    # tmux can return rc0 while failing to create its socket in a sandbox.
    case "$GEN" in %*) ;; *) view_error 'tmux did not create a usable session/socket'; return 1 ;; esac
    view_tmux has-session -t "$target" || return 1
    CREATED=$(view_tmux display-message -p -t "$GEN" '#{session_id}') || return 1
    OWNER="debate-conductor-v1:$LOCK_TOKEN"
    view_tmux set-option -t "$CREATED" @debate-view-owner "$OWNER" || return 1
    CRIT=$(view_tmux split-window -h -t "$GEN" -c "$CWD" -P -F '#{pane_id}' 'exec /bin/sleep 86400') || return 1
    view_tmux select-layout -t "$GEN" even-horizontal || return 1
    view_tmux set-option -w -t "$GEN" @team-name "$TEAM" || return 1
    nonce="$LOCK_TOKEN"
    record=$(view_make_record detached "$TEAM" "$LOG_DIR" "$CWD" "$GEN" "$CRIT" "$nonce") || return 1
    view_tmux set-option -w -t "$GEN" @debate-view "$record" || return 1
    view_start_pane "$GEN" gen "$nonce" "$TEAM" "$BASE" "$CWD" "$SCRIPT_DIR/../bin/tail-role.sh" || return 1
    view_start_pane "$CRIT" crit "$nonce" "$TEAM" "$BASE" "$CWD" "$SCRIPT_DIR/../bin/tail-role.sh" || return 1
    view_wait_ready "$record" || return 1
    view_geometry_matches "$GEN" "$record" || return 1
    view_tmux set-option -w -t "$GEN" @debate-view-complete "$nonce" || return 1
    CREATED=""
  fi
  RECORD=$record
  STATUS=ready-detached
}

prepare_view() {
  local version major minor here_record here_pane
  [ "$MODE" != none ] && [ "$KIND" = team ] || return 0
  [ -n "$VIEW_TMUX" ] || { view_error 'tmux is not installed'; return 1; }
  version=$("$VIEW_TMUX" -V) || return 1
  if [[ "$version" =~ ^tmux\ ([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
    [ "$major" -gt 3 ] || { [ "$major" = 3 ] && [ "$minor" -ge 2 ]; } || {
      view_error 'managed views require tmux >=3.2'; return 1; }
  else view_error 'cannot verify tmux version >=3.2'; return 1; fi
  if [ -n "${TMUX:-}" ]; then
    VIEW_SOCKET=${TMUX%%,*}
  else
    VIEW_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
  fi
  VIEW_SOCKET=$(view_absolute "$VIEW_SOCKET")
  if [ -z "${TMUX:-}" ]; then
    # Unlike tmux's implicit default socket, explicit -S does not create its
    # parent. Create only the normal per-user socket directory, privately.
    socket_parent=${VIEW_SOCKET%/*}
    if [ ! -d "$socket_parent" ]; then
      if socket_error=$(mkdir -m 700 "$socket_parent" 2>&1); then :
      elif [ ! -d "$socket_parent" ]; then view_error "$socket_error"; return 1; fi
    fi
    [ ! -L "$socket_parent" ] && [ "$(view_private_stat "$socket_parent")" = "$(id -u):700" ] || {
      view_error 'tmux socket directory must be private and owned'; return 1; }
  fi
  if [ -n "${TMUX:-}" ] && [ "$FORCE" = 0 ]; then
    here_pane=${TMUX_PANE:-}
    if [ -z "$here_pane" ]; then
      here_pane=$(view_tmux display-message -p '#{pane_id}') || return 1
    fi
    # Internal env is deliberate; the host sees only team-3pane.sh argv.
    if DEBATE_MANAGED_VIEW=1 AGENT_TEAM="$TEAM" DEBATE_LOG_DIR="$BASE" TMUX_PANE="$here_pane" \
      "$SCRIPT_DIR/../bin/team-3pane.sh" --here -n "$TEAM" >/dev/null 2>&1; then
      here_record=$(view_record "$here_pane") || here_record=""
      if view_record_matches "$here_record" "$TEAM" "$LOG_DIR" &&
        view_here_geometry_matches "$here_pane" "$here_record" &&
        [ "$(printf '%s' "$here_record" | jq -r .cwd)" = "$CWD" ] &&
        view_wait_ready "$here_record"; then
        STATUS=present RECORD=$here_record
        # The session can have dots; only detached names enter the opener.
        SESSION=""
        return 0
      fi
    fi
  fi
  prepare_detached
}

ERROR_FILE=$(mktemp "${TMPDIR:-/tmp}/debate-view-error.XXXXXX")
if prepare_view 2>"$ERROR_FILE"; then :; else
  REASON=$(cat "$ERROR_FILE")
  REASON_CODE=setup-failed
  case "$REASON" in *'Operation not permitted'*|*'Permission denied'*) REASON_CODE=sandbox-denied ;; esac
  view_error "$REASON"
fi
rm -f "$ERROR_FILE"
if [ "$STATUS" = manual ] && [ -z "$REASON" ]; then
  REASON='manual viewing requested or raw continuation directory'
fi

CONTEXT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/debate-view-context.XXXXXX")
CONTEXT_DIR=$(cd "$CONTEXT_DIR" && pwd -P)
CONTEXT="$CONTEXT_DIR/context.json"
ATTACH_CMD="" SWITCH_CMD="" CLEANUP_CMD=""
if [ "$STATUS" = ready-detached ]; then
  ATTACH_CMD="$(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") attach-session -t $(view_quote "=$SESSION")"
  SWITCH_CMD="$(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") switch-client -t $(view_quote "=$SESSION")"
  CLEANUP_CMD="$(view_quote "$VIEW_TMUX") -S $(view_quote "$VIEW_SOCKET") kill-session -t $(view_quote "=$SESSION")"
fi
TAIL_GEN="tail -n +1 -F $(view_quote "$LOG_DIR/latest-debate/stream-gen.log")"
TAIL_CRIT="tail -n +1 -F $(view_quote "$LOG_DIR/latest-debate/stream-crit.log")"
jq -cn --arg kind "$KIND" --arg status "$STATUS" --arg team "$TEAM" --arg base "$BASE" \
  --arg dir "$LOG_DIR" --arg cwd "$CWD" --arg context "$CONTEXT" \
  --arg socket "$VIEW_SOCKET" --arg session "$SESSION" --arg bin "$VIEW_TMUX" \
  --arg reason "$REASON" --arg code "$REASON_CODE" --arg attach "$ATTACH_CMD" \
  --arg switch "$SWITCH_CMD" --arg cleanup "$CLEANUP_CMD" --arg gen "$TAIL_GEN" --arg crit "$TAIL_CRIT" '
  {schema_version:1,kind:$kind,status:$status,cwd:$cwd,log_dir:$dir,
   team:(if $kind == "team" then $team else null end),
   log_base:(if $kind == "team" then $base else null end),
   context_file:$context,receipt:($context | sub("context.json$";"receipt.json")),
   socket:(if $status == "ready-detached" then $socket else null end),
   session:(if $status == "ready-detached" then $session else null end),
   tmux_bin:(if $status == "ready-detached" then $bin else null end),
   reason:$reason,reason_code:$code,attach_command:$attach,switch_command:$switch,
   cleanup_command:$cleanup,tail_commands:[$gen,$crit],
   user_message:(if $status == "present" then
     "Generator and Critic viewers are ready in this tmux window."
     elif $status == "ready-detached" then
     "Live view prepared in the background. In another terminal tab/window on this machine and user, run:\n" + $attach +
     "\nDetach with Ctrl-b d. You can also request: 뷰 열어줘."
     else "Manual live viewing.\nReason: " + $reason + "\nRun in separate terminals:\n" + $gen + "\n" + $crit end)}
' > "$CONTEXT"
cat "$CONTEXT"
[ "$MODE" != tmux ] || [ "$STATUS" != manual ] || exit 2
