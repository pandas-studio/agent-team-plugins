#!/usr/bin/env bash
# namespace.sh ids, and ralph-trio's commit_worktree_changes on a locked index.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# herdr_team TAB_ID — the team resolved inside a herdr tab, on stdout; what the
# call wrote to stderr is left in $TMP/herdr.err.
herdr_team() {
  AGENT_TEAM='' TMUX='' HERDR_ENV=1 HERDR_TAB_ID="$1" agent_team_detect_team 2>"$TMP/herdr.err"
}
# tmux_team WINDOW_NAME SESSION_NAME — the team resolved inside tmux, with a
# herdr tab around it, from a tmux that answers with exactly these two names.
mkdir "$TMP/tmux-stub"
cat > "$TMP/tmux-stub/tmux" <<'STUB'
#!/bin/sh
case "$1" in
  show-options) printf '%s\n' "$STUB_TMUX_WINDOW" ;;
  display-message) printf '%s\n' "$STUB_TMUX_SESSION" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/tmux-stub/tmux"
tmux_team() {
  PATH="$TMP/tmux-stub:$PATH" STUB_TMUX_WINDOW="$1" STUB_TMUX_SESSION="$2" \
    AGENT_TEAM='' TMUX="$TMP/stub-socket,1,0" TMUX_PANE='%0' HERDR_ENV=1 HERDR_TAB_ID=w6:t2 \
    agent_team_detect_team 2>/dev/null
}
ID42=$(printf 'w%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42)
ID60="$ID42$(printf 'w%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18)"

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
  assert_eq "$(AGENT_TEAM='' TMUX='' HERDR_ENV='' agent_team_detect_team)" "default"

  # herdr: the tab id from the environment names the team, and a well-formed
  # id is not worth a warning.
  assert_eq "$(herdr_team w6:t2)" "herdr-w6-t2"
  assert_eq "$(wc -l < "$TMP/herdr.err" | tr -d ' ')" "0"
  assert_eq "$(herdr_team a:b:c)" "herdr-a-b-c"
  assert_eq "$(herdr_team w1)" "herdr-w1"
  # 48 characters is the limit of a team name: "herdr-" plus 42 fits, 43 does not.
  assert_eq "$(herdr_team "$ID42")" "herdr-$ID42"
  assert_eq "$(herdr_team "${ID42}x")" "default"
  # ":" becomes "-", so an id that already holds "-" or has an empty field
  # could share a name with another tab; "a.b" and "a_b" cannot.
  assert_eq "$(herdr_team a.b)" "herdr-a.b"
  assert_eq "$(herdr_team a_b:c)" "herdr-a_b-c"
  # A refused id is refused whole, with one warning line whatever it contains,
  # never repaired into another tab's name.
  for bad in 'w6:' ':t2' 'w1::t1' 'a b' 'a-b' 'w1:t-2' '../x' "$ID60" "w1:t1
evil" "w1:t1
" "$(printf 'w\303\251:t1')"; do
    assert_eq "$(herdr_team "$bad")" "default"
    assert_eq "$(wc -l < "$TMP/herdr.err" | tr -d ' ')" "1"
    assert_eq "$(grep -c '^WARNING: herdr tab id ' "$TMP/herdr.err")" "1"
  done
  # Without the marker, or without an id, herdr says nothing about the team.
  assert_eq "$(AGENT_TEAM='' TMUX='' HERDR_ENV=1 HERDR_TAB_ID='' agent_team_detect_team 2>&1)" "default"
  assert_eq "$(AGENT_TEAM='' TMUX='' HERDR_ENV='' HERDR_TAB_ID=w6:t2 agent_team_detect_team 2>&1)" "default"
  assert_eq "$(AGENT_TEAM='' TMUX='' HERDR_ENV=true HERDR_TAB_ID=w6:t2 agent_team_detect_team 2>&1)" "default"
  # AGENT_TEAM still wins, "default" included: that is how a run started before
  # the herdr name existed keeps its directory.
  assert_eq "$(AGENT_TEAM=mine TMUX='' HERDR_ENV=1 HERDR_TAB_ID=w6:t2 agent_team_detect_team 2>&1)" "mine"
  assert_eq "$(AGENT_TEAM=default TMUX='' HERDR_ENV=1 HERDR_TAB_ID=w6:t2 agent_team_detect_team 2>&1)" "default"
  # The alphabet is the one every team name has, whatever the locale or the
  # shell's nocasematch says: U+212A KELVIN SIGN is not a "k".
  assert_eq "$(LC_ALL=en_US.UTF-8 herdr_team "$(printf 'w\303\251:t1')" 2>/dev/null)" "default"
  assert_eq "$(shopt -s nocasematch; LC_ALL=en_US.UTF-8 herdr_team "$(printf '\342\204\252:1')" 2>/dev/null)" "default"
  assert_eq "$(shopt -s nocasematch; herdr_team W6:T2)" "herdr-W6-T2"
  assert_eq "$(LC_ALL=en_US.UTF-8 herdr_team w6:t2 2>/dev/null)" "herdr-w6-t2"
  # Every ASCII letter and digit is accepted, in any locale: none is lost to a
  # collation order that puts it outside a range.
  assert_eq "$(LC_ALL=en_US.UTF-8 herdr_team abcdefghijklmnopqrstuvwxyz0123456789 2>&1)" "herdr-abcdefghijklmnopqrstuvwxyz0123456789"
  assert_eq "$(LC_ALL=en_US.UTF-8 herdr_team ABCDEFGHIJKLMNOPQRSTUVWXYZ 2>&1)" "herdr-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  # Inside tmux the tmux branch decides alone, as before: the window's
  # @team-name, else the session name, else "default" when tmux names nothing.
  # The herdr tab around it is never consulted.
  assert_eq "$(tmux_team wteam sess)" "wteam"
  assert_eq "$(tmux_team '' sess)" "sess"
  assert_eq "$(tmux_team '' '')" "default"
done

# The completion marker counts only on a line of its own. The driver writes
# untrusted task text into fix_plan.md (`Task: %s`), and a worker note can quote
# the marker; neither may end the loop. Both copies of common.sh must agree.
for plugin in ralph-trio spec-trio; do
  PLUGIN_ROOT="$ROOT/$plugin"
  # shellcheck source=/dev/null
  . "$ROOT/$plugin/lib/common.sh"
  fp="$TMP/promise-$plugin.md"
  printf '## iter 1\nTask: document <promise>COMPLETE</promise> handling\n' > "$fp"
  assert_fail check_promise "$fp"
  printf 'I did not add `<promise>COMPLETE</promise>` yet.\n' > "$fp"
  assert_fail check_promise "$fp"
  printf '%s\n' '- <promise>COMPLETE</promise>' > "$fp"
  assert_fail check_promise "$fp"
  printf '  <promise>COMPLETE</promise>\n' > "$fp"
  assert_ok check_promise "$fp"
  printf '## iter 2\n<promise>COMPLETE</promise>\n' > "$fp"
  assert_ok check_promise "$fp"
  printf 'notes\n<promise>COMPLETE</promise>  \r\n' > "$fp"
  assert_ok check_promise "$fp"
  assert_fail check_promise "$TMP/missing-$plugin.md"
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
