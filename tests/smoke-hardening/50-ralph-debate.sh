#!/usr/bin/env bash
# ralph-debate: prompt paths, receipts (#61), failed dispatches (#106).
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_worker_cli_stubs
setup_driver
# The #106 worktree case runs under a team named after $TMP's unique suffix
# (not the PID, which can be recycled), so this glob only matches its own
# paths. Its worktrees live under /tmp, outside $TMP.
RD106_TEAM="rd106-$(basename "$TMP" | tr -cd 'A-Za-z0-9')"
register_cleanup 'rm -rf /tmp/ralph-"$RD106_TEAM"-iter-*'

# ralph-debate hands --prompt to debate.sh from inside the worktree, so a
# relative path must be resolved (and checked) before any cd.
printf -- '- [ ] task\n' > "$DRV/BACKLOG.md"
assert_eq "$(run_driver "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md \
  --prompt no-such.md --max-iter 1 --dry-run)" "rc=2"
assert_ok grep -q 'PROMPT not found: no-such.md' "$TMP/drv.err"
assert_eq "$(run_driver "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md \
  --prompt PROMPT.md --max-iter 1 --dry-run)" "rc=0"
DEBATE_PROMPT="$(sed -n 's/^PROMPT: *//p' "$TMP/rw/log/smoke/latest-ralph-debate.log")"
assert_eq "$DEBATE_PROMPT" "$(cd "$DRV" && pwd)/PROMPT.md"

