#!/usr/bin/env bash
# ask-reviewer.sh --no-memories and the models that shadow built-ins.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

init_fixture_repo

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

smoke_done 20-dev-reviewer
