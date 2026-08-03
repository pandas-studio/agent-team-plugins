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

cmp "$ROOT/dev-trio/lib/registry.sh" "$ROOT/debate-conductor/lib/registry.sh"
PASS=$((PASS + 1))

# namespace.sh is vendored the same way registry.sh is.
for plugin in debate-conductor ralph-trio spec-trio; do
  cmp "$ROOT/dev-trio/lib/namespace.sh" "$ROOT/$plugin/lib/namespace.sh"
  PASS=$((PASS + 1))
done

printf 'hardening smoke: %d assertions passed\n' "$PASS"
