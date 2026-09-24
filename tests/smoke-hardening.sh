#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The drivers take DEV_TRIO_BIN / DEBATE_CONDUCTOR_BIN over PATH; an exported
# override would route these smokes past their stubs.
unset DEV_TRIO_BIN DEBATE_CONDUCTOR_BIN
# agy's home is pinned to a directory that does not exist, so agy roles get
# --add-dir but never --log-file, whatever this machine has installed (#103).
export DEV_TRIO_AGY_HOME=/nonexistent/dev-trio-test-agy-home
PASS=0

assert_ok() { "$@"; PASS=$((PASS + 1)); }
assert_fail() { if "$@" >/dev/null 2>&1; then return 1; fi; PASS=$((PASS + 1)); }

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL (line %s): expected %q, got %q\n' "${BASH_LINENO[0]}" "$2" "$1" >&2
    return 1
  fi
  PASS=$((PASS + 1))
}

for plugin in dev-trio debate-conductor ralph-trio spec-trio; do
  # shellcheck source=/dev/null
  . "$ROOT/$plugin/lib/namespace.sh"
  assert_ok agent_team_validate_id "team-1.alpha" team
  assert_fail agent_team_validate_id "../escape" team
  assert_fail agent_team_validate_id "bad/name" team
  assert_fail agent_team_validate_id "bad name" team
  # grep matches per line, so a multi-line value once passed the pattern check
  # and became a path component. Every copy of the lib must reject it.
  assert_fail agent_team_validate_id "good
EVIL" team
  assert_fail agent_team_validate_id "$(printf 'good\rEVIL')" team
  assert_fail env AGENT_TEAM="good
EVIL" bash -c ". '$ROOT/$plugin/lib/namespace.sh'; agent_team_detect_team"

  # An explicit AGENT_TEAM is a chosen identifier: fail loudly, never guess.
  assert_fail env AGENT_TEAM="../escape" bash -c ". '$ROOT/$plugin/lib/namespace.sh'; agent_team_detect_team"
  # A tmux-derived name is not: sanitize it so ordinary session names still work.
  assert_eq "$(agent_team_sanitize_id 'my project/x')" "myprojectx"
  assert_eq "$(agent_team_sanitize_id '../escape')" "escape"
  assert_eq "$(agent_team_sanitize_id '///')" ""
  assert_eq "$(AGENT_TEAM='' TMUX='' agent_team_detect_team)" "default"
done

# Fixture repos must not pick up the contributor's git setup (signing, hooks).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
LOCKWT=""
# with_worktree creates worktrees under /tmp, outside $TMP.
# The #106 worktree case runs under a team named after $TMP's unique suffix
# (not the PID, which can be recycled), so this glob only matches its own paths.
RD106_TEAM="rd106-$(basename "$TMP" | tr -cd 'A-Za-z0-9')"
trap '[ -n "$LOCKWT" ] && rm -rf "$LOCKWT"; rm -rf "$TMP" /tmp/ralph-"$RD106_TEAM"-iter-*' EXIT
git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name Test
printf 'base\n' > "$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm init

PLUGIN_ROOT="$ROOT/ralph-trio"
# shellcheck source=/dev/null
. "$PLUGIN_ROOT/lib/common.sh"
# A failed auto-commit must leave the worktree and its changes in place.
TEAM="smoke-$$"
LOCKWT="$(cd "$TMP/repo" && with_worktree 1 "$(git symbolic-ref --short HEAD)" 2>/dev/null)"
printf 'changed\n' > "$LOCKWT/file.txt"
touch "$(git -C "$LOCKWT" rev-parse --absolute-git-dir)/index.lock"
assert_fail commit_worktree_changes "$LOCKWT" 1
assert_ok test -d "$LOCKWT"
assert_ok test -n "$(git -C "$LOCKWT" status --porcelain)"
rm -f "$(git -C "$LOCKWT" rev-parse --absolute-git-dir)/index.lock"
unset TEAM

# ask-reviewer.sh --no-memories must reach codex as a config override, and must be
# refused for a model that has no equivalent switch (before anything is spawned).
STUB_CLI="$TMP/stub-cli"
cat > "$STUB_CLI" <<'STUB'
#!/usr/bin/env bash
# Record every argv slot, one per line, and stdin, which carries the prompt
# for the built-in codex models (#102).
printf '%s\n' "$@" > "$STUB_ARGV"
cat > "$STUB_ARGV.stdin"
# Honour native final capture rather than relying on the old log fallback.
while [ $# -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then
    printf '## Verdict\nSHIP — argv fixture\n' > "$2"
    break
  fi
  shift
done
printf '## Verdict\nSHIP — argv fixture\n'
STUB
chmod +x "$STUB_CLI"
run_ask_codex() {
  # Clear the previous run's artifacts so a run that spawns nothing cannot pass
  # on them (several cases expect the same argv).
  rm -f "$TMP/argv" "$TMP/argv.stdin" "$TMP/log/smoke/latest-codex.final.md"
  (cd "$TMP/repo" && env -u REVIEWER_CLI -u DEV_TRIO_REVIEWER_MODEL \
    -u DEV_TRIO_PM_HOST \
    -u MANIFEST_PARENT_TMP -u REVIEWER_ROLE_FILE -u DEV_TRIO_REVIEW_PROFILE \
    CODEX_CLI="$STUB_CLI" CLAUDE_CLI="$STUB_CLI" STUB_ARGV="$TMP/argv" \
    AGENT_TEAM=smoke TMUX="" DEV_TRIO_LOG_DIR="$TMP/log" \
    AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
    "$@" "$ROOT/dev-trio/bin/ask-reviewer.sh" "${ASK_ARGS[@]}" >/dev/null 2>&1)
}
final_path() { printf '%s/log/smoke/%s' "$TMP" "$(readlink "$TMP/log/smoke/latest-codex.final.md")"; }
# Compare argv slot by slot (one per line) so a merged "-c features.memories=false"
# slot cannot pass for the two slots codex needs. The prompt is not in argv:
# codex gets "-" last and the review prompt, focus included, on stdin.
assert_argv() {
  assert_eq "$(cat "$TMP/argv")" "$(printf '%s\n' "$@" "$(final_path)" -)"
  assert_ok grep -q '^focus$' "$TMP/argv.stdin"
}
# Refusal is rc=2 and must happen before any CLI is spawned.
assert_refused() {
  local rc=0
  run_ask_codex "$@" || rc=$?
  assert_eq "$rc" 2
  assert_fail test -e "$TMP/argv"
}

ASK_ARGS=("focus")
assert_ok run_ask_codex
assert_argv exec --skip-git-repo-check --output-last-message

ASK_ARGS=("focus" --no-memories)
assert_ok run_ask_codex
assert_argv exec --skip-git-repo-check -c features.memories=false --output-last-message

# The env var alone selects the model, without the flag.
ASK_ARGS=("focus")
assert_ok run_ask_codex DEV_TRIO_REVIEWER_MODEL=codex-no-memories
assert_argv exec --skip-git-repo-check -c features.memories=false --output-last-message

ASK_ARGS=(--no-memories "focus")
assert_ok run_ask_codex DEV_TRIO_REVIEWER_MODEL=codex-no-memories
assert_argv exec --skip-git-repo-check -c features.memories=false --output-last-message

assert_refused DEV_TRIO_REVIEWER_MODEL=claude

# Config models shadow built-ins: a hand-edited codex-no-memories (here one that
# dropped the override) must not run under a flag that promises the built-in.
printf '%s\n' '{"models":{"codex-no-memories":{"command":"codex","env_command":"CODEX_CLI",
  "args":["exec","{prompt}"],"final_args":["exec","--output-last-message","{final}","{prompt}"]}}}' \
  > "$TMP/shadow-models.json"
