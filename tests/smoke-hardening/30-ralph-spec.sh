#!/usr/bin/env bash
# ralph-trio and spec-trio drivers: --max-runtime, worktrees, blocked merges, ralph-meta, stop-hook, spec scope.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --max-runtime: a spec the loop can't honour must be refused, not read as "no
# limit". parse_runtime runs inside $(...) in the drivers, so check both the
# helper's rc and that every driver actually stops on it.
for plugin in ralph-trio spec-trio; do
  parse_rt() {
    PLUGIN_ROOT="$ROOT/$plugin" bash -c \
      '. "$PLUGIN_ROOT/lib/common.sh"; out=$(parse_runtime "$1" 2>/dev/null); echo "rc=$? $out"' _ "$1"
  }
  assert_eq "$(parse_rt 08m)" "rc=0 480"
  assert_eq "$(parse_rt 6h)" "rc=0 21600"
  for bad in 1d 1h30m 90min "" 2H 1234567890; do
    assert_eq "$(parse_rt "$bad")" "rc=1 "
  done
done
setup_driver
assert_driver_refuses_runtime() {
  assert_eq "$(run_driver "$@" --max-iter 1 --dry-run --max-runtime 1d)" "rc=2"
  assert_ok grep -q "invalid --max-runtime '1d'" "$TMP/drv.err"
}
assert_driver_refuses_runtime "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md
assert_driver_refuses_runtime "$ROOT/ralph-trio/bin/ralph-trio.sh" --backlog BACKLOG.md
assert_driver_refuses_runtime "$ROOT/ralph-trio/bin/ralph-debate.sh" --backlog BACKLOG.md
assert_driver_refuses_runtime "$ROOT/spec-trio/bin/spec-trio.sh" --spec spec.md --backlog BACKLOG.md
# ...while a valid spec still runs (dry-run: no model calls).
assert_eq "$(run_driver "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md --max-iter 1 --dry-run --max-runtime 1h)" "rc=0"
# A worktree that can't be created stops the run with a failure status.
assert_eq "$(run_driver "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md --max-iter 1 --dry-run \
  --worktree --base-branch no-such-ref)" "rc=1"
assert_eq "$(run_driver "$ROOT/spec-trio/bin/spec-trio.sh" --spec spec.md --backlog BACKLOG.md --max-iter 1 \
  --dry-run --no-research --worktree --base-branch no-such-ref)" "rc=1"
assert_ok grep -q 'could not create the iter 1 worktree' "$TMP/drv.err"
# Without --dry-run the task was popped before the failure: it must be pending
# again. (Worktree creation precedes every model call, so nothing is spawned.)
for driver in ralph-trio ralph-debate; do
  printf -- '- [ ] task\n' > "$DRV/BACKLOG.md"
  assert_eq "$(run_driver "$ROOT/ralph-trio/bin/$driver.sh" --backlog BACKLOG.md --max-iter 1 \
    --worktree --base-branch no-such-ref)" "rc=1"
  # Popped (checked off) and re-queued (pending again), not left untouched.
  assert_eq "$(grep -c '^- \[x\] task$' "$DRV/BACKLOG.md")" "1"
  assert_eq "$(grep -c '^- \[ \] task$' "$DRV/BACKLOG.md")" "1"
  assert_ok grep -q 'could not create the iter 1 worktree' "$TMP/drv.err"
done
printf -- '- [ ] task\n' > "$DRV/BACKLOG.md"

