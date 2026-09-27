#!/usr/bin/env bash
# namespace.sh ids, and ralph-trio's commit_worktree_changes on a locked index.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

init_fixture_repo
# with_worktree creates worktrees under /tmp, outside $TMP.
LOCKWT=""
register_cleanup '[ -z "$LOCKWT" ] || rm -rf "$LOCKWT"'

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

smoke_done 10-namespace-common