assert_refused AGENT_TEAM_MODELS_CONFIG="$TMP/shadow-models.json"

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
DRV="$TMP/drv"
git init -q "$DRV"
printf 'prompt\n' > "$DRV/PROMPT.md"
printf -- '- [ ] task\n' > "$DRV/BACKLOG.md"
printf '# spec\n' > "$DRV/spec.md"
run_driver() {
  (cd "$DRV" && env PATH="$ROOT/dev-trio/bin:$ROOT/debate-conductor/bin:$PATH" \
    AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw" SPEC_TRIO_WORKSPACE="$TMP/sw" \
    "$@" >/dev/null 2>"$TMP/drv.err" </dev/null; echo "rc=$?")
}
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

# agent-team-models remove: role keys are printed one per line, never
# word-split or globbed (a key of `*` once listed the working directory).
for plugin in dev-trio debate-conductor; do
  printf '%s\n' '{"version":1,"models":{"mine":{"command":"x","args":["{prompt}"]}},"roles":{"*":"mine","a b":"mine","dev-trio.reviewer":"codex"}}' \
    > "$TMP/refs-models.json"
  (cd "$TMP" && AGENT_TEAM_MODELS_CONFIG="$TMP/refs-models.json" \
    "$ROOT/$plugin/bin/agent-team-models.sh" remove mine >/dev/null 2>"$TMP/refs.err") || true
  assert_eq "$(sed -n 's/^  //p' "$TMP/refs.err")" "$(printf '*\na b')"
  (cd "$TMP" && AGENT_TEAM_MODELS_CONFIG="$TMP/refs-models.json" \
    "$ROOT/$plugin/bin/agent-team-models.sh" remove mine --force --fallback codex >"$TMP/refs.out" 2>&1)
  assert_eq "$(sed -n 's/^  //p' "$TMP/refs.out")" "$(printf '*\na b')"
  assert_eq "$(jq -c '.roles' "$TMP/refs-models.json")" '{"*":"codex","a b":"codex","dev-trio.reviewer":"codex"}'
done

# agent-team-models must not overwrite a config it could not parse: reads fall
# back to an empty config, and a write built on that would drop every model.
for plugin in dev-trio debate-conductor; do
  bad_cfg='{"version":1,"models":{"mine":{"command":"x","args":["{prompt}"]}},}'
  for cmd in "preset add kimi-code" "add z --command z --arg {prompt}" "edit mine --command y" \
             "remove mine" "set-role dev-trio.reviewer codex"; do
    printf '%s\n' "$bad_cfg" > "$TMP/bad-models.json"
    rc=0
    # shellcheck disable=SC2086  # $cmd is a word list on purpose
    AGENT_TEAM_MODELS_CONFIG="$TMP/bad-models.json" "$ROOT/$plugin/bin/agent-team-models.sh" $cmd \
      >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" 2
    assert_eq "$(cat "$TMP/bad-models.json")" "$bad_cfg"
  done
done

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
    a="" b="" c="" d="" e=""
    trap '\''for w in "$a" "$b" "$c" "$d" "$e"; do [ -n "$w" ] && git worktree remove --force "$w" 2>/dev/null; [ -n "$w" ] && rm -rf "$w"; done; true'\'' EXIT
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
    git worktree unlock "$e"
  ' _ "$WTREPO")" "$(printf '%s\n' distinct branches "bad-rc=1 out=" no-leftover discarded merged \
      missing-refused commit-refused validate-refused feature-untouched discard-refused feature-kept \
      ff-fail-kept cleanup-fail-rc2)"
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

# A worker CLI that exits 0 without an answer has not succeeded: agy's print
# mode can soft-deny a tool and emit only stderr; a native-capture adapter can
# omit its final-answer file. Both paths must fail (rc=5), preserve real answers
# and CLI exit codes, and leave the debate round incomplete.
mkdir -p "$TMP/worker-cli"
printf '#!/bin/sh\necho "no output produced — auto-denied" >&2\nexit 0\n' > "$TMP/worker-cli/denied"
cat > "$TMP/worker-cli/answer" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then
    printf '## Verdict\nVerdict: RECONSIDER\n' > "$2"
    break
  fi
  shift
done
echo progress >&2
echo "## Verdict"
echo "Verdict: RECONSIDER"
STUB
printf '#!/bin/sh\necho boom >&2\nexit 9\n' > "$TMP/worker-cli/broken"
chmod +x "$TMP/worker-cli/denied" "$TMP/worker-cli/answer" "$TMP/worker-cli/broken"
run_worker() {
  local wrapper="$1" stub="$2" rc=0
  ( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEV_TRIO_RESEARCHER_MODEL \
      -u DEBATE_CONDUCTOR_PM_HOST -u DEV_TRIO_PM_HOST TMUX='' AGENT_TEAM=worker \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      DEBATE_LOG_DIR="$TMP/worker-log" DEV_TRIO_LOG_DIR="$TMP/worker-log" \
      GENERATOR_CLI="$TMP/worker-cli/$stub" CRITIC_CLI="$TMP/worker-cli/$stub" \
      RESEARCHER_CLI="$TMP/worker-cli/$stub" \
      "$ROOT/$wrapper" "question" > "$TMP/worker.out" 2>/dev/null </dev/null ) || rc=$?
  echo "$rc"
}
for wrapper in debate-conductor/lib/ask-generator.sh debate-conductor/lib/ask-critic.sh dev-trio/bin/ask-researcher.sh; do
  assert_eq "$(run_worker "$wrapper" denied)" "5"
  assert_eq "$(run_worker "$wrapper" answer)" "0"
  assert_ok grep -q '^Verdict: RECONSIDER$' "$TMP/worker.out"
  assert_eq "$(run_worker "$wrapper" broken)" "9"
done

# registry_run_answer edge cases, called directly under errexit/pipefail.
answer_rc() {
  local stub="$1" rc=0
  shift
  ( env "$@" REGISTRY_CMD_OVERRIDE="$TMP/worker-cli/$stub" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      bash -c 'set -euo pipefail; . "$1/dev-trio/lib/registry.sh"; registry_run_answer agy question' _ "$ROOT" \
      > "$TMP/answer.out" 2>/dev/null </dev/null ) || rc=$?
  echo "$rc"
}
printf '#!/bin/sh\nprintf "  \\n\\n"\n' > "$TMP/worker-cli/blank"
# A child that inherits extra descriptors must not be able to fake a status.
printf '#!/bin/sh\necho answer\necho "rc 0" >&3 2>/dev/null\nexit 9\n' > "$TMP/worker-cli/forge"
printf '#!/bin/sh\nprintf "no newline"\n' > "$TMP/worker-cli/partial"
mkdir -p "$TMP/failing-tee"
printf '#!/bin/sh\ncat\nexit 1\n' > "$TMP/failing-tee/tee"
chmod +x "$TMP/worker-cli/blank" "$TMP/worker-cli/forge" "$TMP/worker-cli/partial" "$TMP/failing-tee/tee"
assert_eq "$(answer_rc blank)" "5"
assert_eq "$(answer_rc forge)" "9"
assert_eq "$(answer_rc partial)" "0"
assert_eq "$(cat "$TMP/answer.out")" "no newline"
# The answer cannot be inspected: 6 when the model succeeded, its own code when not.
assert_eq "$(answer_rc answer PATH="$TMP/failing-tee:$PATH")" "6"
assert_eq "$(answer_rc broken PATH="$TMP/failing-tee:$PATH")" "9"
assert_eq "$(answer_rc answer TMPDIR="$TMP/no-such-dir")" "6"

# With an answer path, the artifact — not stdout — decides. A two-argument call
# keeps the behaviour above, which is what debate-conductor's generator and
# critic rely on; the assertions before this line are that contract.
answer_rc_captured() {
  local stub="$1" rc=0
  shift
  rm -f "$TMP/captured.md"
  ( env "$@" REGISTRY_CMD_OVERRIDE="$TMP/worker-cli/$stub" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      bash -c 'set -euo pipefail; . "$1/dev-trio/lib/registry.sh"; registry_run_answer agy question "$2"' \
      _ "$ROOT" "$TMP/captured.md" \
      > "$TMP/answer.out" 2>/dev/null </dev/null ) || rc=$?
  echo "$rc"
}
assert_eq "$(answer_rc_captured partial)" "0"
assert_eq "$(cat "$TMP/captured.md")" "no newline"
# Captured from stdout alone: a caller's own 2>&1 merge never reaches it.
printf '#!/bin/sh\necho "the answer"\necho "a diagnostic" >&2\n' > "$TMP/worker-cli/noisy"
chmod +x "$TMP/worker-cli/noisy"
assert_eq "$(answer_rc_captured noisy)" "0"
assert_eq "$(cat "$TMP/captured.md")" "the answer"
# Nothing said, nothing captured.
assert_eq "$(answer_rc_captured blank)" "5"
# A nonzero CLI status is never promoted by an artifact on disk.
printf '#!/bin/sh\necho "an answer that must not rescue the status"\nexit 5\n' > "$TMP/worker-cli/answer-then-5"
chmod +x "$TMP/worker-cli/answer-then-5"
assert_eq "$(answer_rc_captured answer-then-5)" "5"
# An answer path that cannot be written is a capture failure, not an empty answer.
answer_rc_to() {
  local stub="$1" dest="$2" rc=0
  shift 2
  ( env "$@" REGISTRY_CMD_OVERRIDE="$TMP/worker-cli/$stub" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      bash -c 'set -euo pipefail; . "$1/dev-trio/lib/registry.sh"; registry_run_answer agy question "$2"' \
      _ "$ROOT" "$dest" > /dev/null 2>/dev/null </dev/null ) || rc=$?
  echo "$rc"
}
assert_eq "$(answer_rc_to answer "$TMP/no-such-dir/answer.md")" "6"

# The private copy of the answer is removed on exit and when the process group
# is interrupted mid-answer.
mkdir -p "$TMP/answer-tmp"
assert_eq "$(answer_rc answer TMPDIR="$TMP/answer-tmp")" "0"
assert_eq "$(ls -A "$TMP/answer-tmp")" ""
printf '#!/bin/sh\necho partial answer\nsleep 30\n' > "$TMP/worker-cli/slow"
chmod +x "$TMP/worker-cli/slow"
assert_eq "$(python3 - "$ROOT" "$TMP" <<'PY'
import os, signal, subprocess, sys, time
root, tmp = sys.argv[1], sys.argv[2]
env = dict(os.environ, TMPDIR=f"{tmp}/answer-tmp",
           REGISTRY_CMD_OVERRIDE=f"{tmp}/worker-cli/slow",
           AGENT_TEAM_MODELS_CONFIG=f"{tmp}/no-models.json")
proc = subprocess.Popen(
    ["bash", "-c", '. "$1/dev-trio/lib/registry.sh"; registry_run_answer agy question', "_", root],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
proc.stdout.readline()
during = len(os.listdir(f"{tmp}/answer-tmp"))
os.killpg(proc.pid, signal.SIGTERM)
proc.wait()
for _ in range(50):
    if not os.listdir(f"{tmp}/answer-tmp"):
        break
    time.sleep(0.1)
print(during, len(os.listdir(f"{tmp}/answer-tmp")))
PY
)" "1 0"

run_debate() {
  local team="$1" gen="$2" crit="$3" rc=0
  ( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEBATE_PRIMARY_GEN \
      -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" DEBATE_LOG_DIR="$TMP/debate-log" \
      GENERATOR_CLI="$TMP/worker-cli/$gen" CRITIC_CLI="$TMP/worker-cli/$crit" \
      "$ROOT/debate-conductor/bin/debate.sh" -n 2 "smoke: $team" > /dev/null 2>&1 </dev/null ) || rc=$?
  echo "$rc"
}
completed_rounds() {
  jq -Rn '[inputs | (fromjson? // empty) | select(.t == "end" and .rc == 0) | .round] | unique | length' \
    "$TMP/debate-log/$1"/debate-*/index.jsonl
}
assert_eq "$(run_debate gen-denied denied answer)" "5"
assert_eq "$(completed_rounds gen-denied)" "0"
# /continue resumes a debate whose round 1 failed at round 1, in the same dir.
continue_debate() {
  local team="$1" dir="$2" rc=0
  ( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEBATE_PRIMARY_GEN \
      -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" DEBATE_LOG_DIR="$TMP/debate-log" \
      GENERATOR_CLI="$TMP/worker-cli/answer" CRITIC_CLI="$TMP/worker-cli/answer" \
      "$ROOT/debate-conductor/bin/debate.sh" --continue-from "$dir" -n 2 "smoke: $team" \
      > /dev/null 2>"$TMP/continue.err" </dev/null ) || rc=$?
  echo "$rc"
}
GEN_DENIED_DIR="$(cd "$TMP/debate-log/gen-denied/latest-debate" && pwd -P)"
assert_eq "$(continue_debate gen-denied "$GEN_DENIED_DIR")" "0"
assert_ok grep -q 'resuming from round 1' "$TMP/continue.err"
assert_eq "$(completed_rounds gen-denied)" "2"
assert_eq "$(ls -d "$TMP/debate-log/gen-denied"/debate-* | wc -l | tr -d ' ')" "1"
assert_eq "$(head -1 "$GEN_DENIED_DIR/round-1-gen.md")" "<!-- debate-round: 1 gen agy -->"
assert_ok grep -qx 'Verdict: RECONSIDER' "$GEN_DENIED_DIR/round-1-gen.md"
# A resume shorter than the failed run removes that run's untouched placeholders
# past the new last round, so the latest round file is a real one.
( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEBATE_PRIMARY_GEN \
    -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM=long-denied \
    AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" DEBATE_LOG_DIR="$TMP/debate-log" \
    GENERATOR_CLI="$TMP/worker-cli/denied" CRITIC_CLI="$TMP/worker-cli/answer" \
    "$ROOT/debate-conductor/bin/debate.sh" -n 6 "smoke: long-denied" > /dev/null 2>&1 </dev/null ) || true
LONG_DIR="$(cd "$TMP/debate-log/long-denied/latest-debate" && pwd -P)"
assert_eq "$(ls "$LONG_DIR" | grep -c '^round-')" "6"
# Later output with missing ledger history must block continuation, even
# outside the requested range. Non-transcript files do not block it.
printf 'kept\n' > "$LONG_DIR/round-5-gen.md"
: > "$LONG_DIR/round-9-notes.md"
assert_eq "$(continue_debate long-denied "$LONG_DIR")" "2"
assert_ok grep -q 'contains output beyond retry round 1' "$TMP/continue.err"
assert_eq "$(cat "$LONG_DIR/round-5-gen.md")" "kept"
: > "$LONG_DIR/round-5-gen.md"
assert_eq "$(continue_debate long-denied "$LONG_DIR")" "0"
assert_eq "$(ls "$LONG_DIR" | grep '^round-' | tr '\n' ' ')" "round-1-gen.md round-2-crit.md round-9-notes.md "
assert_eq "$(completed_rounds long-denied)" "2"
# A debate dir that never started (no topic.txt) is still refused.
mkdir -p "$TMP/debate-log/never-started/debate-20260101-000000"
# A readable empty ledger passes compatibility, but without a topic nothing started.
: > "$TMP/debate-log/never-started/debate-20260101-000000/index.jsonl"
assert_eq "$(continue_debate never-started "$TMP/debate-log/never-started/debate-20260101-000000")" "2"
assert_ok grep -q 'no completed round' "$TMP/continue.err"
assert_eq "$(run_debate crit-denied answer denied)" "5"
assert_eq "$(completed_rounds crit-denied)" "1"
assert_eq "$(run_debate both-answer answer answer)" "0"
assert_eq "$(completed_rounds both-answer)" "2"

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

# Two researchers started in the same second must not share a log or manifest.
# `date` is pinned to one second for the filename format only.
mkdir -p "$TMP/fixed-date"
cat > "$TMP/fixed-date/date" <<'STUB'
#!/bin/sh
[ "$1" = "+%Y%m%d-%H%M%S" ] && { echo 20260101-000000; exit 0; }
exec /bin/date "$@"
STUB
chmod +x "$TMP/fixed-date/date"
run_agy_fixed_second() {
  local rc=0
  ( cd "$TMP" && env -u DEV_TRIO_RESEARCHER_MODEL -u DEV_TRIO_PM_HOST TMUX='' AGENT_TEAM=worker \
      PATH="$TMP/fixed-date:$PATH" AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
      DEV_TRIO_LOG_DIR="$TMP/agy-naming" RESEARCHER_CLI="$TMP/worker-cli/answer" \
      "$ROOT/dev-trio/bin/ask-researcher.sh" "question" > /dev/null 2>&1 </dev/null ) || rc=$?
  echo "$rc"
}
assert_eq "$(run_agy_fixed_second)" "0"
assert_eq "$(run_agy_fixed_second)" "0"
AGY_DIR="$TMP/agy-naming/worker"
AGY_LOGS="$(cd "$AGY_DIR" && ls | grep -cE '^agy-20260101-000000-[0-9]+\.log$' || true)"
assert_eq "$AGY_LOGS" "2"
AGY_MANIFESTS=0
for m in "$AGY_DIR"/agy-20260101-000000-*.manifest.json; do
  [ -f "$m" ] || continue
  jq -e . "$m" >/dev/null
  AGY_MANIFESTS=$((AGY_MANIFESTS + 1))
done
assert_eq "$AGY_MANIFESTS" "2"
AGY_LATEST="$(readlink "$AGY_DIR/latest-agy.log")"
assert_ok test -f "$AGY_DIR/$AGY_LATEST"
assert_eq "$(printf '%s\n' "$AGY_LATEST" | grep -cE '^agy-20260101-000000-[0-9]+\.log$')" "1"
assert_eq "$(cd "$AGY_DIR" && ls -A | grep -c '^\.latest-agy-' || true)" "0"

# ---- Live viewer (tail-role.sh) over per-role streams ----------------------
# debate.sh appends every attempt to debate-<TS>/stream-<role>.log; the viewer
# follows that one file. Every count below is over the viewer's whole capture,
# so a line shown twice or dropped fails, whatever the timing. Each test waits
# until the viewer has displayed content it can only have read from the stream
# before changing anything.
TAIL_PID=""
stop_tail() {
  [ -n "$TAIL_PID" ] || return 0
  kill -TERM "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""
}
trap 'stop_tail; [ -n "$LOCKWT" ] && rm -rf "$LOCKWT"; rm -rf "$TMP"' EXIT
# wait_count FILE PATTERN N: poll up to 15 s until PATTERN occurs on at least N
# lines of FILE (GNU tail can take seconds to notice a file).
wait_count() {
  local i=0
  while [ "$i" -lt 150 ]; do
    [ "$(grep -ac -- "$2" "$1" 2>/dev/null || true)" -ge "$3" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "FAIL: '$2' did not reach $3 in $1" >&2
  cat "$1" >&2
  return 1
}
count() { grep -ac -- "$2" "$1" || true; }
# view ROLE TEAM OUT [VAR=value...]: start a viewer on $TMP/view-log/TEAM.
view() {
  local role="$1" team="$2" out="$3"
  shift 3
  ( cd "$TMP" && exec env -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      DEBATE_LOG_DIR="$TMP/view-log" "$@" "$ROOT/debate-conductor/bin/tail-role.sh" "$role" \
      > "$out" 2>&1 </dev/null ) &
  TAIL_PID=$!
}
# debate_in TEAM GEN_STUB CRIT_STUB ARGS...: run debate.sh ARGS "smoke: TEAM"; prints its rc.
debate_in() {
  local team="$1" gen="$2" crit="$3" rc=0
  shift 3
  ( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEBATE_PRIMARY_GEN \
      -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" DEBATE_LOG_DIR="$TMP/view-log" \
      GENERATOR_CLI="$TMP/worker-cli/$gen" CRITIC_CLI="$TMP/worker-cli/$crit" \
      "$ROOT/debate-conductor/bin/debate.sh" "$@" "smoke: $team" > /dev/null 2>&1 </dev/null ) || rc=$?
  echo "$rc"
}
debate_dir() { (cd "$TMP/view-log/$1/latest-debate" && pwd -P); }
cat > "$TMP/worker-cli/partial-fail" <<'STUB'
#!/bin/sh
i=0; while [ $i -lt 40 ]; do echo "OLD partial line $i of a failed attempt"; i=$((i+1)); done
exit 1
STUB
cat > "$TMP/worker-cli/long-answer" <<'STUB'
#!/bin/sh
echo "NEW-FIRST-LINE of the answer"
i=0; while [ $i -lt 60 ]; do echo "NEW body line $i padded padded padded padded padded"; i=$((i+1)); done
echo "NEW-LAST-LINE"
STUB
cat > "$TMP/worker-cli/tricky" <<'STUB'
#!/bin/sh
echo "TRICKY-START"
echo "<!-- debate-round: 2 crit x -->"
printf 'rs\036byte\n'
printf 'NO-NEWLINE-END'
STUB
chmod +x "$TMP/worker-cli/partial-fail" "$TMP/worker-cli/long-answer" "$TMP/worker-cli/tricky"

# 1. A round whose failed attempt left output is retried and more rounds are
#    added: the pane shows the failed attempt, the retry and the new round once
#    each. A viewer started afterwards shows the same.
assert_eq "$(debate_in retry partial-fail answer -n 2)" "1"
RETRY_DIR="$(debate_dir retry)"
view gen retry "$TMP/view-retry.out"
wait_count "$TMP/view-retry.out" 'OLD partial line 39' 1
assert_eq "$(debate_in retry long-answer answer --continue-from "$RETRY_DIR" -n 3)" "0"
wait_count "$TMP/view-retry.out" 'NEW-LAST-LINE' 2
sleep 1
stop_tail
view gen retry "$TMP/view-retry-late.out"
wait_count "$TMP/view-retry-late.out" 'NEW-LAST-LINE' 2
sleep 1
stop_tail
for out in "$TMP/view-retry.out" "$TMP/view-retry-late.out"; do
  assert_eq "$(count "$out" 'Round 1 · Generator')" "2"
  assert_eq "$(count "$out" 'Round 3 · Generator')" "1"
  assert_eq "$(count "$out" 'OLD partial line')" "40"
  assert_eq "$(count "$out" 'NEW-FIRST-LINE')" "2"
  assert_eq "$(count "$out" 'NEW body line')" "120"
  assert_eq "$(count "$out" 'NEW-LAST-LINE')" "2"
  assert_eq "$(count "$out" '<!-- debate-round')" "0"
  # Only the failed attempt is reported, with its exit status.
  assert_eq "$(count "$out" 'attempt failed')" "1"
  assert_eq "$(count "$out" 'attempt failed (rc=1)')" "1"
done
# Each attempt ends with a record carrying its status: round 1 failed (rc=1),
# its retry and round 3 completed. End records never reach round files.
RS="$(printf '\036')"
ID_RE='id=[0-9]+\.[0-9]+\.[0-9]+'
assert_eq "$(LC_ALL=C grep -ac "^${RS}<!-- debate-round-end: " "$RETRY_DIR/stream-gen.log")" "3"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 1 gen rc=1 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 1 gen rc=0 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 3 gen rc=0 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
# attempt_pairs STREAM: every record in order as `R/id` (header) or `R/id/end`,
# with each distinct id replaced by its first-seen index, so a stream whose
# headers and end records pair up reads 1 1/end 2 2/end ... (#53).
attempt_pairs() {
  LC_ALL=C grep -a "^$(printf '\036')<!-- debate-round" "$1" | awk '
    { id = ""; for (i = 1; i <= NF; i++) if ($i ~ /^id=/) id = substr($i, 4)
      if (!(id in seen)) seen[id] = ++n
      printf "%s%s%s ", $3, "/" seen[id], ($2 == "debate-round-end:") ? "/end" : "" }
    END { print "" }'
}
# The failed round 1, its retry by /continue and round 3: three attempts, the
# retry of the same round and model under a new id.
assert_eq "$(attempt_pairs "$RETRY_DIR/stream-gen.log")" "1/1 1/1/end 1/2 1/2/end 3/3 3/3/end "
assert_eq "$(cat "$RETRY_DIR"/round-*.md | grep -ac 'debate-round-end' || true)" "0"

# 2. Critic round 2 fails twice instantly, then a continue retries it and adds
#    rounds 3-5: every attempt is shown once, including the successful retry.
assert_eq "$(debate_in crit-retry answer denied -n 2)" "5"
CRIT_DIR="$(debate_dir crit-retry)"
view crit crit-retry "$TMP/view-crit.out"
wait_count "$TMP/view-crit.out" 'Round 2 · Critic' 1
assert_eq "$(debate_in crit-retry answer denied --continue-from "$CRIT_DIR" -n 4)" "5"
assert_eq "$(debate_in crit-retry answer answer --continue-from "$CRIT_DIR" -n 4)" "0"
wait_count "$TMP/view-crit.out" 'Round 4 · Critic' 1
wait_count "$TMP/view-crit.out" 'Verdict: RECONSIDER' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-crit.out" 'Round 2 · Critic')" "3"
assert_eq "$(count "$TMP/view-crit.out" 'Round 4 · Critic')" "1"
assert_eq "$(count "$TMP/view-crit.out" 'Verdict: RECONSIDER')" "2"
assert_eq "$(count "$TMP/view-crit.out" 'attempt failed (rc=5)')" "2"
assert_eq "$(count "$TMP/view-crit.out" 'attempt failed')" "2"

# 3. Continuing a completed debate shows only the new rounds after the old ones.
assert_eq "$(debate_in done-continue answer answer -n 2)" "0"
DONE_DIR="$(debate_dir done-continue)"
view crit done-continue "$TMP/view-done.out"
wait_count "$TMP/view-done.out" 'Verdict: RECONSIDER' 1
assert_eq "$(debate_in done-continue answer answer --continue-from "$DONE_DIR" -n 2)" "0"
wait_count "$TMP/view-done.out" 'Verdict: RECONSIDER' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-done.out" 'Round 2 · Critic')" "1"
assert_eq "$(count "$TMP/view-done.out" 'Round 4 · Critic')" "1"
assert_eq "$(count "$TMP/view-done.out" 'attempt failed')" "0"

# 3b. A command feeding the model can fail too (here: the previous generator
#     round is missing when round 3 builds its prompt). The attempt must fail
#     with that status, record it, and not be marked done.
assert_eq "$(debate_in ctx-fail answer answer -n 2)" "0"
CTX_DIR="$(debate_dir ctx-fail)"
rm -f "$CTX_DIR/round-1-gen.md"
assert_eq "$(debate_in ctx-fail answer answer --continue-from "$CTX_DIR" -n 1)" "1"
assert_fail jq -e 'select(.t == "end" and .rc == 0 and .round == 3)' "$CTX_DIR/index.jsonl"
assert_eq "$(LC_ALL=C grep -ac -E "^$(printf '\036')<!-- debate-round-end: 3 gen rc=1 $ID_RE -->$" "$CTX_DIR/stream-gen.log")" "1"

# 3c. INT, TERM and HUP to the debate's process group, or to the debate.sh PID
#     alone (#48), stop the whole attempt within seconds: the model process is
#     gone, nothing keeps writing to the stream, the end record carries 130 /
#     143 / 129, the round is not marked done, and debate.sh dies from the
#     signal (so a bash caller stops too). The parent-INT run wraps debate.sh
#     in a bash loop like ralph-debate.sh's: Ctrl-C must stop the loop. SIGKILL
#     to the group cannot be trapped, but must still reach the model.
cat > "$TMP/worker-cli/slow-stream" <<'STUB'
#!/bin/sh
[ -z "${STUB_PID_FILE:-}" ] || echo $$ > "$STUB_PID_FILE"
i=0; while [ $i -lt 100 ]; do echo "SLOW line $i"; i=$((i+1)); sleep 0.1; done
STUB
chmod +x "$TMP/worker-cli/slow-stream"
for sig in INT TERM HUP parent-INT pid-INT pid-TERM pid-HUP KILL; do
  case "$sig" in
    INT|parent-INT|pid-INT) status=130; signum=2 ;;
    TERM|pid-TERM) status=143; signum=15 ;;
    HUP|pid-HUP) status=129; signum=1 ;;
    KILL) status=""; signum=9 ;;
  esac
  if [ "$sig" = KILL ]; then
    expected="rc=-9 fast=1 model=gone grew=0 ends=0  done=0 continued=0"
  else
    expected="rc=-$signum fast=1 model=gone grew=0 ends=1 <!-- debate-round-end: 1 gen rc=$status id=HEAD --> done=0 continued=0"
  fi
  assert_eq "$(python3 - "$ROOT" "$TMP" "$sig" <<'PYCASE'
import glob, json, os, re, signal, subprocess, sys, time
root, tmp, case = sys.argv[1:4]
sig = case.split("-")[-1]
team = f"cancel-{case}"
env = {k: v for k, v in os.environ.items()
       if k not in ("DEBATE_GENERATOR_MODEL", "DEBATE_CRITIC_MODEL", "DEBATE_PRIMARY_GEN", "DEBATE_CONDUCTOR_PM_HOST")}
pid_file = f"{tmp}/{team}.model-pid"
env.update(TMUX="", AGENT_TEAM=team, AGENT_TEAM_MODELS_CONFIG=f"{tmp}/no-models.json",
           DEBATE_LOG_DIR=f"{tmp}/view-log", GENERATOR_CLI=f"{tmp}/worker-cli/slow-stream",
           CRITIC_CLI=f"{tmp}/worker-cli/answer", STUB_PID_FILE=pid_file)
debate = [f"{root}/debate-conductor/bin/debate.sh", "-n", "2", f"smoke: {team}"]
marker = f"{tmp}/{team}.continued"
if case.startswith("parent-"):
    # A caller loop: runs the debate, then would go on to the next one.
    cmd = ["bash", "-c", 'for t in 1 2; do "$@" || true; echo continued >> "$MARKER"; done', "_", *debate]
    env["MARKER"] = marker
else:
    cmd = debate
p = subprocess.Popen(cmd, cwd=tmp, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
stream = None
for _ in range(150):
    found = glob.glob(f"{tmp}/view-log/{team}/debate-*/stream-gen.log")
    if found and "SLOW line 5" in open(found[0], errors="replace").read():
        stream = found[0]
        break
    time.sleep(0.1)
if stream is None:
    os.killpg(p.pid, signal.SIGKILL)
    print("stream never showed SLOW line 5")
    sys.exit(0)
model = int(open(pid_file).read())
started = time.time()
if case.startswith("pid-"):
    os.kill(p.pid, getattr(signal, "SIG" + sig))
else:
    os.killpg(p.pid, getattr(signal, "SIG" + sig))
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    rc = "timeout"
# The model has 10 s of output left; stopping it must not wait for that.
fast = int(time.time() - started < 3)
def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                          text=True).stdout.strip()[:1] not in ("", "Z")
for _ in range(30):
    if not alive(model):
        break
    time.sleep(0.1)
model_state = "alive" if alive(model) else "gone"
if model_state == "alive":
    os.kill(model, signal.SIGKILL)
size = os.path.getsize(stream)
time.sleep(1.5)
grew = int(os.path.getsize(stream) != size)
ends = [l for l in open(stream, errors="replace") if l.startswith("\x1e<!-- debate-round-end: ")]
rows = [json.loads(l) for l in open(os.path.join(os.path.dirname(stream), "index.jsonl")) if l.strip()]
done = int(any(r["t"] == "end" and r["round"] == 1 and r["rc"] == 0 for r in rows))
continued = int(os.path.exists(marker))
end = ends[0].rstrip(chr(10))[1:] if ends else ""
# The end record names the attempt its header started.
head = [l for l in open(stream, errors="replace") if l.startswith("\x1e<!-- debate-round: ")][0]
head_id = re.search(r" id=(\S+) -->", head).group(1)
end = end.replace(f" id={head_id} -->", " id=HEAD -->")
print(f"rc={rc} fast={fast} model={model_state} grew={grew} ends={len(ends)} {end} done={done} continued={continued}")
PYCASE
)" "$expected"
done

# 3d. A TERM to the debate.sh PID right after an attempt has completed (its
#     rc=0 end record is written), while the next one may be starting: the completed round stays done with rc=0, every
#     attempt header in a stream has exactly one end record, an interrupted
#     attempt records 143 and is not done, and no model keeps running.
assert_eq "$(python3 - "$ROOT" "$TMP" <<'PYRACE'
import glob, json, os, re, signal, subprocess, sys, time
root, tmp = sys.argv[1:3]
team = "cancel-after-done"
env = {k: v for k, v in os.environ.items()
       if k not in ("DEBATE_GENERATOR_MODEL", "DEBATE_CRITIC_MODEL", "DEBATE_PRIMARY_GEN", "DEBATE_CONDUCTOR_PM_HOST")}
pid_file = f"{tmp}/{team}.model-pid"
env.update(TMUX="", AGENT_TEAM=team, AGENT_TEAM_MODELS_CONFIG=f"{tmp}/no-models.json",
           DEBATE_LOG_DIR=f"{tmp}/view-log", GENERATOR_CLI=f"{tmp}/worker-cli/answer",
           CRITIC_CLI=f"{tmp}/worker-cli/slow-stream", STUB_PID_FILE=pid_file)
p = subprocess.Popen([f"{root}/debate-conductor/bin/debate.sh", "-n", "2", f"smoke: {team}"], cwd=tmp, env=env,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
# The stream end follows the authoritative ledger end.
for _ in range(1000):
    streams = glob.glob(f"{tmp}/view-log/{team}/debate-*/stream-gen.log")
    if streams and re.search(r"^\x1e<!-- debate-round-end: 1 gen rc=0 id=\S+ -->$",
                             open(streams[0], errors="replace").read(), re.M):
        break
    time.sleep(0.01)
else:
    os.killpg(p.pid, signal.SIGKILL)
    print("round 1 end record never appeared")
    sys.exit(0)
os.kill(p.pid, signal.SIGTERM)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    rc = "timeout"
time.sleep(0.5)
d = glob.glob(f"{tmp}/view-log/{team}/debate-*")[0]
def records(role, kind):
    # The id of an end record reads ID when it names the header before it, else BAD.
    out, head = [], None
    for l in open(f"{d}/stream-{role}.log", errors="replace"):
        m = re.match(r"\x1e(<!-- debate-round(-end)?: .* id=)(\S+) -->$", l.rstrip(chr(10)))
        if not m:
            continue
        if m.group(2) is None:
            head = m.group(3)
        if (m.group(2) or str()) == kind:
            out.append(m.group(1) + ("ID" if m.group(3) == head else "BAD") + " -->")
    return out
gen_ends = records("gen", "-end")
crit_heads = records("crit", "") if os.path.exists(f"{d}/stream-crit.log") else []
crit_ends = records("crit", "-end") if crit_heads else []
balanced = int(len(crit_heads) == len(crit_ends) and all(e.endswith(" rc=143 id=ID -->") for e in crit_ends))
model = "gone"
if os.path.exists(pid_file):
    pid = int(open(pid_file).read())
    try:
        os.kill(pid, 0)
        if subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()[:1] not in ("", "Z"):
            model = "alive"
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
rows = [json.loads(l) for l in open(f"{d}/index.jsonl") if l.strip()]
completed = {r["round"] for r in rows if r["t"] == "end" and r["rc"] == 0}
print(f"rc={rc} gen={gen_ends} r1done={int(1 in completed)} "
      f"crit-balanced={balanced} r2done={int(2 in completed)} model={model}")
PYRACE
)" "rc=-15 gen=['<!-- debate-round-end: 1 gen rc=0 id=ID -->'] r1done=1 crit-balanced=1 r2done=0 model=gone"

# 3e. The completion-boundary fault matrix now lives in
# tests/test_debate_conductor_hosts.py: it injects signals around status
# selection and ledger/stream ends, and failed ledger starts/ends, without
# relying on the retired sidecar touch syscall.

# 3f. record_attempt_end on its own: an end record already last in the stream
#     is not written again only when it is this attempt's (its id) and has one
#     numeric rc; a selected status survives a signal; a stream that cannot be
#     read is not written to.
record_end_case() {
  local last="$1" selected="$2" rc="$3" path="${4:-$PATH}"
  rm -rf "$TMP/rec" && mkdir -p "$TMP/rec"
  [ -z "$last" ] || printf '%s\n%s\n' "${REC_FIRST-$(printf '\036')<!-- debate-round: 1 gen agy id=7.1 -->}" "$last" > "$TMP/rec/stream-gen.log"
  PATH="$path" REC_SELECTED="$selected" REC_PUBLISHED="${REC_PUBLISHED-1}" bash -c '
    set -euo pipefail
    eval "$(awk '"'"'$0 == "stream_record() {" || $0 == "stream_attempt_end() {" || $0 == "record_attempt_end() {" { f = 1 } f { print } f && $0 == "}" { f = 0 }'"'"' "$1")"
    RS_BYTE="$(printf "\036")"; DEBATE_DIR="$2"
    CUR_ATTEMPT_ROUND=1; CUR_ATTEMPT_ROLE=gen; CUR_ATTEMPT_ID=7.1
    # No ledger here: this case drives the stream half only, and an attempt the
    # ledger never opened writes no end record to it (#44).
    CUR_ATTEMPT_FILE=round-1-gen.md; CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
    [ "$REC_SELECTED" = 0 ] || CUR_ATTEMPT_RC=0
    CUR_ATTEMPT_HEADER="<!-- debate-round: 1 gen agy id=7.1 -->"; CUR_ATTEMPT_PUBLISHED="$REC_PUBLISHED"
    record_attempt_end "$3"
    printf "role=[%s] " "$CUR_ATTEMPT_ROLE"
    if [ -e "$2/stream-gen.log" ]; then
      n="$(LC_ALL=C grep -ac "debate-round-end" "$2/stream-gen.log" || true)"
      printf "%s " "$n"
      sed -n "\$p" "$2/stream-gen.log" | LC_ALL=C tr -d "\036"
    else
      echo "no stream"
    fi
  ' _ "$ROOT/debate-conductor/bin/debate.sh" "$TMP/rec" "$rc"
}
RS_LINE="$(printf '\036')<!-- debate-round-end: 1 gen"
OWN_END="<!-- debate-round-end: 1 gen rc=143 id=7.1 -->"
assert_eq "$(record_end_case "$RS_LINE rc=143 id=7.1 -->" 0 143)" "role=[] 1 $OWN_END"
# Not this attempt's complete record: written.
for last in "rc=0garbage id=7.1" "rc= id=7.1" "id=7.1" "rc=0 rc=1 id=7.1" "rc=0 rc=x id=7.1" \
    "rc=x rc=0 id=7.1" "rc=0 id=7.0" "rc=0 id=17.1" "rc=0 id=7.11" "rc=0" "rc=0 id=7.1 id=7.1"; do
  assert_eq "$(record_end_case "$RS_LINE $last -->" 0 143)" "role=[] 2 $OWN_END"
done
assert_eq "$(record_end_case "$(printf '\036')<!-- debate-round-end: 2 gen rc=0 id=7.1 -->" 0 143)" "role=[] 2 $OWN_END"
assert_eq "$(record_end_case "partial output" 1 143)" "role=[] 1 <!-- debate-round-end: 1 gen rc=0 id=7.1 -->"
assert_eq "$(record_end_case "" 0 130)" "role=[] 1 <!-- debate-round-end: 1 gen rc=130 id=7.1 -->"
mkdir -p "$TMP/failing-tail"
printf '#!/bin/sh\nexit 1\n' > "$TMP/failing-tail/tail"
chmod +x "$TMP/failing-tail/tail"
assert_eq "$(record_end_case "partial output" 1 143 "$TMP/failing-tail:$PATH")" "role=[] 0 partial output"
# A signal inside begin_attempt (#52): the header may not be published yet. The
# record is written only when the stream ends with this attempt's exact header.
HDR_OWN="$(printf '\036')<!-- debate-round: 1 gen agy id=7.1 -->"
HDR_OLD="$(printf '\036')<!-- debate-round: 1 gen agy id=7.0 -->"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OLD" record_end_case "$HDR_OWN" 0 143)" "role=[] 1 $OWN_END"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OWN" record_end_case "$HDR_OLD" 0 143)" "role=[] 0 <!-- debate-round: 1 gen agy id=7.0 -->"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OLD" record_end_case "$HDR_OWN output" 0 143)" "role=[] 0 <!-- debate-round: 1 gen agy id=7.1 --> output"
assert_eq "$(REC_PUBLISHED='' record_end_case "" 0 143)" "role=[] no stream"

# 3g. begin_attempt registers the attempt before publishing its header (#52).
#     The functions run in a shell whose TERM trap records the attempt, as
#     on_signal does; stream_header is wrapped to signal that shell right after
#     the header is written (after), right before (before), or to fail part way
#     through the write (fail). The stream starts with an earlier attempt's
#     header of the same round and model.
cat > "$TMP/ordering.sh" <<'ORDER'
set -euo pipefail
eval "$(awk '$0 ~ /^(stream_record|stream_header|begin_attempt|stream_attempt_end|record_attempt_end|index_append|index_start|index_end)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' "$1")"
# debate_index_file lives in lib/index.sh, which index_append calls.
# $3 is the ordering case; the lib path comes in as $4.
. "$4"
eval "real_$(declare -f stream_header)"
RS_BYTE="$(printf '\036')"; DEBATE_DIR="$2"; ATTEMPT_RUN=7; ATTEMPT_SEQ=0
CUR_ATTEMPT_ROUND=""; CUR_ATTEMPT_ROLE=""; CUR_ATTEMPT_ID=""
CUR_ATTEMPT_HEADER=""; CUR_ATTEMPT_PUBLISHED=""; CUR_ATTEMPT_FILE=""
CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
case "$3" in
  after) stream_header() { real_stream_header "$@"; kill -s TERM $$; } ;;
  before) stream_header() { kill -s TERM $$; real_stream_header "$@"; } ;;
  fail) stream_header() { printf '%s%s' "$RS_BYTE" "<!-- debate-round: 1 gen" >> "$DEBATE_DIR/stream-$1.log"; return 1; } ;;