# ralph-debate reads what ITS OWN dispatch produced, from the receipt debate.sh
# publishes, never from the team-wide `latest-debate` symlink (#61). The shim
# runs the real producer, then retargets the symlink at a foreign debate whose
# critic says the opposite thing — ralph cannot look until the shim returns, so
# no sleeps and no scheduling assumptions. The shim lives in a bin/ with a
# sibling lib/ because that is how ralph resolves debate-result.sh.
RD="$TMP/rd61"
mkdir -p "$RD/bin" "$RD/log/smoke/debate-19700101-000000" "$RD/ws"
ln -s "$ROOT/debate-conductor/lib" "$RD/lib"
printf '## Verdict\nVerdict: STRENGTHEN\n' > "$RD/log/smoke/debate-19700101-000000/round-2-crit.md"
ln -sfn "debate-19700101-000000" "$RD/log/smoke/latest-debate"
cat > "$RD/bin/debate.sh" <<SHIM
#!/bin/sh
"$ROOT/debate-conductor/bin/debate.sh" "\$@"
rc=\$?
: > "$RD/shim-ran"
ln -sfn "debate-19700101-000000" "$RD/log/smoke/latest-debate"
[ -n "\${RD61_DROP_RECEIPT:-}" ] && rm -f "\$DEBATE_RECEIPT"
exit \$rc
SHIM
chmod +x "$RD/bin/debate.sh"
run_rd61() {
  rm -f "$RD/shim-ran"
  printf -- '- [ ] task 61\n' > "$DRV/BACKLOG.md"
  (cd "$DRV" && env PATH="$RD/bin:$ROOT/dev-trio/bin:$PATH" \
    AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw61" \
    DEBATE_LOG_DIR="$RD/log" AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
    GENERATOR_CLI="$TMP/worker-cli/answer" CRITIC_CLI="$TMP/worker-cli/answer" \
    "$@" "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md --max-iter 1 \
    >/dev/null 2>"$TMP/rd61.err" </dev/null; echo "rc=$?")
}
assert_eq "$(run_rd61 env)" "rc=0"
assert_ok test -e "$RD/shim-ran"
# The symlink really did move to the foreign debate...
assert_eq "$(readlink "$RD/log/smoke/latest-debate")" "debate-19700101-000000"
RD61_LOG="$TMP/rw61/log/smoke/latest-ralph-debate.log"
# ...and ralph still reported its own debate's verdict (the stub says
# RECONSIDER; the foreign transcript says STRENGTHEN).
assert_eq "$(sed -n 's/^  verdict: *//p' "$RD61_LOG")" "RECONSIDER"
RD61_DIR="$(sed -n 's/^  debate dir: *//p' "$RD61_LOG")"
assert_eq "$(basename "$(dirname "$RD61_DIR")")" "smoke"
case "$RD61_DIR" in *debate-19700101-000000) assert_eq "own dir" "foreign dir" ;; *) assert_eq "own dir" "own dir" ;; esac
assert_ok test -f "$RD61_DIR/round-2-crit.md"
# A successful dispatch whose receipt is gone is a failed dispatch, never a
# fallback read of whatever the symlink happens to point at now. A failed
# dispatch has no verdict: the topic goes back on the backlog and the run stops
# with exit 1, without counting the iteration (#106). One row per outcome: the
# STOP reason and completed count, pending copies of the topic, verdict rows in
# the summary, and the last fix_plan header without its timestamp.
rd106_outcome() {
  local log="$TMP/rw61/log/smoke/latest-ralph-debate.log"
  printf '%s|pending=%s|verdicts=%s|%s\n' \
    "$(sed -n 's/^=== STOP (\(.*\)) completed=\(.*\) ===$/\1 \2/p' "$log")" \
    "$(grep -c '^- \[ \] task 61$' "$DRV/BACKLOG.md" || true)" \
    "$(grep -c '^  verdict:' "$log" || true)" \
    "$(grep '^## iter [0-9]' "$DRV/fix_plan.md" | tail -1 | sed 's/^## iter \([0-9]*\) · [0-9TZ:-]* · /iter \1 /')"
}
RD106_FAILED="dispatch-failed 0|pending=1|verdicts=0|iter 1 DISPATCH-FAILED (topic restored)"
assert_eq "$(run_rd61 env RD61_DROP_RECEIPT=1)" "rc=1"
assert_eq "$(rd106_outcome)" "$RD106_FAILED"
# ralph_log writes to stderr, not the summary log.
assert_ok grep -q 'receipt is missing or unusable' "$TMP/rd61.err"
# The receipt is kept beside the logs as a per-dispatch audit artifact, and the
# summary log binds it to the exit code — but an untouched reservation from a
# dispatch that published nothing is reclaimed.
assert_ok grep -q '^  receipt: ' "$TMP/rw61/log/smoke/latest-ralph-debate.log"
assert_ok jq -e '.schema_version == 1' "$(ls "$TMP/rw61/log/smoke"/debate-receipt-* | head -1)"
# A dispatch that fails publishes nothing, so its reservation is still empty —
# that is the file the cleanup exists for, and the only one it may take.
cat > "$RD/bin/debate.sh" <<SHIM3
#!/bin/sh
: > "$RD/shim-ran"
exit 7
SHIM3
chmod +x "$RD/bin/debate.sh"
assert_eq "$(run_rd61 env)" "rc=1"
assert_eq "$(rd106_outcome)" "$RD106_FAILED"
assert_eq "$(find "$TMP/rw61/log/smoke" -name 'debate-receipt-*' -size 0 | wc -l | tr -d ' ')" "0"
# The fix_plan record does not point at the reservation it just reclaimed.
assert_eq "$(grep '^debate.sh rc=' "$DRV/fix_plan.md" | tail -1)" "debate.sh rc=7 · receipt: none published"
# ...while the published one from the first dispatch is still there.
# A receipt with contents is never reclaimed, even when the reader rejects it:
# its bytes are the evidence of what the producer got wrong.
cat > "$RD/bin/debate.sh" <<SHIM2
#!/bin/sh
"$ROOT/debate-conductor/bin/debate.sh" "\$@"
rc=\$?
: > "$RD/shim-ran"
printf 'not a receipt\n' > "\$DEBATE_RECEIPT"
exit \$rc
SHIM2
chmod +x "$RD/bin/debate.sh"
assert_eq "$(run_rd61 env)" "rc=1"
assert_eq "$(rd106_outcome)" "$RD106_FAILED"
assert_eq "$(grep -lx 'not a receipt' "$TMP/rw61/log/smoke"/debate-receipt-*.* | wc -l | tr -d ' ')" "1"
# Two receipts survive the whole block: the one a successful dispatch published
# and the one whose contents a rejected dispatch left as evidence. The empty
# reservations of the dispatches that published nothing are gone.
assert_eq "$(find "$TMP/rw61/log/smoke" -name 'debate-receipt-*' -size 0 | wc -l | tr -d ' ')" "0"
assert_eq "$(find "$TMP/rw61/log/smoke" -name 'debate-receipt-*' ! -size 0 | wc -l | tr -d ' ')" "2"