# A merge that is blocked stops the loop at the first blocked iteration (exit
# 1, one preserved worktree) instead of keeping a full worktree per iteration.
MB="$TMP/merge-block"
git init -q "$MB"
git -C "$MB" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
printf 'prompt\n' > "$MB/PROMPT.md"
printf '#!/usr/bin/env bash\necho work >> work.txt\n' > "$TMP/mb-worker.sh"
chmod +x "$TMP/mb-worker.sh"
MB_RC=$(cd "$MB" && env AGENT_TEAM="mb-$$" TMUX="" RALPH_TRIO_WORKSPACE="$TMP/mb-ws" \
  WORKER_CLI="$TMP/mb-worker.sh" "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md \
  --max-iter 3 --worktree \
  --test-cmd "git -C '$MB' -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved" \
  >/dev/null 2>"$TMP/mb.err" </dev/null; echo "rc=$?")
MB_WTS=$(git -C "$MB" worktree list --porcelain | grep -c '^worktree ' || true)
git -C "$MB" worktree list --porcelain | sed -n 's/^worktree //p' | sed 1d | while IFS= read -r w; do
  rm -rf "$w"
done
assert_eq "$MB_RC" "rc=1"
assert_eq "$MB_WTS" "2"
assert_eq "$(grep -c 'WORKTREE-MERGE-BLOCK' "$MB/fix_plan.md")" "1"

# #114: a discard whose branch cannot be deleted leaves only the branch. The
# summary and fix_plan entry name that branch and not the removed worktree path.
CL="$TMP/cleanup-left"
git init -q "$CL"
git -C "$CL" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
printf 'prompt\n' > "$CL/PROMPT.md"
CL_RC=$(cd "$CL" && env AGENT_TEAM="cl-$$" TMUX="" RALPH_TRIO_WORKSPACE="$TMP/cl-ws" \
  WORKER_CLI="$TMP/mb-worker.sh" "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md \
  --max-iter 3 --worktree \
  --test-cmd 'b=$(git symbolic-ref --short HEAD) && : > "$(git rev-parse --git-common-dir)/refs/heads/$b.lock"; exit 1' \
  >/dev/null 2>"$TMP/cl.err" </dev/null; echo "rc=$?")
CL_BR=$(git -C "$CL" for-each-ref --format='%(refname:short)' 'refs/heads/ralph/*')
find "$CL/.git/refs/heads" -name '*.lock' -exec rm -f {} +
assert_eq "$CL_RC" "rc=1"
assert_eq "$(grep -c 'WORKTREE-CLEANUP-BLOCK' "$CL/fix_plan.md")" "1"
assert_eq "$(grep -c '^Worktree: ' "$CL/fix_plan.md" || true)" "0"
assert_eq "$(grep '^Branch: ' "$CL/fix_plan.md")" "Branch: $CL_BR"
assert_eq "$(grep -rh 'cleanup failed' "$TMP/cl-ws")" "  worktree: discarded, but cleanup failed; left: Branch: $CL_BR"

# Same for a coder that switches the worktree to another branch and leaves
# edits: the auto-commit is refused, and the loop stops there.
CB="$TMP/commit-block"
git init -q "$CB"
git -C "$CB" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$CB" branch feature
printf 'prompt\n' > "$CB/PROMPT.md"
printf '#!/usr/bin/env bash\ngit switch -q feature\necho work >> work.txt\n' > "$TMP/cb-worker.sh"
chmod +x "$TMP/cb-worker.sh"
CB_RC=$(cd "$CB" && env AGENT_TEAM="cb-$$" TMUX="" RALPH_TRIO_WORKSPACE="$TMP/cb-ws" \
  WORKER_CLI="$TMP/cb-worker.sh" "$ROOT/ralph-trio/bin/ralph-solo.sh" --prompt PROMPT.md \
  --max-iter 3 --worktree --test-cmd true >/dev/null 2>"$TMP/cb.err" </dev/null; echo "rc=$?")
CB_WTS=$(git -C "$CB" worktree list --porcelain | grep -c '^worktree ' || true)
git -C "$CB" worktree list --porcelain | sed -n 's/^worktree //p' | sed 1d | while IFS= read -r w; do
  rm -rf "$w"
done
assert_eq "$CB_RC" "rc=1"
assert_eq "$CB_WTS" "2"
assert_eq "$(grep -c 'WORKTREE-COMMIT-BLOCK' "$CB/fix_plan.md")" "1"
assert_eq "$(git -C "$CB" log --oneline feature | wc -l | tr -d ' ')" "1"

# ralph-meta without --base-ref: the empty range array must not kill git log
# under bash 3.2's set -u (it used to report 0 commits every time).
git -C "$DRV" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ralph iter 1: smoke"
git -C "$DRV" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated"
mkdir -p "$TMP/meta-ws/log/smoke"
printf "fixture stdout\n" > "$TMP/meta-ws/log/smoke/ralph-trio-fixture-plan.log"
printf "fixture stdout\n" > "$TMP/meta-ws/log/smoke/ralph-trio-fixture-plan.stdout.log"
mkdir -p "$TMP/meta-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/meta-bin/ask-reviewer.sh"
chmod +x "$TMP/meta-bin/ask-reviewer.sh"
(cd "$DRV" && env PATH="$TMP/meta-bin:$PATH" AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/meta-ws" \
  "$ROOT/ralph-trio/bin/ralph-meta.sh" --since "1 hour ago" >/dev/null 2>"$TMP/meta.err" </dev/null) || true
assert_eq "$(sed -n 's/.*ralph commits found: //p' "$TMP/meta.err")" "1"
assert_eq "$(sed -n 's/.*ralph logs found: //p' "$TMP/meta.err")" "1"

# A failed BSD-style probe may write stdout on GNU stat; it must not contaminate
# the successful fallback's numeric mtime. Reproduce on every host.
cat > "$TMP/meta-bin/stat" <<'STAT'
#!/usr/bin/env bash
if [ "$1" = -f ]; then
  echo 'filesystem data from failed BSD probe'
  exit 1
fi
python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$3"
STAT
chmod +x "$TMP/meta-bin/stat"
(cd "$DRV" && env PATH="$TMP/meta-bin:$PATH" AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/meta-ws" \
  "$ROOT/ralph-trio/bin/ralph-meta.sh" --since "1 hour ago" --variant trio >/dev/null 2>"$TMP/meta-fallback.err" </dev/null) || true
assert_eq "$(sed -n 's/.*ralph logs found: //p' "$TMP/meta-fallback.err")" "1"
# The reviewer must not take ralph-meta's own stdin as context.
printf '#!/usr/bin/env bash\n[ -t 0 ] || cat > "%s"\n' "$TMP/meta-reviewer.stdin" > "$TMP/meta-bin/ask-reviewer.sh"
printf 'META-STDIN-SENTINEL\n' > "$TMP/meta.stdin"
(cd "$DRV" && env PATH="$TMP/meta-bin:$PATH" AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/meta-ws" \
  "$ROOT/ralph-trio/bin/ralph-meta.sh" --since "1 hour ago" >/dev/null 2>&1 <"$TMP/meta.stdin") || true
assert_eq "$(wc -c < "$TMP/meta-reviewer.stdin" | tr -d ' ')" "0"

# stop-hook: Claude Code hands a blocking Stop hook's `reason` to Claude and
# ignores a top-level `additionalContext`, so PROMPT.md must travel in `reason`.
HOOK="$TMP/stop-hook"
mkdir -p "$HOOK"
printf 'Build the thing.\nPROMPT-BODY-SENTINEL\n' > "$HOOK/PROMPT.md"
printf '# fix_plan\n- tried FIX-PLAN-SENTINEL\n' > "$HOOK/fix_plan.md"
# HOOK_ACTIVE=true marks a continuation, as Claude Code sends it.
run_stop_hook() {
  printf '{"hook_event_name":"Stop","stop_hook_active":%s}' "${HOOK_ACTIVE:-false}" \
    | env AGENT_TEAM=hook TMUX="" RALPH_TRIO_WORKSPACE="$HOOK/ws" \
        RALPH_PROMPT="$HOOK/PROMPT.md" RALPH_FIX_PLAN="$HOOK/fix_plan.md" "$@" \
        "$ROOT/ralph-trio/bin/stop-hook.sh" 2>"$HOOK/err"
}
hook_reason_part() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"].split("\n\n---\n\n")[int(sys.argv[1])])' "$1"
}
# An invalid explicit team is a setup error: let Claude Code stop instead of
# returning exit 2, which would block its Stop event.
rc=0
run_stop_hook AGENT_TEAM='bad team' > "$HOOK/out-invalid-team.json" || rc=$?
assert_eq "$rc" "0"
assert_eq "$(wc -c < "$HOOK/out-invalid-team.json" | tr -d ' ')" "0"
assert_ok grep -Fq 'ERROR: AGENT_TEAM must match' "$HOOK/err"
assert_ok grep -Fq '[ralph-hook] cannot determine team — allowing stop' "$HOOK/err"
assert_eq "$(test -e "$HOOK/ws/state/hook/iter" && echo yes || echo no)" "no"
run_stop_hook > "$HOOK/out.json"
assert_eq "$(jq -r '.decision' "$HOOK/out.json")" "block"
assert_eq "$(jq -r 'has("additionalContext") or has("hookSpecificOutput")' "$HOOK/out.json")" "false"
assert_eq "$(hook_reason_part 1 < "$HOOK/out.json")" "$(cat "$HOOK/PROMPT.md")"
assert_eq "$(cat "$HOOK/ws/state/hook/iter")" "1"
run_stop_hook RALPH_INJECT_FIX_PLAN=1 > "$HOOK/out-fp.json"
assert_eq "$(hook_reason_part 2 < "$HOOK/out-fp.json" | sed -n '/^<fix_plan_md>$/,/^<\/fix_plan_md>$/p')" \
  "$(printf '<fix_plan_md>\n%s\n</fix_plan_md>' "$(cat "$HOOK/fix_plan.md")")"
assert_eq "$(cat "$HOOK/ws/state/hook/iter")" "2"
# A PROMPT.md over Linux's 128 KiB single-argument cap still arrives whole.
python3 -c 'print("BIG-PROMPT " + "x" * 300000)' > "$HOOK/PROMPT.md"
rm -f "$HOOK/ws/state/hook/prompt.sha256"
run_stop_hook > "$HOOK/out-big.json"
assert_eq "$(hook_reason_part 1 < "$HOOK/out-big.json" | wc -c | tr -d ' ')" "$(wc -c < "$HOOK/PROMPT.md" | tr -d ' ')"
# If the response cannot be built, the stop is allowed and no iteration is spent.
mkdir -p "$HOOK/bin"
printf '#!/bin/sh\nexit 1\n' > "$HOOK/bin/python3"
chmod +x "$HOOK/bin/python3"
before=$(cat "$HOOK/ws/state/hook/iter")
rc=0
run_stop_hook PATH="$HOOK/bin:$PATH" > "$HOOK/out-fail.json" || rc=$?
assert_eq "$rc" "0"
assert_eq "$(wc -c < "$HOOK/out-fail.json" | tr -d ' ')" "0"
assert_eq "$(cat "$HOOK/ws/state/hook/iter")" "$before"
assert_eq "$(grep -c 'could not build the hook response' "$HOOK/err")" "1"
# Claude Code ends the turn after 8 consecutive blocks and never acts on a 9th.
# The hook allows that stop itself, keeps the counter, and a new message
# (stop_hook_active=false) starts a fresh run of blocks.
printf 'Build the thing.\n' > "$HOOK/PROMPT.md"
rm -f "$HOOK/ws/state/hook/prompt.sha256"
echo 0 > "$HOOK/ws/state/hook/iter"
blocked=0
for n in 1 2 3 4 5 6 7 8 9; do
  active=true
  [ "$n" -gt 1 ] || active=false
  HOOK_ACTIVE=$active run_stop_hook > "$HOOK/out-cap.json"
  [ "$(jq -r '.decision // empty' "$HOOK/out-cap.json" 2>/dev/null)" != block ] || blocked=$((blocked + 1))
done
assert_eq "$blocked" "8"
assert_eq "$(wc -c < "$HOOK/out-cap.json" | tr -d ' ')" "0"
assert_eq "$(grep -c 'consecutive blocks (Claude Code cap) at iter=8' "$HOOK/err")" "1"
assert_eq "$(cat "$HOOK/ws/state/hook/iter")" "8"
# A new message resets the run even when the file holds an old count.
echo 5 > "$HOOK/ws/state/hook/consecutive-blocks"
HOOK_ACTIVE=false run_stop_hook > "$HOOK/out-cap.json"
assert_eq "$(jq -r '.decision' "$HOOK/out-cap.json")" "block"
assert_eq "$(cat "$HOOK/ws/state/hook/iter")" "9"
assert_eq "$(cat "$HOOK/ws/state/hook/consecutive-blocks")" "1"
# RALPH_HOST_BLOCK_CAP=0 turns the cap check off.
echo 20 > "$HOOK/ws/state/hook/consecutive-blocks"
HOOK_ACTIVE=true run_stop_hook RALPH_HOST_BLOCK_CAP=0 > "$HOOK/out-cap.json"
assert_eq "$(jq -r '.decision' "$HOOK/out-cap.json")" "block"
# An empty fix_plan sends no excerpt, and the log does not claim one.
: > "$HOOK/fix_plan.md"
run_stop_hook RALPH_INJECT_FIX_PLAN=1 > "$HOOK/out-empty.json"
assert_eq "$(jq -r '.reason | contains("<fix_plan_md>")' "$HOOK/out-empty.json")" "false"
assert_eq "$(grep -c 'fix_plan excerpt' "$HOOK/err")" "0"

# with_worktree: every call gets its own path and branch, never removes an
# existing one, and reports a failed `git worktree add` instead of echoing a
# path it did not create. merge_or_discard_worktree finds the branch itself.
for plugin in ralph-trio spec-trio; do
  WTREPO="$TMP/wt-$plugin"
  git init -q "$WTREPO"
  git -C "$WTREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  assert_eq "$(PLUGIN_ROOT="$ROOT/$plugin" TEAM="smoke-$$" bash -c '
    . "$PLUGIN_ROOT/lib/common.sh"
    cd "$1" || exit 9
    base=$(git symbolic-ref --short HEAD)
    # The worktrees live under /tmp, outside $TMP: remove them even on failure.
    a="" b="" c="" d="" e="" f="" g="" h=""
    trap '\''for w in "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; do [ -n "$w" ] && git worktree remove --force "$w" 2>/dev/null; [ -n "$w" ] && rm -rf "$w"; done; true'\'' EXIT
    a=$(with_worktree 1 "$base" 2>/dev/null) || exit 9
    printf "a\n" > "$a/a.txt"
    git -C "$a" add a.txt && git -C "$a" -c user.name=t -c user.email=t@t commit -qm a
    b=$(with_worktree 1 "$base" 2>/dev/null) || exit 9
    [ "$a" != "$b" ] && [ -f "$a/a.txt" ] && echo distinct
    [ "$(worktree_branch "$a" 1)" != "$(worktree_branch "$b" 1)" ] && echo branches
    x=$(with_worktree 2 no-such-ref 2>/dev/null); echo "bad-rc=$? out=$x"
    ls -d "/tmp/ralph-$TEAM-iter-2."* >/dev/null 2>&1 || echo no-leftover
    merge_or_discard_worktree "$b" 1 0 "$PWD" >/dev/null 2>&1 && [ ! -d "$b" ] && echo discarded
    merge_or_discard_worktree "$a" 1 1 "$PWD" >/dev/null 2>&1 && [ -f a.txt ] && echo merged
    merge_or_discard_worktree "$PWD/nope" 1 1 "$PWD" >/dev/null 2>&1 || echo missing-refused
    # A coder that switches the worktree to another branch: nothing is
    # auto-committed onto it, merged from it, or deleted.
    git branch feature
    c=$(with_worktree 3 "$base" 2>/dev/null) || exit 9
    git -C "$c" switch -q feature
    printf "c\n" > "$c/c.txt"
    commit_worktree_changes "$c" 3 >/dev/null 2>&1 || echo commit-refused
    git -C "$c" stash -q -u
    pre_merge_validate "$c" "$base" "$(worktree_branch "$c" 3)" >/dev/null 2>&1 || echo validate-refused
    [ "$(git rev-parse feature)" = "$(git rev-parse "$base")" ] && echo feature-untouched
    merge_or_discard_worktree "$c" 3 0 "$PWD" >/dev/null 2>&1 || echo discard-refused
    git rev-parse -q --verify refs/heads/feature >/dev/null && [ -d "$c" ] && echo feature-kept
    # A fast-forward that fails (base moved on) keeps the worktree to recover from.
    d=$(with_worktree 4 "$base" 2>/dev/null) || exit 9
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m iter
    iter_commit=$(git -C "$d" rev-parse HEAD)
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "base moved"
    base_head=$(git rev-parse HEAD)
    if ! merge_or_discard_worktree "$d" 4 1 "$PWD" >/dev/null 2>&1 \
      && case "$(git worktree list --porcelain)" in *"/${d##*/}"*) true ;; *) false ;; esac \
      && [ "$(git -C "$d" symbolic-ref --short HEAD)" = "$(worktree_branch "$d" 4)" ] \
      && [ "$(git -C "$d" rev-parse HEAD)" = "$iter_commit" ] \
      && [ "$(git rev-parse HEAD)" = "$base_head" ]; then
      echo ff-fail-kept
    fi
    # Cleanup that fails (a locked worktree) is rc=2, not a silent success.
    e=$(with_worktree 5 "$base" 2>/dev/null) || exit 9
    git worktree lock "$e"
    merge_or_discard_worktree "$e" 5 0 "$PWD" >/dev/null 2>&1
    [ "$?" = 2 ] && [ -d "$e" ] && echo cleanup-fail-rc2
    [ "$(worktree_leftovers "$e" 5 "$PWD")" = "$(printf "Worktree: %s\nBranch: %s" "$e" "$(worktree_branch "$e" 5)")" ] \
      && echo leftovers-rc2
    git worktree unlock "$e"
    # A branch that cannot be deleted after the worktree went is also rc=2, and
    # the leftovers name only the branch, not the removed path (#114).
    f=$(with_worktree 6 "$base" 2>/dev/null) || exit 9
    fbr=$(worktree_branch "$f" 6)
    lock="$(git rev-parse --git-common-dir)/refs/heads/$fbr.lock"
    : > "$lock"
    merge_or_discard_worktree "$f" 6 0 "$PWD" >/dev/null 2>&1
    [ "$?" = 2 ] && [ ! -d "$f" ] && git rev-parse -q --verify "refs/heads/$fbr" >/dev/null \
      && [ "$(worktree_leftovers "$f" 6 "$PWD")" = "Branch: $fbr" ] && echo branch-left-rc2
    rm -f "$lock"
    # A coder that switched the worktree off its branch and deleted that
    # branch leaves only the worktree: the leftovers do not name a gone branch.
    g=$(with_worktree 7 "$base" 2>/dev/null) || exit 9
    git -C "$g" switch -q -c elsewhere && git branch -q -D "$(worktree_branch "$g" 7)"
    merge_or_discard_worktree "$g" 7 0 "$PWD" >/dev/null 2>&1
    [ "$?" = 1 ] && [ "$(worktree_leftovers "$g" 7 "$PWD")" = "Worktree: $g" ] && echo leftovers-no-branch
    # Nothing is named as a survivor once the coder removed both itself.
    h=$(with_worktree 8 "$base" 2>/dev/null) || exit 9
    hbr=$(worktree_branch "$h" 8)
    git worktree remove --force "$h" && git branch -q -D "$hbr"
    [ "$(worktree_leftovers "$h" 8 "$PWD")" = "Left: nothing (worktree $h and branch $hbr are gone)" ] \
      && echo leftovers-none
  ' _ "$WTREPO")" "$(printf '%s\n' distinct branches "bad-rc=1 out=" no-leftover discarded merged \
      missing-refused commit-refused validate-refused feature-untouched discard-refused feature-kept \
      ff-fail-kept cleanup-fail-rc2 leftovers-rc2 branch-left-rc2 leftovers-no-branch leftovers-none)"
done

# spec-trio scope gate: paths are listed verbatim (non-ASCII names match the
# allowlist), a committed rename surfaces its out-of-scope source, and a name
# the line-based check can't represent fails closed.
SCOPE="$TMP/scope"
git init -q "$SCOPE"
mkdir -p "$SCOPE/config" "$SCOPE/src" "$SCOPE/docs"
printf 'a\n' > "$SCOPE/config/prod.yaml"
git -C "$SCOPE" add . && git -C "$SCOPE" -c user.name=t -c user.email=t@t commit -qm base
SCOPE_BASE="$(git -C "$SCOPE" rev-parse HEAD)"
git -C "$SCOPE" mv config/prod.yaml src/prod.yaml
git -C "$SCOPE" -c user.name=t -c user.email=t@t commit -qm move
printf 'k\n' > "$SCOPE/docs/한글.md"
printf 'q\n' > "$SCOPE/src/a -> b.txt"
printf 'n\n' > "$SCOPE/src/new
line.txt"
SCOPE_OUT="$(bash -c '
  . "$1/spec-trio/lib/spec-helpers.sh"
  check_scope "$2" "$(printf "src/\ndocs/한글.md\n")" "$3" "" "$4"
  echo "rc=$?"
' _ "$ROOT" "$SCOPE" "$TMP/scope.log" "$SCOPE_BASE")"
assert_eq "$SCOPE_OUT" "rc=1"
assert_eq "$(sed -n '/^--- offending paths ---$/,$p' "$TMP/scope.log" | sed 1d | sort)" \
  "$(printf '%s\n' '/<path containing a newline>: src/new\nline.txt' config/prod.yaml | sort)"

# A submodule whose only change is untracked content is still a change (plain
# `git diff` hides it).
git init -q "$TMP/sub"
git -C "$TMP/sub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m sub
git init -q "$TMP/super"
git -C "$TMP/super" -c protocol.file.allow=always submodule add -q "$TMP/sub" vendor/sub 2>/dev/null
git -C "$TMP/super" -c user.name=t -c user.email=t@t commit -qm base
printf 'x\n' > "$TMP/super/vendor/sub/new.txt"
assert_eq "$(bash -c '. "$1/spec-trio/lib/spec-helpers.sh"; collect_changed_paths "$2" "$3"' \
  _ "$ROOT" "$TMP/super" "$(git -C "$TMP/super" rev-parse HEAD)")" "vendor/sub"
# ...and a committed gitlink bump stays visible under submodule.<name>.ignore=all.
SUPER_BASE="$(git -C "$TMP/super" rev-parse HEAD)"
git -C "$TMP/super" config submodule.vendor/sub.ignore all
rm "$TMP/super/vendor/sub/new.txt"
git -C "$TMP/super/vendor/sub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m bump
git -C "$TMP/super" add vendor/sub
git -C "$TMP/super" -c user.name=t -c user.email=t@t commit -qm bump
assert_eq "$(bash -c '. "$1/spec-trio/lib/spec-helpers.sh"; collect_changed_paths "$2" "$3"' \
  _ "$ROOT" "$TMP/super" "$SUPER_BASE")" "vendor/sub"

# The first commit of a repo that had none: spec-trio anchors on the empty
# tree, so that commit's paths are scope-checked too.
git init -q "$TMP/unborn"
EMPTY_TREE="$(git -C "$TMP/unborn" hash-object -t tree /dev/null)"
printf 'x\n' > "$TMP/unborn/outside.txt"
git -C "$TMP/unborn" add outside.txt
git -C "$TMP/unborn" -c user.name=t -c user.email=t@t commit -qm first
assert_eq "$(bash -c '. "$1/spec-trio/lib/spec-helpers.sh"; collect_changed_paths "$2" "$3"' \
  _ "$ROOT" "$TMP/unborn" "$EMPTY_TREE")" "outside.txt"

# #107: the README's wrapper recipe starts ralph-solo.sh from any
# directory; a symlink cannot find lib/, and the error names the path it tried
# instead of blaming jq.
LAUNCH_TMP="$TMP/launch"
mkdir -p "$LAUNCH_TMP/bin"
printf '#!/bin/bash\nexec %q "$@"\n' "$ROOT/ralph-trio/bin/ralph-solo.sh" > "$LAUNCH_TMP/bin/ralph-solo"
chmod +x "$LAUNCH_TMP/bin/ralph-solo"
assert_ok "$LAUNCH_TMP/bin/ralph-solo" --help >/dev/null 2>&1
ln -s "$ROOT/ralph-trio/bin/ralph-solo.sh" "$LAUNCH_TMP/bin/ralph-link"
rc=0; "$LAUNCH_TMP/bin/ralph-link" --help >/dev/null 2>"$LAUNCH_TMP/link.err" || rc=$?
assert_eq "$rc" "2"
assert_eq "$(grep -c "ralph-solo: failed to load $LAUNCH_TMP/lib/common.sh" "$LAUNCH_TMP/link.err")" "1"
assert_eq "$(grep -c 'jq missing' "$LAUNCH_TMP/link.err")" "0"

# #170/#172: the plist is strict XML and paths are data, not shell source.
# Exercise every character called out by #170 through the generated argv, cwd,
# environment and cron-wrapper contracts.
LAUNCH_TEMPLATE="$ROOT/ralph-trio/templates/launchd/com.user.ralph.plist.template"
LAUNCH_RENDERER="$ROOT/ralph-trio/bin/render-launchd-plist.py"
assert_ok python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$LAUNCH_TEMPLATE"
if command -v xmllint >/dev/null 2>&1; then
  assert_ok xmllint --noout "$LAUNCH_TEMPLATE"
fi

SPECIAL_ROOT="$TMP/launch space 'single' \"double\" \$dollar & amp"
SPECIAL_REPO="$SPECIAL_ROOT/repo {{REPO}} {{RALPH_SOLO_BIN}} space 'single' \"double\" \$dollar & amp"
SPECIAL_BIN_DIR="$SPECIAL_ROOT/bin {{REPO}} {{RALPH_SOLO_BIN}} space 'single' \"double\" \$dollar & amp"
SPECIAL_BIN="$SPECIAL_BIN_DIR/ralph solo 'single' \"double\" \$dollar & amp"
SPECIAL_PLIST="$SPECIAL_ROOT/generated launchd.plist"
SPECIAL_TEST_CMD='echo "{{REPO}}" && npm test & lint "$HOME"'
LAUNCH_CAPTURE="$SPECIAL_ROOT/launch capture"
export LAUNCH_CAPTURE
mkdir -p "$SPECIAL_REPO/.ralph-trio/log/overnight" "$SPECIAL_BIN_DIR"
cat > "$SPECIAL_BIN" <<'STUB'
#!/bin/bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'team=%s\n' "${AGENT_TEAM-}"
  for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} > "$LAUNCH_CAPTURE"
STUB
chmod +x "$SPECIAL_BIN"
printf 'replace me\n' > "$SPECIAL_PLIST"
assert_ok "$LAUNCH_RENDERER" \
  --repo "$SPECIAL_REPO" \
  --ralph-solo-bin "$SPECIAL_BIN" \
  --test-cmd "$SPECIAL_TEST_CMD" \
  --output "$SPECIAL_PLIST" >/dev/null
assert_ok python3 - "$SPECIAL_PLIST" "$SPECIAL_REPO" "$SPECIAL_BIN" "$SPECIAL_TEST_CMD" <<'PY'
import os
import plistlib
import subprocess
import sys
from pathlib import Path

plist_path, repo, executable, test_command = sys.argv[1:]
with open(plist_path, "rb") as stream:
    plist = plistlib.load(stream)

arguments = [
    executable,
    "--max-iter", "50",
    "--max-runtime", "6h",
    "--worktree",
    "--prompt", f"{repo}/PROMPT.md",
    "--test-cmd", test_command,
]
assert plist["ProgramArguments"] == arguments
assert plist["WorkingDirectory"] == repo
assert plist["StandardOutPath"] == f"{repo}/.ralph-trio/log/overnight/launchd.stdout.log"
assert plist["StandardErrorPath"] == f"{repo}/.ralph-trio/log/overnight/launchd.stderr.log"
assert plist["EnvironmentVariables"]["AGENT_TEAM"] == "overnight"

environment = os.environ.copy()
environment.update(plist["EnvironmentVariables"])
subprocess.run(arguments, cwd=repo, env=environment, check=True)
capture = Path(os.environ["LAUNCH_CAPTURE"]).read_text().splitlines()
assert capture == [f"cwd={repo}", "team=overnight"] + [
    f"arg={argument}" for argument in arguments[1:]
]
PY
if command -v xmllint >/dev/null 2>&1; then
  assert_ok xmllint --noout "$SPECIAL_PLIST"
fi
if command -v plutil >/dev/null 2>&1; then
  assert_ok plutil -lint "$SPECIAL_PLIST"
fi

rc=0
"$LAUNCH_RENDERER" \
  --repo "$SPECIAL_REPO" \
  --ralph-solo-bin "$SPECIAL_BIN" \
  --test-cmd "$SPECIAL_TEST_CMD" \
  --output "$SPECIAL_ROOT/missing/generated.plist" \
  >"$SPECIAL_ROOT/missing.out" 2>"$SPECIAL_ROOT/missing.err" || rc=$?
assert_eq "$rc" "2"
assert_eq "$(grep -c -- '--output parent directory does not exist:' "$SPECIAL_ROOT/missing.err")" "1"
assert_eq "$(grep -c 'Traceback' "$SPECIAL_ROOT/missing.err")" "0"

rc=0
"$LAUNCH_RENDERER" \
  --repo "$SPECIAL_REPO" \
  --ralph-solo-bin "$SPECIAL_BIN" \
  --test-cmd '   ' \
  --output "$SPECIAL_PLIST" \
  >"$SPECIAL_ROOT/empty.out" 2>"$SPECIAL_ROOT/empty.err" || rc=$?
assert_eq "$rc" "2"
assert_eq "$(grep -c -- '--test-cmd must not be empty' "$SPECIAL_ROOT/empty.err")" "1"
assert_eq "$(grep -c 'Traceback' "$SPECIAL_ROOT/empty.err")" "0"

CRON_WRAPPER="$SPECIAL_ROOT/cron wrapper"
CRON_CAPTURE="$SPECIAL_ROOT/cron capture"
printf '#!/bin/bash\ncd %q || exit 1\nexec env AGENT_TEAM=overnight %q --max-iter 50 --max-runtime 6h --worktree --prompt %q --test-cmd %q >> %q 2>&1\n' \
  "$SPECIAL_REPO" "$SPECIAL_BIN" "$SPECIAL_REPO/PROMPT.md" \
  "$SPECIAL_TEST_CMD" \
  "$SPECIAL_REPO/.ralph-trio/log/overnight/cron.log" > "$CRON_WRAPPER"
chmod +x "$CRON_WRAPPER"
assert_ok env LAUNCH_CAPTURE="$CRON_CAPTURE" "$CRON_WRAPPER"
assert_eq "$(sed -n '1p' "$CRON_CAPTURE")" "cwd=$SPECIAL_REPO"
assert_eq "$(sed -n '2p' "$CRON_CAPTURE")" "team=overnight"
assert_eq "$(sed -n '3,$p' "$CRON_CAPTURE")" "$(printf '%s\n' \
  'arg=--max-iter' 'arg=50' 'arg=--max-runtime' 'arg=6h' 'arg=--worktree' \
  'arg=--prompt' "arg=$SPECIAL_REPO/PROMPT.md" \
  'arg=--test-cmd' "arg=$SPECIAL_TEST_CMD")"


smoke_done 30-ralph-spec