esac
trap 'record_attempt_end 143; exit 143' TERM
trap 'record_attempt_end "$?"; : > "$DEBATE_DIR/exit-trap"' EXIT
begin_attempt 1 gen agy "$DEBATE_DIR/round-1-gen.md"
echo "begin_attempt returned" >&2
ORDER
ordering_case() {
  local rc=0
  rm -rf "$TMP/ord" && mkdir -p "$TMP/ord"
  printf '%s\n' "$(printf '\036')<!-- debate-round: 1 gen agy id=7.0 -->" > "$TMP/ord/stream-gen.log"
  /bin/bash "$TMP/ordering.sh" "$ROOT/debate-conductor/bin/debate.sh" "$TMP/ord" "$1" \
    "$ROOT/debate-conductor/lib/index.sh" 2>/dev/null || rc=$?
  printf 'rc=%s exit-trap=%s records=%s\n' "$rc" "$([ -e "$TMP/ord/exit-trap" ] && echo 1 || echo 0)" \
    "$(LC_ALL=C grep -a "^$(printf '\036')" "$TMP/ord/stream-gen.log" | LC_ALL=C tr -d '\036' | tr '\n' '|')"
}
assert_eq "$(ordering_case after)" "rc=143 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|<!-- debate-round: 1 gen agy id=7.1 -->|<!-- debate-round-end: 1 gen rc=143 id=7.1 -->|"
assert_eq "$(ordering_case before)" "rc=143 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|"
assert_eq "$(ordering_case fail)" "rc=1 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|<!-- debate-round: 1 gen|"