# A dispatch that published a perfectly good receipt and *then* failed is still
# a failed dispatch: the exit code gates the read, because a signal after
# publication can leave a valid receipt behind for a run that did not finish.
# The receipt itself is kept — it records what the producer published.
cat > "$RD/bin/debate.sh" <<SHIM4
#!/bin/sh
"$ROOT/debate-conductor/bin/debate.sh" "\$@"
: > "$RD/shim-ran"
exit 7
SHIM4
chmod +x "$RD/bin/debate.sh"
assert_eq "$(run_rd61 env)" "rc=1"
assert_eq "$(rd106_outcome)" "$RD106_FAILED"
RD61_LAST="$(sed -n 's/^  receipt: *//p' "$TMP/rw61/log/smoke/latest-ralph-debate.log" | sed 's/ (rc=.*//')"
assert_ok jq -e '.schema_version == 1' "$RD61_LAST"
# ...and the fix_plan record names that kept receipt.
assert_eq "$(grep '^debate.sh rc=' "$DRV/fix_plan.md" | tail -1)" "debate.sh rc=7 · receipt: $RD61_LAST"

# A failed dispatch stops the run: later topics are neither consumed nor
# dispatched, and --max-iter 0 (unlimited) still ends after one iteration
# (--max-runtime only bounds the test if that ever regresses). The driver is
# reached through DEBATE_CONDUCTOR_BIN, as in #106's repro.
cat > "$RD/bin/debate.sh" <<SHIM6
#!/bin/sh
echo run >> "$RD/shim-runs"
exit 1
SHIM6
chmod +x "$RD/bin/debate.sh"
rm -f "$RD/shim-runs"
printf -- '- [ ] task 61\n- [ ] task two\n' > "$DRV/BACKLOG.md"
assert_eq "$( (cd "$DRV" && env PATH="$ROOT/dev-trio/bin:$PATH" DEBATE_CONDUCTOR_BIN="$RD/bin" \
  AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw61" \
  "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md --max-iter 0 --max-runtime 60 \
  >/dev/null 2>"$TMP/rd106.err" </dev/null; echo "rc=$?") )" "rc=1"
assert_eq "$(wc -l < "$RD/shim-runs" | tr -d ' ')" "1"
assert_eq "$(rd106_outcome)" "$RD106_FAILED"
# task two keeps its place; only the failed topic moved behind it.
assert_eq "$(grep -n '^- \[ \] ' "$DRV/BACKLOG.md" | tr '\n' ' ')" "2:- [ ] task two 3:- [ ] task 61 "

# When the topic cannot be put back, the record says so and still carries the
# topic text. A backlog of its own, so the read-only file cannot break later
# writes to the shared one; root ignores mode bits, so the case is skipped there.
if [ "$(id -u)" != 0 ]; then
  RO="$TMP/rd106-ro"
  mkdir -p "$RO"
  printf -- '- [ ] task ro\n' > "$RO/BACKLOG.md"
  cat > "$RD/bin/debate.sh" <<SHIM7
