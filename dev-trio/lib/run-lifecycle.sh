#!/usr/bin/env bash
# run-lifecycle.sh — the run lifecycle ask-reviewer.sh and ask-researcher.sh
# share (#152): artifact paths, the private raw log on fd 8 and its reader on
# fd 7, the manifest, run metadata, latest-* links, the END marker and the
# EXIT-trap backstop. Prompt building, the model call and what a wrapper makes
# of the outcome stay in the wrapper.
#
# Definitions only; sourcing runs nothing. The caller sets RUN_TAG (its name
# without .sh, which prefixes every message) and the LOG_DIR, TEAM and PM_HOST
# it already resolves. Values that differ by role come in as arguments. The
# helpers set the wrapper's own globals — TS, LOG, FINAL, AGY_CLI_LOG,
# LATEST_TMP, RUNSTATE_LOG — plus RUN_OFFSET, and use fds 7, 8 and 9 the way
# the wrappers always have.
#
# errexit: a function called from `if`, `!`, `&&` or `||` runs with errexit
# suppressed inside it, on Bash 3.2 and 5 alike. So each helper is one of
#   aborting    — called as a plain statement only; its commands keep the
#                 exact shapes of the inline code they replaced, so errexit
#                 fires on the same commands it always did.
#   predicate   — called only as a condition; every fallible command is
#                 guarded and the status is the answer.
#   best-effort — a failure is reported and the status is 0, so a plain call
#                 cannot trip errexit and skip what follows it.
# Requires Bash 3.2, the host.sh, manifest.sh, runstate.sh and registry.sh
# helpers.

# run_paths CHANNEL CLI_LOG_TAG WORKSPACE — aborting. Names this run's
# artifacts, once per run in the prepared LOG_DIR. The PID suffix avoids log and manifest
# collisions when two runs start within the same second (BSD `date` has no
# sub-second precision). FINAL is the answer as its own artifact: a reader
# must never have to find it inside the transcript, where the model's output
# can quote the wrapper's framing. With a WORKSPACE (a workspace-aware model,
# the built-in agy), AGY_CLI_LOG pins agy's own per-run log so its
# conversation id — and through it a denied tool — can be found after the run.
# It stays in agy's log directory: it holds the user's whole allow list, so it
# is never copied here. dev_trio_agy_cli_log creates that file, so a caller
# that refuses a run on its own inputs does so before calling this.
run_paths() {
  TS="$(date +%Y%m%d-%H%M%S)-$$"
  LOG="$LOG_DIR/$1-$TS.log"
  FINAL="$LOG_DIR/$1-$TS.final.md"
  [ -z "$3" ] || AGY_CLI_LOG="$(dev_trio_agy_cli_log "$2-$TS")"
}

# run_cleanup — best-effort; the EXIT trap. Its first command captures the
# status the shell is exiting with. The completion backstop runs first: a run
# whose completion is never published would read as live forever on the
# dashboard, and a failing cleanup step must not take the handler down before
# it records one. It is a no-op once a real completion has been published.
# The caller defines run_cleanup_files, which removes its temporaries in its
# own order (LATEST_TMP included) and returns 0.
run_cleanup() {
  _cleanup_rc=$?
  if [ -n "$RUNSTATE_LOG" ]; then
    runstate_complete "$RUNSTATE_LOG" exit_code="$_cleanup_rc" reason=aborted 2>/dev/null || true
  fi
  run_cleanup_files
  manifest_cleanup || true
}