# 3i. The stream record and the ledger record of one attempt always carry the
#     same status (#44). The two writes are independent, so a signal can land
#     between them: without a decision that outlives the first write, the
#     re-entry normalises again and the records split (measured: stream rc=9,
#     ledger rc=143). index_end is wrapped to signal right after it writes,
#     before the stream end, which is exactly that window.
cat > "$TMP/rcsplit.sh" <<'RCSPLIT'
set -euo pipefail
eval "$(awk '$0 ~ /^(stream_record|stream_header|stream_attempt_end|record_attempt_end|index_append|index_start|index_end)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' "$1")"
. "$3"
eval "real_$(declare -f index_end)"
DEBATE_DIR="$2"; RS_BYTE="$(printf '\036')"
CUR_ATTEMPT_ROUND=1; CUR_ATTEMPT_ROLE=gen; CUR_ATTEMPT_ID=7.1
CUR_ATTEMPT_FILE=round-1-gen.md
CUR_ATTEMPT_HEADER="<!-- debate-round: 1 gen agy id=7.1 -->"; CUR_ATTEMPT_PUBLISHED=1
CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
printf '%s%s\n' "$RS_BYTE" "$CUR_ATTEMPT_HEADER" > "$2/stream-gen.log"
index_start agy && CUR_ATTEMPT_INDEXED=1
[ "$5" = 0 ] || CUR_ATTEMPT_RC=0
# Signal once, not on every call: the trap re-enters record_attempt_end, which
# calls this again, and bash 5 runs the trap recursively where bash 3.2 blocks
# the signal for the duration of its own handler — an unconditional kill here
# looped until the shell died on Linux and passed on macOS.
signalled=""
index_end() {
  real_index_end "$@"
  [ -n "$signalled" ] || { signalled=1; kill -s TERM $$; }
}
trap 'record_attempt_end 143' TERM
record_attempt_end "$4"
RCSPLIT
rcsplit_case() {
  rm -rf "$TMP/rcsplit" && mkdir -p "$TMP/rcsplit"
  /bin/bash "$TMP/rcsplit.sh" "$ROOT/debate-conductor/bin/debate.sh" "$TMP/rcsplit" \
    "$ROOT/debate-conductor/lib/index.sh" "$1" "$2" >/dev/null 2>&1 || true
  printf 'stream=%s ledger=%s\n' \
    "$(LC_ALL=C grep -ao 'rc=[0-9]*' "$TMP/rcsplit/stream-gen.log" | tr '\n' ' ')" \
    "$(jq -r 'select(.t == "end") | "rc=\(.rc)"' "$TMP/rcsplit/index.jsonl" | tr '\n' ' ')"
}
assert_eq "$(rcsplit_case 9 0)" "stream=rc=9  ledger=rc=9 "
assert_eq "$(rcsplit_case 143 0)" "stream=rc=143  ledger=rc=143 "
# Success selected: both records say 0, and the re-entry keeps saying 0.
assert_eq "$(rcsplit_case 9 1)" "stream=rc=0  ledger=rc=0 "