#!/bin/sh
chmod a-w "$RO/BACKLOG.md"
exit 1
SHIM7
  chmod +x "$RD/bin/debate.sh"
  RO_RC=$( (cd "$RO" && env PATH="$ROOT/dev-trio/bin:$PATH" DEBATE_CONDUCTOR_BIN="$RD/bin" \
    AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw106ro" \
    "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md --max-iter 1 \
    >/dev/null 2>"$TMP/rd106ro.err" </dev/null; echo "rc=$?") )
  chmod u+w "$RO/BACKLOG.md"
  assert_eq "$RO_RC" "rc=1"
  assert_eq "$(grep '^## iter [0-9]' "$RO/fix_plan.md" | sed 's/^## iter \([0-9]*\) · [0-9TZ:-]* · /iter \1 /')" \
    "iter 1 DISPATCH-FAILED (topic NOT restored)"
  assert_ok grep -qx 'Topic: task ro' "$RO/fix_plan.md"
  assert_eq "$(cat "$RO/BACKLOG.md")" "- [x] task ro"
  assert_ok grep -q 'could not restore the topic to BACKLOG' "$TMP/rd106ro.err"
fi

# #112: both pre-dispatch stops must say when a popped topic could not be
# restored. The shims make BACKLOG read-only only after pop_top_task rewrites it.
if [ "$(id -u)" != 0 ]; then
  RD112="$TMP/rd112"
  mkdir -p "$RD112/repo" "$RD112/bin"
  git init -q "$RD112/repo"
  git -C "$RD112/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  cat > "$RD112/bin/git" <<'SHIM112GIT'
#!/bin/bash
if [ "$RD112_STOP" = worktree ] && [ "$1" = worktree ] && [ "$2" = add ]; then
  [ "${RD112_READONLY:-1}" != 1 ] || chmod a-w "$RD112_BACKLOG"
  exit 1
fi
exec "$RD112_REAL_GIT" "$@"
SHIM112GIT
  cat > "$RD112/bin/mktemp" <<'SHIM112MKTEMP'
#!/bin/bash
if [ "$RD112_STOP" = receipt ] && [[ "$1" == *debate-receipt-* ]]; then
  [ "${RD112_READONLY:-1}" != 1 ] || chmod a-w "$RD112_BACKLOG"
  [ "${RD112_FIX_PLAN_READONLY:-0}" != 1 ] || chmod a-w "$RD112_FIX_PLAN"
  exit 1
