#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0

assert_ok() { "$@"; PASS=$((PASS + 1)); }
assert_fail() { if "$@" >/dev/null 2>&1; then return 1; fi; PASS=$((PASS + 1)); }

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: expected %q, got %q\n' "$2" "$1" >&2
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
trap '[ -n "$LOCKWT" ] && rm -rf "$LOCKWT"; rm -rf "$TMP"' EXIT
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

# ask-codex.sh --no-memories must reach codex as a config override, and must be
# refused for a model that has no equivalent switch (before anything is spawned).
STUB_CLI="$TMP/stub-cli"
cat > "$STUB_CLI" <<'STUB'
#!/usr/bin/env bash
# Record every argv slot except the trailing prompt, one per line.
printf '%s\n' "${@:1:$#-1}" > "$STUB_ARGV"
echo "VERDICT: SHIP"
STUB
chmod +x "$STUB_CLI"
run_ask_codex() {
  # Clear the previous run's artifacts so a run that spawns nothing cannot pass
  # on them (several cases expect the same argv).
  rm -f "$TMP/argv" "$TMP/log/smoke/latest-codex.final.md"
  (cd "$TMP/repo" && env -u REVIEWER_CLI -u DEV_TRIO_REVIEWER_MODEL \
    -u MANIFEST_PARENT_TMP -u REVIEWER_ROLE_FILE \
    CODEX_CLI="$STUB_CLI" CLAUDE_CLI="$STUB_CLI" STUB_ARGV="$TMP/argv" \
    AGENT_TEAM=smoke TMUX="" DEV_TRIO_LOG_DIR="$TMP/log" \
    AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" \
    "$@" "$ROOT/dev-trio/bin/ask-codex.sh" "${ASK_ARGS[@]}" >/dev/null 2>&1)
}
final_path() { printf '%s/log/smoke/%s' "$TMP" "$(readlink "$TMP/log/smoke/latest-codex.final.md")"; }
# Compare argv slot by slot (one per line) so a merged "-c features.memories=false"
# slot cannot pass for the two slots codex needs.
assert_argv() { assert_eq "$(cat "$TMP/argv")" "$(printf '%s\n' "$@" "$(final_path)")"; }
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

# ralph-meta without --base-ref: the empty range array must not kill git log
# under bash 3.2's set -u (it used to report 0 commits every time).
git -C "$DRV" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ralph iter 1: smoke"
git -C "$DRV" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated"
mkdir -p "$TMP/meta-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/meta-bin/ask-codex.sh"
chmod +x "$TMP/meta-bin/ask-codex.sh"
(cd "$DRV" && env PATH="$TMP/meta-bin:$PATH" AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw" \
  "$ROOT/ralph-trio/bin/ralph-meta.sh" --since "1 hour ago" >/dev/null 2>"$TMP/meta.err" </dev/null) || true
assert_eq "$(sed -n 's/.*ralph commits found: //p' "$TMP/meta.err")" "1"

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
    a="" b=""
    trap '\''for w in "$a" "$b"; do [ -n "$w" ] && git worktree remove --force "$w" 2>/dev/null; [ -n "$w" ] && rm -rf "$w"; done; true'\'' EXIT
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
    a="$c"
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
    b="$d"
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m iter
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "base moved"
    merge_or_discard_worktree "$d" 4 1 "$PWD" >/dev/null 2>&1 || { [ -d "$d" ] && echo ff-fail-kept; }
  ' _ "$WTREPO")" "$(printf '%s\n' distinct branches "bad-rc=1 out=" no-leftover discarded merged \
      missing-refused commit-refused validate-refused feature-untouched discard-refused feature-kept \
      ff-fail-kept)"
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

cmp "$ROOT/dev-trio/lib/registry.sh" "$ROOT/debate-conductor/lib/registry.sh"
PASS=$((PASS + 1))
cmp "$ROOT/dev-trio/bin/agent-team-models.sh" "$ROOT/debate-conductor/bin/agent-team-models.sh"
PASS=$((PASS + 1))

# namespace.sh is vendored the same way registry.sh is.
for plugin in debate-conductor ralph-trio spec-trio; do
  cmp "$ROOT/dev-trio/lib/namespace.sh" "$ROOT/$plugin/lib/namespace.sh"
  PASS=$((PASS + 1))
done

printf 'hardening smoke: %d assertions passed\n' "$PASS"