# 3h. wait_attempt waits for an attempt in short steps (#57). bash 3.2's `wait`
#     can miss a trapped signal that arrives as it starts and then run the trap
#     only when the child exits, so debate.sh outlived a TERM by a whole attempt.
#     The helper still returns the attempt's status, so errexit is unchanged, and
#     stop_attempt cleans up the step as well as the attempt.
# The functions are extracted once: 400 trials re-running awk over debate.sh cost
# ~20 s of the suite.
awk '$0 ~ /^(attempt_running|wait_attempt|stop_attempt)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' \
  "$ROOT/debate-conductor/bin/debate.sh" > "$TMP/wait57-funcs.sh"
assert_eq "$(grep -c '^wait_attempt() {\|^attempt_running() {\|^stop_attempt() {' "$TMP/wait57-funcs.sh")" "3"
# The gate is extracted too, so the assertion below reads debate.sh's own value
# rather than a copy of its condition that could drift from it (#66).
awk '/^if \[ -z "\$\{ATTEMPT_WAIT_POLL/ { f = 1 } f { print } f && $0 == "fi" { exit }' \
  "$ROOT/debate-conductor/bin/debate.sh" > "$TMP/wait57-gate.sh"
assert_eq "$(grep -c 'BASH_VERSINFO' "$TMP/wait57-gate.sh")" "1"
cat > "$TMP/wait57.sh" <<'WAIT57'
set -euo pipefail
. "$1"
ATTEMPT_WAIT_STEP=0.2
# Both paths of the #66 gate are driven from here; 1 keeps the pre-gate behavior
# for the cases written against the stepped wait.
ATTEMPT_WAIT_POLL="${ATTEMPT_WAIT_POLL:-1}"
case "$2" in
  status0)  ( exit 0 ) & wait_attempt "$!"; echo "rc=$?" ;;
  status7)  ( exit 7 ) & rc=0; wait_attempt "$!" || rc=$?; echo "rc=$rc" ;;
  reaped)   ( exit 5 ) & pid=$!; sleep 0.5; rc=0; wait_attempt "$pid" || rc=$?; echo "rc=$rc" ;;
  errexit)  ( exit 7 ) & wait_attempt "$!"; echo "not reached" ;;
  race)     trap 'exit 143' TERM
            ( sleep 3 ) <&0 &
            pid=$!
            kill -s TERM $$ &
            wait_attempt "$pid"
            exit 0 ;;
  cleanup)  trap 'stop_attempt; exit 143' TERM
            ( sleep 30 ) <&0 &
            wait_attempt "$!" ;;
  ignore)   rm -f "$1.ready"
            ( trap '' TERM; : > "$1.ready"
              i=0; while [ $i -lt 80 ]; do sleep 0.1; i=$((i+1)); done ) <&0 &
            pid=$!
            i=0
            while [ ! -f "$1.ready" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
            stop_attempt
            if kill -0 "$pid" 2>/dev/null; then echo "bounded=1"; else echo "bounded=0"; fi
            kill -9 "$pid" 2>/dev/null || true ;;
esac
WAIT57
wait57() { /bin/bash "$TMP/wait57.sh" "$TMP/wait57-funcs.sh" "$1" 2>&1; }
# Both sides of the gate must return the attempt's status and keep errexit, so
# every one of these runs twice (#66).
for POLL in 1 0; do
  export ATTEMPT_WAIT_POLL="$POLL"
  assert_eq "poll=$POLL $(wait57 status0)" "poll=$POLL rc=0"
  assert_eq "poll=$POLL $(wait57 status7)" "poll=$POLL rc=7"
  # reaped runs in the python driver below, with a timeout: a liveness regression
  # would hang it here instead of failing.
  assert_eq "poll=$POLL $(wait57 errexit; echo "exit=$?")" "poll=$POLL exit=7"
done
unset ATTEMPT_WAIT_POLL
# Cleanup and bounded latency, timed outside the shell under test: the parent
# sends TERM only once a sleep step is actually running, and inspects the
# process group before its own safety-net kill.
assert_eq "$(python3 - "$ROOT" "$TMP" <<'PYWAIT'
import os, platform, signal, subprocess, sys, time
root, tmp = sys.argv[1:3]
def trial(case, timeout=10):
    p = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", case],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        out, rc = "", "timeout"
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    return out.strip(), rc
def group(pid):
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if l.split()[1] == str(pid)]
# 1. TERM while a step is running: the trap runs stop_attempt, and nothing of the
#    attempt or the step is left behind.
p = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", "cleanup"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
stepped = False
for _ in range(200):
    if any(" sleep 0.2" in l for l in group(p.pid)):
        stepped = True
        break
    time.sleep(0.05)