fi
exec "$RD112_REAL_MKTEMP" "$@"
SHIM112MKTEMP
  chmod +x "$RD112/bin/git" "$RD112/bin/mktemp"
  for stop in worktree receipt; do
    case_dir="$RD112/$stop"
    mkdir -p "$case_dir"
    printf -- '- [ ] task %s\n' "$stop" > "$case_dir/BACKLOG.md"
    args=()
    [ "$stop" != worktree ] || args=(--worktree)
    rc=$( (cd "$RD112/repo" && env PATH="$RD112/bin:$ROOT/debate-conductor/bin:$PATH" \
      RD112_STOP="$stop" RD112_BACKLOG="$case_dir/BACKLOG.md" \
      RD112_REAL_GIT="$(command -v git)" RD112_REAL_MKTEMP="$(command -v mktemp)" \
      DEBATE_CONDUCTOR_BIN="$ROOT/debate-conductor/bin" \
      AGENT_TEAM="rd112-$stop" TMUX="" RALPH_TRIO_WORKSPACE="$case_dir/workspace" \
      "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog "$case_dir/BACKLOG.md" \
      --max-iter 1 ${args[@]+"${args[@]}"} >/dev/null 2>"$case_dir/driver.err" </dev/null; echo "rc=$?") )
    chmod u+w "$case_dir/BACKLOG.md"
    assert_eq "$rc" "rc=1"
    assert_eq "$(cat "$case_dir/BACKLOG.md")" "- [x] task $stop"
    assert_ok grep -q 'could not restore the topic to BACKLOG' "$case_dir/driver.err"
    stop_upper=$(printf '%s' "$stop" | tr '[:lower:]' '[:upper:]')
    header=$(grep '^## iter [0-9]' "$case_dir/fix_plan.md" | sed 's/^## iter \([0-9]*\) · [0-9TZ:-]* · /iter \1 /')
    assert_eq "$header" "iter 1 $stop_upper-FAILED (topic NOT restored)"
    assert_ok grep -qx "Topic: task $stop" "$case_dir/fix_plan.md"
  done
  for stop in worktree receipt; do
    case_dir="$RD112/$stop-restored"
    mkdir -p "$case_dir"
    printf -- '- [ ] task restored %s\n' "$stop" > "$case_dir/BACKLOG.md"
    args=()
    [ "$stop" != worktree ] || args=(--worktree)
    rc=$( (cd "$RD112/repo" && env PATH="$RD112/bin:$ROOT/debate-conductor/bin:$PATH" \
      RD112_STOP="$stop" RD112_READONLY=0 RD112_BACKLOG="$case_dir/BACKLOG.md" \
      RD112_REAL_GIT="$(command -v git)" RD112_REAL_MKTEMP="$(command -v mktemp)" \
      DEBATE_CONDUCTOR_BIN="$ROOT/debate-conductor/bin" \
      AGENT_TEAM="rd112-$stop-restored" TMUX="" RALPH_TRIO_WORKSPACE="$case_dir/workspace" \
      "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog "$case_dir/BACKLOG.md" \
      --max-iter 1 ${args[@]+"${args[@]}"} >/dev/null 2>"$case_dir/driver.err" </dev/null; echo "rc=$?") )
    assert_eq "$rc" "rc=1"
    assert_eq "$(grep -c "^- \[ \] task restored $stop$" "$case_dir/BACKLOG.md")" "1"
    stop_upper=$(printf '%s' "$stop" | tr '[:lower:]' '[:upper:]')
    header=$(grep '^## iter [0-9]' "$case_dir/fix_plan.md" | sed 's/^## iter \([0-9]*\) · [0-9TZ:-]* · /iter \1 /')
    assert_eq "$header" "iter 1 $stop_upper-FAILED (topic restored)"
    assert_ok grep -qx "Topic: task restored $stop" "$case_dir/fix_plan.md"
  done
  case_dir="$RD112/receipt-unrecorded"
  mkdir -p "$case_dir"
  printf -- '- [ ] task unrecorded\n' > "$case_dir/BACKLOG.md"
  printf '# plan\n' > "$case_dir/fix_plan.md"
  rc=$( (cd "$RD112/repo" && env PATH="$RD112/bin:$ROOT/debate-conductor/bin:$PATH" \
    RD112_STOP=receipt RD112_FIX_PLAN_READONLY=1 RD112_FIX_PLAN="$case_dir/fix_plan.md" \
    RD112_BACKLOG="$case_dir/BACKLOG.md" \
    RD112_REAL_GIT="$(command -v git)" RD112_REAL_MKTEMP="$(command -v mktemp)" \
    DEBATE_CONDUCTOR_BIN="$ROOT/debate-conductor/bin" \
    AGENT_TEAM=rd112-unrecorded TMUX="" RALPH_TRIO_WORKSPACE="$case_dir/workspace" \
    "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog "$case_dir/BACKLOG.md" \
    --max-iter 1 >/dev/null 2>"$case_dir/driver.err" </dev/null; echo "rc=$?") )
  chmod u+w "$case_dir/BACKLOG.md" "$case_dir/fix_plan.md"
  assert_eq "$rc" "rc=1"
  assert_eq "$(cat "$case_dir/BACKLOG.md")" "- [x] task unrecorded"
  assert_ok grep -q 'could not restore the topic to BACKLOG' "$case_dir/driver.err"
  assert_ok grep -q 'could not record RECEIPT-FAILED in fix_plan.md; topic: task unrecorded' "$case_dir/driver.err"
  assert_eq "$(grep -c 'RECEIPT-FAILED' "$case_dir/fix_plan.md" || true)" "0"
fi

# With --worktree, a failed dispatch discards the iteration's worktree and its
# branch before stopping. A team name of its own ($RD106_TEAM) keeps the /tmp
# paths unique to this run, and the EXIT trap removes them if an assertion fails
# first; the fixture repo, and with it the worktree registration, is under $TMP.
WTR="$TMP/rd106-wt"
git init -q "$WTR/repo"
git -C "$WTR/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
printf -- '- [ ] task wt\n' > "$WTR/BACKLOG.md"
cat > "$RD/bin/debate.sh" <<SHIM8
#!/bin/sh
exit 1
SHIM8
chmod +x "$RD/bin/debate.sh"
assert_eq "$( (cd "$WTR/repo" && env PATH="$ROOT/dev-trio/bin:$PATH" DEBATE_CONDUCTOR_BIN="$RD/bin" \
  AGENT_TEAM="$RD106_TEAM" TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw106wt" \
  "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog "$WTR/BACKLOG.md" --max-iter 1 --worktree \
  >/dev/null 2>"$TMP/rd106wt.err" </dev/null; echo "rc=$?") )" "rc=1"
RD106_WT_LOG="$TMP/rw106wt/log/$RD106_TEAM/latest-ralph-debate.log"
assert_eq "$(sed -n 's/^=== STOP (\(.*\)) completed=\(.*\) ===$/\1 \2/p' "$RD106_WT_LOG")" "dispatch-failed 0"
# A worktree really was created for the iteration...
assert_eq "$(grep -c "^  worktree: /tmp/ralph-$RD106_TEAM-iter-1\." "$RD106_WT_LOG")" "1"
# ...and nothing of it is left: no directory, no branch, no registered worktree.
assert_eq "$(ls -d /tmp/ralph-"$RD106_TEAM"-iter-* 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "$(git -C "$WTR/repo" branch --list "ralph/$RD106_TEAM-*" | wc -l | tr -d ' ')" "0"
assert_eq "$(git -C "$WTR/repo" worktree list | wc -l | tr -d ' ')" "1"
assert_eq "$(grep -c '^- \[ \] task wt$' "$WTR/BACKLOG.md")" "1"
assert_eq "$(grep -c '^  worktree: discarded$' "$RD106_WT_LOG")" "1"
# A failed dispatch takes the end-of-iteration worktree path, so a worktree that
# cannot be discarded is recorded where it was left instead of dropped silently. The shim
# runs inside the worktree and switches it off its generated branch, which makes
# merge_or_discard_worktree refuse (rc=1) and preserve it.
cat > "$RD/bin/debate.sh" <<'SHIM9'
#!/bin/sh
git checkout -q -b rd106-moved
exit 1
SHIM9
chmod +x "$RD/bin/debate.sh"
printf -- '- [ ] task wt\n' > "$WTR/BACKLOG.md"
assert_eq "$( (cd "$WTR/repo" && env PATH="$ROOT/dev-trio/bin:$PATH" DEBATE_CONDUCTOR_BIN="$RD/bin" \
  AGENT_TEAM="$RD106_TEAM" TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw106wt" \
  "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog "$WTR/BACKLOG.md" --max-iter 1 --worktree \
  >/dev/null 2>"$TMP/rd106wt.err" </dev/null; echo "rc=$?") )" "rc=1"
RD106_KEPT="$(sed -n 's/^  worktree: PRESERVED (not merged or discarded: \(.*\))$/\1/p' "$RD106_WT_LOG")"
case "$RD106_KEPT" in /tmp/ralph-"$RD106_TEAM"-iter-1.*) assert_eq kept kept ;; *) assert_eq "$RD106_KEPT" "/tmp/ralph-$RD106_TEAM-iter-1.*" ;; esac
assert_ok test -d "$RD106_KEPT"
assert_eq "$(grep '^## iter [0-9]' "$WTR/fix_plan.md" | tail -1 | sed 's/^## iter \([0-9]*\) · [0-9TZ:-]* · /iter \1 /')" "iter 1 WORKTREE-MERGE-BLOCK"
assert_eq "$(grep '^Worktree: ' "$WTR/fix_plan.md" | tail -1)" "Worktree: $RD106_KEPT"
# The blocked worktree is what stops the run here, as on any other iteration.
assert_eq "$(sed -n 's/^=== STOP (\(.*\)) completed=\(.*\) ===$/\1 \2/p' "$RD106_WT_LOG")" "worktree-blocked 0"
assert_eq "$(grep -c '^- \[ \] task wt$' "$WTR/BACKLOG.md")" "1"
git -C "$WTR/repo" worktree remove --force "$RD106_KEPT"

# A relative RALPH_TRIO_WORKSPACE still yields an absolute receipt path, which
# debate.sh requires: $LOG_DIR is relative in that case and is resolved once in
# the parent shell.
printf -- '- [ ] task rel\n' > "$DRV/BACKLOG.md"
rm -f "$RD/shim-ran"
cat > "$RD/bin/debate.sh" <<SHIM5
#!/bin/sh
exec "$ROOT/debate-conductor/bin/debate.sh" "\$@"
SHIM5
chmod +x "$RD/bin/debate.sh"
assert_eq "$( (cd "$DRV" && env PATH="$RD/bin:$ROOT/dev-trio/bin:$PATH" \
  AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="rel-ws" \
  DEBATE_LOG_DIR="$RD/log" AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
  GENERATOR_CLI="$TMP/worker-cli/answer" CRITIC_CLI="$TMP/worker-cli/answer" \
  "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md --max-iter 1 \
  >/dev/null 2>"$TMP/rd61rel.err" </dev/null; echo "rc=$?") )" "rc=0"
assert_eq "$(sed -n 's/^  verdict: *//p' "$DRV/rel-ws/log/smoke/latest-ralph-debate.log")" "RECONSIDER"
assert_ok grep -qE '^  receipt: +/' "$DRV/rel-ws/log/smoke/latest-ralph-debate.log"

# An UNKNOWN from a debate that did finish (the critic gave no parseable
# verdict) is not a failed dispatch and keeps its old handling: logged to
# fix_plan.md, not re-queued, and the run carries on to exit 0. The critic stub
# also writes its critique to --output-last-message, as `answer` does, or native
# final capture reports no answer.
cat > "$TMP/worker-cli/noverdict" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then
    printf '## Critique\nNo verdict here.\n' > "$2"
    break
  fi
  shift
done
echo "## Critique"
echo "No verdict here."
STUB
chmod +x "$TMP/worker-cli/noverdict"
assert_eq "$(run_rd61 env CRITIC_CLI="$TMP/worker-cli/noverdict")" "rc=0"
assert_eq "$(rd106_outcome)" "max-iter 1|pending=0|verdicts=1|iter 1 UNKNOWN verdict"
assert_eq "$(sed -n 's/^  verdict: *//p' "$TMP/rw61/log/smoke/latest-ralph-debate.log")" "UNKNOWN"
assert_eq "$(cat "$DRV/BACKLOG.md")" "- [x] task 61"

# A debate-conductor too old to ship the shared receipt library is refused up
# front, not once per iteration.
mkdir -p "$TMP/rd61old/bin" "$TMP/rd61old/lib"
printf '#!/bin/sh\nexit 0\n' > "$TMP/rd61old/bin/debate.sh"
chmod +x "$TMP/rd61old/bin/debate.sh"
printf -- '- [ ] task old\n' > "$DRV/BACKLOG.md"
assert_eq "$( (cd "$DRV" && env PATH="$TMP/rd61old/bin:$ROOT/dev-trio/bin:$PATH" \
  AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw61old" \
  "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md --max-iter 1 \
  >/dev/null 2>"$TMP/rd61old.err" </dev/null; echo "rc=$?") )" "rc=2"
assert_ok grep -q 'update debate-conductor' "$TMP/rd61old.err"
# ...and the task is still pending, not popped.
assert_eq "$(grep -c '^- \[ \] task old$' "$DRV/BACKLOG.md")" "1"

smoke_done 50-ralph-debate
