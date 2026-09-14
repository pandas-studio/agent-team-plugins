#!/usr/bin/env bash
# spec-trio-only contract, test and backlog lifecycle. Shared Ralph helpers
# intentionally retain their existing semantics.

spec_stamp() {
  local path="$1" digest target
  if [ -f "$path" ] && [ -r "$path" ]; then
    target=$(spec_resolve_target "$path") || return 1
    digest=$(_manifest_sha256 "$target") || return 1
    [ -n "$digest" ] || return 1
    printf '%s:%s:%s\n' "$(readlink "$path" 2>/dev/null || true)" "$target" "$digest"
  elif [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing\n'
  else
    return 1
  fi
}

spec_guard() {
  local path expected actual i
  for i in "${!GUARD_PATHS[@]}"; do
    path="${GUARD_PATHS[$i]}"; expected="${GUARD_STAMPS[$i]}"
    actual=$(spec_stamp "$path") || actual=unreadable
    if [ "$actual" != "$expected" ]; then
      printf 'protected input changed: %s\n' "$path" > "$GUARD_FAILURE" || return 1
      return 4
    fi
  done
  [ ! -f "$GUARD_FAILURE" ]
}

spec_check_or_stop() {
  if ! spec_guard; then
    STOP_REASON="protected-input-changed"
    cat "$GUARD_FAILURE" >&2 2>/dev/null || true
    [ -z "${WT:-}" ] || echo "Preserved worktree: $WT" >&2
    exit 4
  fi
}

# Runs in the stage subshell. The persistent marker retains even a transient
# guard failure, so a later restored file cannot turn this attempt into SHIP.
spec_run_stage() {
  local rc=0
  spec_guard || return 4
  "$@" || rc=$?
  spec_guard || return 4
  return "$rc"
}

spec_protect() {
  local stamp
  stamp=$(spec_stamp "$1") || return 1
  GUARD_PATHS+=("$1")
  GUARD_STAMPS+=("$stamp")
}

spec_protect_worktree() {
  GUARD_PATHS=("$SPEC_SOURCE" "$SPEC_FILE" "$BACKLOG_FILE")
  GUARD_STAMPS=("$SOURCE_STAMP" "$SNAPSHOT_STAMP" "$BACKLOG_STAMP")
  local root rel p
  if [ -n "$WT" ]; then
    root=$(git -C "$ORIGINAL_DIR" rev-parse --show-toplevel) || return 1
    for p in "$SPEC_SOURCE" "$SPEC_TARGET" "$BACKLOG_FILE" "$BACKLOG_TARGET"; do
      case "$p" in
        "$root"/*)
          rel=${p#"$root"/}
          spec_protect "$WT/$rel" || return 1
          ;;
      esac
    done
  fi
}

spec_pending_count() {
  awk '/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+/ { n++ } END { print n+0 }' "$BACKLOG_FILE"
}

spec_select_task() {
  TASK_LINE=$(awk '/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+/ { print NR; exit }' "$BACKLOG_FILE") || return 1
  TASK=""
  [ -n "$TASK_LINE" ] || return 0
  TASK=$(sed -n "${TASK_LINE}p" "$BACKLOG_FILE" | sed -E 's/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+//')
}

spec_resolve_target() {
  local target="$1" link hops=0 parent
  while [ -L "$target" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    link=$(readlink "$target") || return 1
    case "$link" in
      /*) target="$link" ;;
      *) target="$(dirname "$target")/$link" ;;
    esac
  done
  parent=$(cd -P "$(dirname "$target")" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$(basename "$target")"
}

spec_complete_task() {
  spec_check_or_stop
  local tmp target
  target="$BACKLOG_TARGET"
  # Preserve a supplied backlog symlink while atomically replacing its target.
  tmp=$(mktemp "$target.spec-trio.XXXXXX") || return 1
  cp -p "$target" "$tmp" || return 1
  awk -v ln="$TASK_LINE" 'NR == ln { sub(/\[ \]/, "[x]") } { print }' "$BACKLOG_FILE" > "$tmp" || return 1
  spec_publish_backlog "$tmp" || return 1
  COMPLETED=$((COMPLETED + 1))
  printf '## iter %d · SHIP (completed)\nTask: %s\nReview: %s\n\n' "$ITER" "$TASK" "$REVIEW_LOG" >> "$FIX_PLAN_FILE" || return 1
}

# Both completion and coverage requeue publish an exact prepared payload.
# Never learn a new expected stamp by rereading mutable live data after a write.
spec_publish_backlog() {
  local tmp="$1" digest expected
  digest=$(_manifest_sha256 "$tmp") || return 1
  expected="${BACKLOG_STAMP%:*}:$digest"
  spec_check_or_stop
  [ "$(spec_resolve_target "$BACKLOG_FILE")" = "$BACKLOG_TARGET" ] || return 1
  [ -w "$BACKLOG_TARGET" ] || { echo "backlog is not writable: $BACKLOG_FILE" >&2; return 1; }
  mv -f "$tmp" "$BACKLOG_TARGET" || return 1
  BACKLOG_STAMP="$expected"
  GUARD_STAMPS[2]="$BACKLOG_STAMP"
  spec_check_or_stop
}

spec_append_coverage() {
  local additions="$1" tmp
  spec_check_or_stop
  [ -s "$additions" ] || return 0
  tmp=$(mktemp "$BACKLOG_TARGET.spec-trio.XXXXXX") || return 1
  cp -p "$BACKLOG_TARGET" "$tmp" || return 1
  # Separate additions from a final line lacking a newline.
  if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then
    printf '\n' >> "$tmp" || return 1
  fi
  cat "$additions" >> "$tmp" || return 1
  spec_publish_backlog "$tmp"
}

# Called while the coder manifest is open. Scope failure remains the existing
# scope gate's verdict, rather than becoming a test failure.
spec_test_code() {
  local coder_rc="$1" code_log="$2" hi
  TEST_RC=0
  TEST_LOG="${code_log%.log}-test.log"
  spec_check_or_stop
  manifest_add_input kind=coder-rc value="$coder_rc" || exit 1
  manifest_add_input kind=test-command value="$TEST_CMD" || exit 1
  if [ "$coder_rc" -ne 0 ]; then
    manifest_add_input kind=test-status value=skipped-coder-failed || exit 1
    return 0
  fi
  hi=$(build_harness_ignore)
  if [ "$STRICT_SCOPE" = "1" ] && ! check_scope "$WORK_DIR" "$ALLOWED_PATHS_LIST" "${code_log%.log}-pre-test-scope.log" "$hi" "$ITER_BASE_SHA"; then
    manifest_add_input kind=test-status value=skipped-scope-failed || exit 1
    return 0
  fi
  ( cd "$WORK_DIR" && spec_run_stage bash -c "$TEST_CMD" ) > "$TEST_LOG" 2>&1 || TEST_RC=$?
  spec_check_or_stop
  manifest_add_input kind=test-log path="$TEST_LOG" || exit 1
  manifest_add_input kind=test-rc value="$TEST_RC" || exit 1
  printf '  test rc: %d (log: %s)\n' "$TEST_RC" "$TEST_LOG" >> "$SUMMARY_LOG" || exit 1
}

spec_retry_verdict() {
  local parent="$1" reason="$2" log="$3"
  VERDICT=NEEDS-FIX
  manifest_init spec-review "$log" || exit 1
  REVIEW_RUN_ID="$MANIFEST_RUN_ID"
  manifest_set_parent "$parent" || exit 1
  manifest_add_input kind=task value="$TASK" || exit 1
  manifest_add_input kind=spec path="$SPEC_FILE" || exit 1
  manifest_add_input kind=skip-reason value="$reason" || exit 1
  manifest_add_input kind=coder-rc value="$CODE_RC" || exit 1
  if [ -f "$TEST_LOG" ]; then
    manifest_add_input kind=test-rc value="$TEST_RC" || exit 1
    manifest_add_input kind=test-log path="$TEST_LOG" || exit 1
  else
    manifest_add_input kind=test-status value=not-run || exit 1
  fi
  printf '%s — coder rc=%s, test rc=%s; see %s\n' "$reason" "$CODE_RC" "$TEST_RC" "$TEST_LOG" > "$log" || exit 1
  manifest_set_verdict NEEDS-FIX || exit 1
  manifest_finalize || exit 1
}

spec_finish() {
  local rc="$1" pending status
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "${STOP_REASON:-running}" = running ]; then STOP_REASON=execution-error; fi
  pending=$(spec_pending_count) || { pending=unknown; rc=1; }
  case "$rc" in
    0) status=completed; [ "$DRY_RUN" != 1 ] || status=dry-run ;;
    3) status=pending ;;
    4) status=blocked ;;
    130) status=interrupted ;;
    *) status=failed ;;
  esac
  manifest_cleanup
  printf '=== spec-trio done (status=%s completed=%s pending=%s reason=%s exit=%s) ===\n' \
    "$status" "${COMPLETED:-0}" "$pending" "${STOP_REASON:-execution-error}" "$rc" | tee -a "$SUMMARY_LOG" >&2 || rc=1
  echo "summary: $SUMMARY_LOG" >&2
  exit "$rc"
}