os.kill(p.pid, signal.SIGTERM)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    rc = "timeout"
time.sleep(0.3)
left = len(group(p.pid))
try:
    os.killpg(p.pid, signal.SIGKILL)
except (ProcessLookupError, PermissionError):
    pass
# 2. An attempt that exited and was reaped before the call: its status, no hang.
reaped = trial("reaped", timeout=10)[0]
# 3. Isolated trials: a TERM racing the start of the wait must never delay the exit
#    by the length of the attempt. Measured 5/400 late with a plain `wait`. The race
#    is a bash 3.2 one (0/300 on 5.2), and a loaded Linux runner could exceed the
#    threshold without it, so only macOS asserts latency.
#    The exit status is asserted on both, and Linux runs the larger batch: it is
#    where #66 lives, a trial costs ~1 ms, and 25 trials missed the pre-gate rate
#    four runs out of five. 500 is ~0.6 s.
#    The stderr of a trial is kept rather than dropped: #66 cost two days because
#    the failure printed only a set of exit codes, while the cause was one line on
#    the stderr this loop used to send to DEVNULL. No apostrophes in this block:
#    bash 3.2 parses the heredoc inside the command substitution around it.
strict = platform.system() == "Darwin"
# Which side of the gate this bash uses, and whether debate.sh agrees. The batch
# runs the path that is actually configured: the stepped poll is only reachable
# on bash 3.x, and forcing it on bash 5 would reintroduce the #66 window the gate
# exists to avoid — 0.10% a trial, which over a batch this size is most runs.
major = int(subprocess.run(["/bin/bash", "-c", "echo ${BASH_VERSINFO[0]}"],
                           capture_output=True, text=True).stdout.strip())
want = "1" if major <= 3 else "0"
gate = subprocess.run(["/bin/bash", "-c", f". {tmp}/wait57-gate.sh; echo $ATTEMPT_WAIT_POLL"],
                      capture_output=True, text=True).stdout.strip()
gate_ok = int(gate == want)
env = dict(os.environ, ATTEMPT_WAIT_POLL=want)
late = 0
codes = set()
errs = set()
for _ in range(400 if strict else 500):
    t0 = time.monotonic()
    with open(f"{tmp}/race-err.txt", "w") as eh:
        q = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", "race"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=eh,
                             start_new_session=True, env=env)
        try:
            code = q.wait(timeout=10)
        except subprocess.TimeoutExpired:
            code = "timeout"
    codes.add(code)
    if str(code) != "143":
        lines = open(f"{tmp}/race-err.txt").read().strip().splitlines()
        errs.add(lines[0][:120] if lines else "(no stderr)")
    if strict and time.monotonic() - t0 >= 1.5:
        late += 1
    try:
        os.killpg(q.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
print(f"stepped={int(stepped)} rc={rc} left={left} reaped=[{reaped}] "
      f"codes={sorted(str(c) for c in codes)} late={late} err={sorted(errs)} gate_ok={gate_ok}")
PYWAIT
)" "stepped=1 rc=143 left=0 reaped=[rc=5] codes=['143'] late=0 err=[] gate_ok=1"

