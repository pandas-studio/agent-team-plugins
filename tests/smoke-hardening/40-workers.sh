#!/usr/bin/env bash
# Worker answers: wrappers, registry_run_answer, debate.sh and /continue, researcher log names.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A worker CLI that exits 0 without an answer has not succeeded: agy's print
# mode can soft-deny a tool and emit only stderr; a native-capture adapter can
# omit its final-answer file. Both paths must fail (rc=5), preserve real answers
# and CLI exit codes, and leave the debate round incomplete.
make_worker_cli_stubs
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

smoke_done 40-workers