# run_install_traps — aborting. RUNSTATE_LOG must be set (empty) first.
run_install_traps() {
  trap run_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# run_open_log — aborting; exits 2 on refusal. Opens LOG on fd 8 as a new
# private regular file. An existing path is refused before opening (including
# nonregular files that Bash noclobber permits), then the descriptor is
# verified before anything is written to it.
run_open_log() {
  local log_uid log_umask
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    echo "[$RUN_TAG] raw log path already exists: $LOG" >&2
    exit 2
  fi
  log_uid=$(id -u) || exit 2
  log_umask=$(umask)
  umask 077
  set -C
  if ! exec 8>"$LOG"; then
    set +C
    umask "$log_umask"
    exit 2
  fi
  set +C
  umask "$log_umask"
  if ! dev_trio_new_log_fd_is_private "$LOG" 8 "$log_uid"; then
    echo "[$RUN_TAG] raw log is not a new private regular file: $LOG" >&2
    exec 8>&-
    exit 2
  fi
}

# run_write_header MODEL — aborting. The log header, framed the same for both
# roles; the caller's run_header_body writes the role-specific lines between.
# The last line is the marker registry_extract_response keys on.
run_write_header() {
  {
    echo "=== $RUN_TAG.sh @ $TS ==="
    run_header_body
    echo "=== PM HOST: $PM_HOST ==="
    echo "=== MODEL: $1 ==="
    echo "=== RESPONSE ==="
  } >&8
}

# run_begin_metadata CHANNEL VARIANT ROLE MODEL [ARG...] — best-effort.
# Structured run metadata for the dashboard, published before the latest-*
# links so a reader that follows a link always finds a described run rather
# than a bare log it would have to parse. Values the dashboard renders come
# from here, never from the log body, which carries untrusted text. ARGs are
# the caller's own runstate_begin arguments (result_path, input*=), passed in
# the order the inputs are to be recorded. A sidecar that cannot be written
# never changes the run's outcome.
run_begin_metadata() {
  local channel="$1" variant="$2" role="$3" model="$4" final_source nested
  shift 4
  if registry_has_final "$model"; then
    final_source=native
  else
    final_source=stdout
  fi
  if manifest_is_nested; then
    nested=true
  else
    nested=false
  fi
  if runstate_begin "$LOG" channel="$channel" wrapper="$RUN_TAG.sh" \
       variant="$variant" team="$TEAM" run_stem="$channel-$TS" \
       started_display="$TS" pid="$$" role="$role" model="$model" \
       pm_host="$PM_HOST" final_path="$FINAL" final_source="$final_source" \
       nested="$nested" ${1+"$@"}; then
    RUNSTATE_LOG="$LOG"
  else
    echo "[$RUN_TAG] run metadata unavailable; the dashboard will show this run as legacy" >&2
  fi
}

# run_publish_latest CHANNEL MODEL — aborting. ln -sfn unlinks then creates
# and can fail under concurrent dispatch, so a unique sibling link is renamed
# over each latest-* link instead; readers see either complete target.
run_publish_latest() {
  LATEST_TMP="$LOG_DIR/.latest-$1-$TS"
  ln -s "$1-$TS.log" "$LATEST_TMP"
  mv -f "$LATEST_TMP" "$LOG_DIR/latest-$1.log"
  ln -s "$1-$TS.final.md" "$LATEST_TMP"
  mv -f "$LATEST_TMP" "$LOG_DIR/latest-$1.final.md"
  LATEST_TMP=""
  echo "[$RUN_TAG] running ($2) — monitor: dashboard.sh $1  (raw: tail -F $LOG_DIR/latest-$1.log)" >&2
}

# run_attach_reader — predicate. Opens LOG for reading on fd 7 and confirms
# that fds 7 and 8 are both still LOG's inode. On success RUN_OFFSET is where
# this run's own output starts (the size of fd 8), or empty when that could
# not be sampled. On failure fd 7 may be open and the caller's fallback
# closes it. Called directly, never through $( ): a subshell would lose fd 7.
run_attach_reader() {
  RUN_OFFSET=""
  exec 7<"$LOG" \
    && dev_trio_fd_matches_path "$LOG" 8 \
    && dev_trio_fd_matches_path "$LOG" 7 || return 1
  RUN_OFFSET="$(dev_trio_fd_size 8)" || RUN_OFFSET=""
}

# run_freeze_range DEST OFFSET END — predicate. Copies bytes [OFFSET, END) of
# the transcript through the held fd 7 into DEST, so a path replaced after
# creation cannot alter what is read. `tail`/`head` both read a regular file
# here, so neither reintroduces a pipe a leaked descendant could hold open.
# True only when DEST holds the whole range.
run_freeze_range() {
  tail -c "+$(($2 + 1))" <&7 \
    | head -c "$(($3 - $2))" > "$1" || true
  [ "$(wc -c < "$1")" -eq "$(($3 - $2))" ]
}

# run_finish_log RC — best-effort. The END marker is framing: the answer, the
# result and the run metadata carry the outcome, so a failed append is
# reported and never replaces it. With ORIGINAL_LOG_FD=9 the transcript went
# elsewhere and fd 9 still holds the original log's inode.
run_finish_log() {
  if [ "$ORIGINAL_LOG_FD" -eq 9 ]; then
    printf '\n=== END (rc=%d) ===\n' "$1" >&9 || \
      echo "[$RUN_TAG] final log append failed; $LOG may be incomplete" >&2 || true
  elif ! printf '\n=== END (rc=%d) ===\n' "$1" >&8; then
    echo "[$RUN_TAG] final log append failed; $LOG may be incomplete" >&2 || true
  fi
}