# 3b. stop_attempt is bounded even when a root ignores TERM (#66): it returns
#     while that root is still running, rather than waiting out its lifetime with
#     record_attempt_end and release_lock behind it. Asserted as "stop_attempt
#     returned before the root did", not as a wall-clock threshold: the budget is
#     20 sleeps of 0.1 s plus a ps and a grep each, which a loaded runner stretches
#     — the suite already carries two load-sensitive failures. The child publishes
#     readiness after installing its TERM-ignore trap, so it cannot be stopped
#     before the trap exists and fail this for the wrong reason.
assert_eq "$(wait57 ignore)" "bounded=1"

# 4. Model text cannot draw a banner or move text: a quoted marker is dropped,
#    \x1e is removed, and an answer without a final newline does not swallow the
#    next attempt's header.
assert_eq "$(debate_in tricky tricky answer -n 3)" "0"
TRICKY_DIR="$(debate_dir tricky)"
view gen tricky "$TMP/view-tricky.out"
wait_count "$TMP/view-tricky.out" 'Round 3 · Generator' 1
wait_count "$TMP/view-tricky.out" 'NO-NEWLINE-END' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-tricky.out" 'Round 1 · Generator')" "1"
assert_eq "$(count "$TMP/view-tricky.out" 'Round 3 · Generator')" "1"
assert_eq "$(count "$TMP/view-tricky.out" 'TRICKY-START')" "2"
assert_eq "$(count "$TMP/view-tricky.out" '<!-- debate-round')" "0" || {
  cat "$TMP/view-tricky.out" >&2
  exit 1
}
assert_eq "$(count "$TMP/view-tricky.out" 'rsbyte')" "2"
# Only debate.sh's records carry \x1e (two headers, two end records), each at the
# start of a line: the end record after the unterminated answer starts its own.
assert_eq "$(LC_ALL=C tr -cd '\036' < "$TRICKY_DIR/stream-gen.log" | wc -c | tr -d ' ')" "4"
assert_eq "$(LC_ALL=C grep -ac "^$(printf '\036')" "$TRICKY_DIR/stream-gen.log")" "4"
assert_eq "$(LC_ALL=C grep -ac -E "^$(printf '\036')<!-- debate-round-end: [13] gen rc=0 $ID_RE -->$" "$TRICKY_DIR/stream-gen.log")" "2"
# Round files and the critic stream are untouched by the generator's quoted marker.
assert_eq "$(LC_ALL=C tr -cd '\036' < "$TRICKY_DIR/round-1-gen.md" | wc -c | tr -d ' ')" "0"
assert_eq "$(head -1 "$TRICKY_DIR/round-1-gen.md")" "<!-- debate-round: 1 gen agy -->"
assert_eq "$(LC_ALL=C grep -ac "^$(printf '\036')" "$TRICKY_DIR/stream-crit.log")" "2"

# 4b. Records carry tokens after the role (#53). One stream mixing records
#     without ids, with ids, with unknown tokens and malformed end records: the
#     viewer draws each header, reports each failed attempt once, and drops
#     only framed lines it cannot read. A model line that merely looks like a
#     marker with extra words is model text and stays visible.
CRAFT_DIR="$TMP/view-log/crafted/debate-20260101-000002"
mkdir -p "$CRAFT_DIR"
ln -s debate-20260101-000002 "$TMP/view-log/crafted/latest-debate"
{
  printf '\036<!-- debate-round: 1 gen agy -->\nLEGACY-BODY\n\036<!-- debate-round-end: 1 gen rc=3 -->\n'
  printf '\036<!-- debate-round: 1 gen agy id=9.1 -->\nID-BODY\n\036<!-- debate-round-end: 1 gen rc=4 id=9.1 -->\n'
  printf '\036<!-- debate-round: 2 gen codex id=9.2 future=x -->\nFUTURE-BODY\n'
  printf '\036<!-- debate-round-end: 2 gen id=9.2 rc=6 future=x -->\n'
  printf '\036<!-- debate-round: 3 gen id=9.3 -->\nNO-MODEL-BODY\n'
  printf '<!-- debate-round: 2 crit example extra words -->\n'
  printf '<!-- debate-round: 2 crit x -->\n'
  for bad in "id=9.3" "rc= id=9.3" "rc=1x id=9.3" "rc=7 rc=8 id=9.3" "rc=7 rc=x id=9.3" "rc=x rc=7 id=9.3"; do
    printf '\036<!-- debate-round-end: 3 gen %s -->\n' "$bad"
  done
  printf '\036<!-- debate-round-end: 3 gen rc=0 id=9.3 -->\nCRAFT-END\n'
} > "$CRAFT_DIR/stream-gen.log"
# check_crafted OUT [VAR=value...]: view the crafted stream and check it.
check_crafted() {
  local out="$1" body
  : > "$out"
  view gen crafted "$@"
  wait_count "$out" 'CRAFT-END' 1
  stop_tail
  assert_eq "$(count "$out" 'Round 1 · Generator · agy')" "2"
  assert_eq "$(count "$out" 'Round 2 · Generator · codex')" "1"
  assert_eq "$(count "$out" 'Round 3 · Generator')" "1"
  assert_eq "$(count "$out" 'Round 3 · Generator · ')" "0"
  assert_eq "$(grep -ao 'attempt failed (rc=[^)]*)' "$out" | tr '\n' ' ')" \
    "attempt failed (rc=3) attempt failed (rc=4) attempt failed (rc=6) "
  assert_eq "$(count "$out" 'example extra words')" "1"
  assert_eq "$(count "$out" '2 crit x')" "0"
  assert_eq "$(count "$out" 'id=')" "0"
  assert_eq "$(LC_ALL=C grep -ac "$(printf '\036')" "$out" || true)" "0"
  for body in LEGACY-BODY ID-BODY FUTURE-BODY NO-MODEL-BODY; do
    assert_eq "$(count "$out" "$body")" "1"
  done
}
check_crafted "$TMP/view-crafted.out"

# 5. A new debate: the pane stops the old one before announcing the new one, and
#    shows each debate's content exactly once.
assert_eq "$(debate_in retarget partial-fail answer -n 2)" "1"
view gen retarget "$TMP/view-retarget.out"
wait_count "$TMP/view-retarget.out" 'OLD partial line 39' 1
sleep 1.1  # a new debate-<TS> directory needs a different second
assert_eq "$(debate_in retarget long-answer answer -n 2)" "0"
wait_count "$TMP/view-retarget.out" 'NEW-LAST-LINE' 1
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-retarget.out" 'new debate run detected')" "1"
assert_eq "$(count "$TMP/view-retarget.out" 'OLD partial line')" "40"
assert_eq "$(count "$TMP/view-retarget.out" 'NEW body line')" "60"
assert_eq "$(sed -n '/new debate run detected/,$p' "$TMP/view-retarget.out" | grep -ac 'OLD partial line' || true)" "0"
assert_eq "$(sed -n '1,/new debate run detected/p' "$TMP/view-retarget.out" | grep -ac 'NEW body line' || true)" "0"

# 6. A debate created before streams existed: the pane says so once, then shows
#    the rounds a continue adds.
assert_eq "$(debate_in legacy answer answer -n 2)" "0"
LEGACY_DIR="$(debate_dir legacy)"
rm -f "$LEGACY_DIR/stream-gen.log" "$LEGACY_DIR/stream-crit.log"
view crit legacy "$TMP/view-legacy.out"
wait_count "$TMP/view-legacy.out" 'predates live streams' 1
assert_eq "$(debate_in legacy answer answer --continue-from "$LEGACY_DIR" -n 2)" "0"
wait_count "$TMP/view-legacy.out" 'Round 4 · Critic' 1
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-legacy.out" 'predates live streams')" "1"
assert_eq "$(count "$TMP/view-legacy.out" 'Round 2 · Critic')" "0"
assert_eq "$(count "$TMP/view-legacy.out" 'Round 4 · Critic')" "1"
# The note also appears when the round files show up after the viewer started.
mkdir -p "$TMP/view-log/legacy-late/debate-20260101-000000"
ln -s debate-20260101-000000 "$TMP/view-log/legacy-late/latest-debate"
view crit legacy-late "$TMP/view-legacy-late.out"
sleep 1.5
cp "$LEGACY_DIR/round-2-crit.md" "$TMP/view-log/legacy-late/debate-20260101-000000/"
wait_count "$TMP/view-legacy-late.out" 'predates live streams' 1
stop_tail
assert_eq "$(count "$TMP/view-legacy-late.out" 'predates live streams')" "1"

# 6b. If the follower dies (its tail killed), the pane says so and stops rather
#     than replaying the stream and showing everything twice.
view crit done-continue "$TMP/view-killed.out"
wait_count "$TMP/view-killed.out" 'Round 4 · Critic' 1
KILLED_STREAM="$DONE_DIR/stream-crit.log"
i=0
while [ "$i" -lt 50 ] && ! pgrep -f "tail -n [+]1 -F $KILLED_STREAM" >/dev/null; do sleep 0.1; i=$((i + 1)); done
pkill -f "tail -n [+]1 -F $KILLED_STREAM"
wait_count "$TMP/view-killed.out" 'stream follower stopped' 1
i=0
while [ "$i" -lt 50 ] && kill -0 "$TAIL_PID" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
assert_fail kill -0 "$TAIL_PID"
TAIL_PID=""
assert_eq "$(count "$TMP/view-killed.out" 'Round 2 · Critic')" "1"
assert_eq "$(count "$TMP/view-killed.out" 'Round 4 · Critic')" "1"

# 7. mawk reads a pipe in blocks unless run with -W interactive. The fake mawk
#    below identifies itself like mawk and, without -W interactive, holds all
#    input until EOF, which `tail -F` never sends. When the host awk is itself
#    mawk, the pass-through keeps -W interactive.
REAL_AWK="$(command -v awk)"
REAL_AWK_STREAM=""
case "$("$REAL_AWK" -W version 2>&1 </dev/null || true)" in mawk*) REAL_AWK_STREAM="-W interactive" ;; esac
mkdir -p "$TMP/fake-mawk"
cat > "$TMP/fake-mawk/awk" <<STUB
#!/bin/sh
if [ "\$1" = -W ] && [ "\$2" = version ]; then echo "mawk 1.3.4 fake"; exit 0; fi
if [ "\$1" = -W ] && [ "\$2" = interactive ]; then shift 2; exec "$REAL_AWK" $REAL_AWK_STREAM "\$@"; fi
held="$TMP/fake-mawk/held.\$\$"
cat > "\$held"
exec "$REAL_AWK" "\$@" "\$held"
STUB
chmod +x "$TMP/fake-mawk/awk"
view crit done-continue "$TMP/view-mawk.out" PATH="$TMP/fake-mawk:$PATH"
wait_count "$TMP/view-mawk.out" 'Round 4 · Critic' 1
stop_tail
assert_eq "$(count "$TMP/view-mawk.out" 'Round 2 · Critic')" "1"
check_crafted "$TMP/view-crafted-fake-mawk.out" PATH="$TMP/fake-mawk:$PATH"
# The fake only checks line-by-line reading; the parsing runs on the host awk.
# Parse the crafted stream with each other awk installed too.
for other_awk in mawk gawk nawk; do
  other_path="$(command -v "$other_awk" 2>/dev/null || true)"
  [ -n "$other_path" ] || continue
  mkdir -p "$TMP/awk-$other_awk"
  ln -sf "$other_path" "$TMP/awk-$other_awk/awk"
  check_crafted "$TMP/view-crafted-$other_awk.out" PATH="$TMP/awk-$other_awk:$PATH"
