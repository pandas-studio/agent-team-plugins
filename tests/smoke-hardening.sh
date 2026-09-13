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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name Test
printf 'base\n' > "$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm init
printf 'changed\n' > "$TMP/repo/file.txt"
touch "$TMP/repo/.git/index.lock"

PLUGIN_ROOT="$ROOT/ralph-trio"
# shellcheck source=/dev/null
. "$PLUGIN_ROOT/lib/common.sh"
assert_fail commit_worktree_changes "$TMP/repo" 1
assert_ok test -d "$TMP/repo"
assert_ok test -n "$(git -C "$TMP/repo" status --porcelain)"

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
    -u DEV_TRIO_PM_HOST \
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

cmp "$ROOT/dev-trio/lib/registry.sh" "$ROOT/debate-conductor/lib/registry.sh"
PASS=$((PASS + 1))

# namespace.sh is vendored the same way registry.sh is.
for plugin in debate-conductor ralph-trio spec-trio; do
  cmp "$ROOT/dev-trio/lib/namespace.sh" "$ROOT/$plugin/lib/namespace.sh"
  PASS=$((PASS + 1))
done

printf 'hardening smoke: %d assertions passed\n' "$PASS"
