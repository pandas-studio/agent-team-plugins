#!/usr/bin/env bash
# Shared data/quoting boundary for view preparation, dispatch and GUI attachment.

view_error() { printf 'debate-view: %s\n' "$*" >&2; }

# POSIX shell quoting also works when the user's interactive shell is not Bash.
view_quote() {
  local rest="$1"
  printf "'"
  while [[ "$rest" == *"'"* ]]; do
    printf '%s%s' "${rest%%\'*}" "'\\''"
    rest=${rest#*\'}
  done
  printf "%s'" "$rest"
}

view_absolute() {
  local rest="$1" path=/ part
  case "$rest" in *$'\n'*|*$'\r'*) view_error 'line breaks in paths are unsupported'; return 2 ;; esac
  case "$rest" in /*) ;; *) rest="$PWD/$rest" ;; esac
  rest=${rest#/}
  # Physical existing prefixes preserve symlink/.. semantics. Nonexistent
  # prefixes are normalized without creating any log folders.
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=""; fi
    case "$part" in
      ''|.) ;;
      ..) path=${path%/*}; [ -n "$path" ] || path=/ ;;
      *) path="${path%/}/$part"
         if [ -d "$path" ]; then path=$(cd "$path" && pwd -P) || return 1; fi ;;
    esac
  done
  printf '%s\n' "$path"
}

view_private_stat() {
  stat -c '%u:%a' "$1" 2>/dev/null || stat -f '%u:%Lp' "$1" 2>/dev/null
}

view_private_file() {
  [ ! -L "$1" ] && [ -f "$1" ] &&
    [ "$(view_private_stat "$1")" = "$(id -u):600" ]
}

view_context_read() {
  local file="$1" parent data
  case "$file" in /*/context.json) ;; *) view_error 'expected an absolute context.json path'; return 2 ;; esac
  parent=${file%/*}
  [ ! -L "$parent" ] && [ -d "$parent" ] &&
    [ "$(view_private_stat "$parent")" = "$(id -u):700" ] &&
    view_private_file "$file" || { view_error 'context must be a private, owned regular file'; return 2; }
  data=$(jq -sce --arg parent "$parent" '
    def path: type == "string" and startswith("/") and
      (explode | all(. >= 32 and . != 127 and . != 65533));
    select(length == 1) | .[0] |
    select(.schema_version == 1 and (.kind == "team" or .kind == "log-dir")) |
    select(.status == "present" or .status == "ready-detached" or .status == "manual") |
    select((.cwd | path) and (.log_dir | path)) |
    select(.context_file == ($parent + "/context.json") and
           .receipt == ($parent + "/receipt.json")) |
    select(if .kind == "team" then
      (.team | type == "string" and length > 0 and length <= 48 and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.log_base | path) and .log_dir == ((.log_base | rtrimstr("/")) + "/" + .team)
      else (.team == null and .log_base == null and .status == "manual") end) |
    select(if .status == "ready-detached" then
      (.session | type == "string" and test("^[A-Za-z0-9_-]+$")) and
      (.socket | path) and (.tmux_bin | path)
      else .session == null and .socket == null end)
  ' "$file" 2>/dev/null) || { view_error 'invalid context'; return 2; }
  [ -d "$(printf '%s' "$data" | jq -r .cwd)" ] || { view_error 'workspace no longer exists'; return 2; }
  printf '%s\n' "$data"
}

view_tmux() { "$VIEW_TMUX" -S "$VIEW_SOCKET" "$@"; }

view_record() { view_tmux show-options -wqv -t "$1" @debate-view; }

view_complete() {
  local complete nonce
  complete=$(view_tmux show-options -wqv -t "$1" @debate-view-complete) || return 1
  nonce=$(printf '%s' "$2" | jq -r .nonce) || return 1
  [ -n "$complete" ] && [ "$complete" = "$nonce" ]
}

view_record_matches() {
  local record="$1" team="$2" dir="$3"
  printf '%s' "$record" | jq -e --arg team "$team" --arg dir "$dir" '
    .version == 1 and .team == $team and .log_dir == $dir and
    (.nonce | type == "string" and length > 0) and
    (.gen | type == "string" and test("^%[0-9]+$")) and
    (.crit | type == "string" and test("^%[0-9]+$")) and .gen != .crit
  ' >/dev/null 2>&1
}

view_pane_ready() {
  local pane="$1" role="$2" nonce="$3" team="$4" dir="$5" ready dead
  dead=$(view_tmux display-message -p -t "$pane" '#{pane_dead}') || return 1
  [ "$dead" = 0 ] || return 1
  ready=$(view_tmux show-options -pqv -t "$pane" @debate-view-ready) || return 1
  printf '%s' "$ready" | jq -e --arg role "$role" --arg nonce "$nonce" --arg team "$team" --arg dir "$dir" '
    .role == $role and .nonce == $nonce and .team == $team and .log_dir == $dir
  ' >/dev/null 2>&1
}

view_wait_ready() {
  local record="$1" gen crit nonce team dir deadline
  gen=$(printf '%s' "$record" | jq -r .gen)
  crit=$(printf '%s' "$record" | jq -r .crit)
  nonce=$(printf '%s' "$record" | jq -r .nonce)
  team=$(printf '%s' "$record" | jq -r .team)
  dir=$(printf '%s' "$record" | jq -r .log_dir)
  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if view_pane_ready "$gen" gen "$nonce" "$team" "$dir" &&
       view_pane_ready "$crit" crit "$nonce" "$team" "$dir"; then return 0; fi
    sleep 0.1
  done
  view_error 'viewer startup/readiness could not be verified'
  return 1
}

view_here_geometry_matches() {
  local pane="$1" record="$2" want live
  [ "$(printf '%s' "$record" | jq -r .type)" = here ] || return 1
  want=$(printf '%s\n%s\n' "$pane" "$(printf '%s' "$record" | jq -r '.gen,.crit')" | sort)
  live=$(view_tmux list-panes -t "$pane" -F '#{pane_id}' | sort) || return 1
  [ "$want" = "$live" ]
}

view_start_pane() {
  local pane="$1" role="$2" nonce="$3" team="$4" base="$5" cwd="$6" tail="$7" cmd
  cmd="exec env AGENT_TEAM=$(view_quote "$team") DEBATE_LOG_DIR=$(view_quote "$base") DEBATE_VIEW_NONCE=$(view_quote "$nonce") $(view_quote "$tail") $(view_quote "$role")"
  view_tmux set-option -p -t "$pane" remain-on-exit on || return 1
  if [ "${8:-replace}" = dead ]; then
    # Never kill a process that a user/concurrent actor started after our
    # dead-pane observation. tmux itself refuses a non-dead pane without -k.
    view_tmux respawn-pane -t "$pane" -c "$cwd" "$cmd"
  else
    view_tmux respawn-pane -k -t "$pane" -c "$cwd" "$cmd"
  fi
}

view_make_record() {
  jq -cn --arg type "$1" --arg team "$2" --arg dir "$3" --arg cwd "$4" \
    --arg gen "$5" --arg crit "$6" --arg nonce "$7" \
    '{version:1,type:$type,team:$team,log_dir:$dir,cwd:$cwd,gen:$gen,crit:$crit,nonce:$nonce}'
}

view_geometry_matches() {
  local target="$1" record="$2" want live
  want=$(printf '%s' "$record" | jq -r '.gen,.crit' | sort)
  live=$(view_tmux list-panes -t "$target" -F '#{pane_id}' | sort) || return 1
  [ "$want" = "$live" ]
}

view_ghostty_supported() {
  local app version major minor
  for app in /Applications/Ghostty.app "$HOME/Applications/Ghostty.app"; do
    [ -d "$app" ] || continue
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null) || continue
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
      major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
      if [ "$major" -gt 1 ] || { [ "$major" = 1 ] && [ "$minor" -ge 3 ]; }; then return 0; fi
    fi
  done
  return 1
}

# Kept separate from native automation so capability/terminal detection can be
# checked with recording dependencies on every platform, without opening apps.
view_select_terminal() {
  local requested="$1" term
  case "$requested" in
    ghostty) view_ghostty_supported || return 1; printf 'ghostty\n'; return ;;
    terminal) printf 'terminal\n'; return ;;
    auto) ;;
    *) return 1 ;;
  esac
  term=${TERM_PROGRAM:-}
  if [ -n "${TMUX:-}" ]; then
    term=$(view_tmux list-clients -F '#{client_termname} #{client_termtype}' 2>/dev/null | sort -u) || term=""
    [ "$(printf '%s\n' "$term" | wc -l | tr -d ' ')" = 1 ] || term=""
  fi
  case "$term" in
    ghostty|Ghostty|xterm-ghostty|xterm-ghostty\ *|ghostty\ *)
      if view_ghostty_supported; then printf 'ghostty\n'; return; fi ;;
  esac
  printf 'terminal\n'
}