done

# 8. A short first line reaches the stream while the model is still running
#    (sed must not block-buffer; #42).
cat > "$TMP/worker-cli/held-open" <<STUB
#!/bin/sh
echo "EARLY-LINE"
# Also stop when the fixture is gone, so a failed assertion cannot leave it running.
while [ ! -e "$TMP/held-open.release" ] && [ -d "$TMP" ]; do sleep 0.1; done
echo "LATE-LINE"
STUB
chmod +x "$TMP/worker-cli/held-open"
rm -f "$TMP/held-open.release"
( debate_in held held-open answer -n 1 > "$TMP/held-open.rc" ) &
HELD_PID=$!
i=0
while [ "$i" -lt 100 ] && ! grep -aq 'EARLY-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
assert_eq "$(grep -ac 'EARLY-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null || true)" "1"
assert_eq "$(grep -ac 'LATE-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null || true)" "0"
: > "$TMP/held-open.release"
wait "$HELD_PID"
assert_eq "$(cat "$TMP/held-open.rc")" "0"
assert_eq "$(grep -ac 'LATE-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log")" "1"

cmp "$ROOT/ralph-trio/lib/stage-result.sh" "$ROOT/spec-trio/lib/stage-result.sh"
PASS=$((PASS + 1))

cmp "$ROOT/dev-trio/lib/registry.sh" "$ROOT/debate-conductor/lib/registry.sh"
PASS=$((PASS + 1))
cmp "$ROOT/dev-trio/bin/agent-team-models.sh" "$ROOT/debate-conductor/bin/agent-team-models.sh"
PASS=$((PASS + 1))

# #103: agy's workspace_args/log_args are prefixed only when the caller passes
# REGISTRY_WORKSPACE / REGISTRY_CLI_LOG, each on its own; with neither, argv is
# what it always was (debate-conductor never sets them).
REG_TMP=$(mktemp -d)
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\necho\n' > "$REG_TMP/rec"
chmod +x "$REG_TMP/rec"
registry_argv() {
  env -u REGISTRY_WORKSPACE -u REGISTRY_CLI_LOG -u REGISTRY_CMD_OVERRIDE \
    AGENT_TEAM_MODELS_CONFIG="$REG_TMP/none.json" AGY_CLI="$REG_TMP/rec" CODEX_CLI="$REG_TMP/rec" \
    "$@" bash -c '. "$1/dev-trio/lib/registry.sh"; shift; eval "$*"' _ "$ROOT" "$REG_CALL"
}
REG_CALL='registry_run agy P'
assert_eq "$(registry_argv)" '[-p][P]'
REG_CALL='REGISTRY_WORKSPACE=/r registry_run agy P'
assert_eq "$(registry_argv)" '[--add-dir][/r][-p][P]'
REG_CALL='REGISTRY_CLI_LOG=/l registry_run agy P'
assert_eq "$(registry_argv)" '[--log-file][/l][-p][P]'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run agy P'
assert_eq "$(registry_argv)" '[--log-file][/l][--add-dir][/r][-p][P]'
REG_CALL='REGISTRY_WORKSPACE= REGISTRY_CLI_LOG= registry_run agy P'
assert_eq "$(registry_argv REGISTRY_WORKSPACE=/stale REGISTRY_CLI_LOG=/stale)" '[-p][P]'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run codex P'
assert_eq "$(registry_argv)" '[exec][--skip-git-repo-check][-]'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run_answer agy P; echo "rc=$?"'
assert_eq "$(registry_argv)" "$(printf '[--log-file][/l][--add-dir][/r][-p][P]\nrc=0')"
REG_CALL='registry_has_workspace agy && ! registry_has_workspace codex && echo yes'
assert_eq "$(registry_argv)" yes

# #102: one argument is capped at 128 KiB on Linux (MAX_ARG_STRLEN). The claude
# and codex built-ins take the prompt on stdin, whole; argv models refuse a
# prompt that one argument cannot hold, on every platform. The big prompt is
# built inside the call: passing it in REG_CALL would itself be one argument.
# Only Linux CI proves the kernel side; the byte counts below hold everywhere.
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\nprintf " stdin=%%s\\n" "$(wc -c | tr -d " ")"\n' > "$REG_TMP/count"
chmod +x "$REG_TMP/count"
mkdir "$REG_TMP/stage"
count_argv() { registry_argv CLAUDE_CLI="$REG_TMP/count" CODEX_CLI="$REG_TMP/count" TMPDIR="$REG_TMP/stage" "$@"; }
BIG='big=$(printf "%300000s" "" | tr " " x); '
REG_CALL="${BIG}registry_run claude \"\$big\""
assert_eq "$(count_argv)" '[-p] stdin=300001'
REG_CALL="${BIG}registry_run claude-write \"\$big\""
assert_eq "$(count_argv)" '[-p][--permission-mode][acceptEdits] stdin=300001'
REG_CALL="${BIG}registry_run codex \"\$big\""
assert_eq "$(count_argv)" '[exec][--skip-git-repo-check][-] stdin=300001'
REG_CALL="${BIG}registry_run codex-no-memories \"\$big\" /f"
assert_eq "$(count_argv)" '[exec][--skip-git-repo-check][-c][features.memories=false][--output-last-message][/f][-] stdin=300001'
REG_CALL="${BIG}registry_run_answer codex \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv)" "$(printf '[exec][--skip-git-repo-check][-] stdin=300001\nrc=0')"
# The prompt (plus the here-string's newline) is the CLI's stdin; bash leaves
# no temp file behind, and the caller's own stdin never reaches the CLI.
assert_eq "$(ls -A "$REG_TMP/stage")" ''
REG_CALL='echo CALLER-STDIN | registry_run claude P'
assert_eq "$(count_argv)" '[-p] stdin=2'
# A CLI that exits without reading the prompt keeps its own status, also
# under the caller's pipefail.
printf '#!/bin/sh\nexit "$STUB_RC"\n' > "$REG_TMP/early"
chmod +x "$REG_TMP/early"
REG_CALL="set -o pipefail; ${BIG}registry_run claude \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/early" STUB_RC=0)" 'rc=0'
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/early" STUB_RC=7)" 'rc=7'
# A child the CLI leaves holding stdin must not keep the call waiting (a
# `printf | cli` writer would block on a 300 KB prompt). The child waits at most 10 s
# for the release file and leaves a marker if it had to give up.
cat > "$REG_TMP/leaky" <<'STUB'
#!/bin/sh
( i=0
  while [ ! -e "$LEAK_RELEASE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$LEAK_RELEASE" ] || : > "$LEAK_RELEASE.gave-up" ) <&0 >/dev/null 2>&1 &
echo answered
STUB
chmod +x "$REG_TMP/leaky"
REG_CALL="${BIG}registry_run claude \"\$big\"; echo \"rc=\$?\"; ls \"\$LEAK_RELEASE.gave-up\" 2>/dev/null"
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/leaky" LEAK_RELEASE="$REG_TMP/release")" "$(printf 'answered\nrc=0')"
: > "$REG_TMP/release"
# agy stays on argv and refuses what one Linux argument cannot hold.
REG_CALL="${BIG}registry_run agy \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv 2>"$REG_TMP/agy.err")" 'rc=3'
assert_ok grep -q '300000 bytes; Linux refuses a single argument of 131072 bytes or more' "$REG_TMP/agy.err"
# The limit counts bytes (NUL included, so the limit itself is refused), and
# REGISTRY_ARGV_MAX_BYTES moves it.
REG_CALL='registry_run agy 0123456789abcdef; echo "rc=$?"'
assert_eq "$(count_argv REGISTRY_ARGV_MAX_BYTES=16 2>/dev/null)" 'rc=3'
REG_CALL='registry_run agy 0123456789abcde'
assert_eq "$(count_argv REGISTRY_ARGV_MAX_BYTES=16)" '[-p][0123456789abcde]'
# A template with no {prompt} never passes the prompt: size is no reason to refuse.
printf '%s\n' '{"models":{"bare":{"command":"x","env_command":"AGY_CLI","args":["--ping"]}}}' > "$REG_TMP/bare.json"
REG_CALL="${BIG}registry_run bare \"\$big\" </dev/null"
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/bare.json")" '[--ping]'
REG_CALL='registry_run agy "한글ab"; echo "rc=$?"'
assert_eq "$(count_argv REGISTRY_ARGV_MAX_BYTES=8 2>/dev/null)" 'rc=3'
assert_eq "$(count_argv REGISTRY_ARGV_MAX_BYTES=9)" "$(printf '[-p][한글ab]\nrc=0')"
# Configuration errors are refused before anything runs.
printf '%s\n' '{"models":{
  "leaky":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"stdin","args":["-p","{prompt}"]},
  "odd":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"file","args":["-p"]},
  "mine":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"stdin","args":["--print"]}}}' > "$REG_TMP/via.json"
REG_CALL='registry_run leaky P; echo "rc=$?"; registry_run odd P; echo "rc=$?"; registry_run mine P'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/via.json" 2>/dev/null)" "$(printf 'rc=3\nrc=3\n[--print] stdin=2')"
rm -rf "$REG_TMP"

# namespace.sh is vendored the same way registry.sh is.
for plugin in debate-conductor ralph-trio spec-trio; do
  cmp "$ROOT/dev-trio/lib/namespace.sh" "$ROOT/$plugin/lib/namespace.sh"
  PASS=$((PASS + 1))
done

printf 'hardening smoke: %d assertions passed\n' "$PASS"
