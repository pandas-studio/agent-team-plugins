#!/usr/bin/env bash
# debate.sh — orchestrate N-round adversarial debate (Generator vs Critic).
#
# Round pattern: odd = Generator, even = Critic. Default 3 rounds:
#   Round 1: Generator produces initial draft
#   Round 2: Critic attacks it
#   Round 3: Generator revises, addressing the critique
#
# Usage:
#   debate.sh "topic"                          # 3 rounds (gen → crit → gen)
#   debate.sh -n 5 "topic"                     # 5 rounds
#   debate.sh "topic" context.md               # extra context file → round 1 gen
#   debate.sh --primary-gen=claude "topic"     # claude as generator
#   debate.sh --rotate "topic"                 # role rotation ON
#   debate.sh --until-converged "topic"        # stop early when Critic verdict = STRENGTHEN
#
# Convergence (--until-converged):
#   Instead of running a fixed round count, keep alternating gen/crit and stop
#   as soon as a Critic round emits the canonical `Verdict: STRENGTHEN` line.
#   -n becomes the *upper bound* (hard cap); without -n the cap defaults to 6
#   (an even cap so a non-converging debate still ends on a Critic verdict).
#   Convergence is only evaluated on Critic (even) rounds.
#
# Model pair:
#   --primary-gen=MODEL   generator model — flag > DEBATE_GENERATOR_MODEL >
#                         DEBATE_PRIMARY_GEN (legacy) >
#                         continued debate metadata > config role > host default
#   --primary-crit=MODEL  critic model    — flag > DEBATE_CRITIC_MODEL >
#                         continued debate metadata > config role > host default
#   MODEL is any registered model id (built-ins agy|codex|claude, plus anything
#   added via `agent-team-models`; run `agent-team-models list`). Gen ≠ crit.
#
# Rotation (--rotate):
#   Round 1 gen=A, Round 2 crit=B, Round 3 gen=B, Round 4 crit=A, then repeats.
#   When rotation is on, transcript filenames carry a model suffix:
#       round-3-gen-codex.md  (vs round-3-gen.md without rotation)
#
# Output:
#   - stdout: full transcript with round markers
#   - $LOG_DIR/debate-<TS>/round-<N>-{gen,crit}[-MODEL].md per round
#   - $LOG_DIR/debate-<TS>/stream-{gen,crit}.log: append-only live stream per
#     role, followed by tail-role.sh. Each attempt starts with a header line and
#     ends with an end record carrying its exit status, both beginning with
#     \x1e (never present in model output, which is filtered).
#   - $LOG_DIR/latest-debate → symlink to most recent debate dir
#   - $LOG_DIR/latest-debate.json — committed sequence and physical directory snapshot
#   A fresh debate directory is allocated atomically, so two debates started in
#   the same second get `debate-<TS>` and `debate-<TS>-1`. While a run is
#   writing a debate it holds `debate-<TS>/.lock`; a second run on the same
#   debate is refused (exit 2).
#
# Log location: $DEBATE_LOG_DIR (default: $PWD/.debate-conductor/log) / $TEAM /
set -euo pipefail

DEFAULT_ROUNDS=3
# Converge-mode cap when -n is not given. Even so a non-converging debate ends
# on a Critic round (final verdict present) rather than a dangling Generator one.
CONVERGE_DEFAULT_ROUNDS=6
ROUNDS="$DEFAULT_ROUNDS"
ROUNDS_SET=0
TOPIC=""
CONTEXT_FILE=""
ROTATE=0
ROTATE_SET=0
UNTIL_CONVERGED=0
CONVERGED=""
PRIMARY_GEN_OPT=""
PRIMARY_CRIT_OPT=""
CONTINUE_FROM=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NAMESPACE_LIB="$SCRIPT_DIR/../lib/namespace.sh"
[ -f "$_NAMESPACE_LIB" ] || { echo "debate: namespace.sh not found at $_NAMESPACE_LIB" >&2; exit 1; }
# shellcheck source=../lib/namespace.sh
. "$_NAMESPACE_LIB"
unset _NAMESPACE_LIB
_REGISTRY_LIB="$SCRIPT_DIR/../lib/registry.sh"
[ -f "$_REGISTRY_LIB" ] || { echo "debate: registry.sh not found at $_REGISTRY_LIB" >&2; exit 1; }
# shellcheck source=../lib/registry.sh
. "$_REGISTRY_LIB" || { echo "debate: failed to load registry.sh (jq missing?)" >&2; exit 2; }
unset _REGISTRY_LIB
_INDEX_LIB="$SCRIPT_DIR/../lib/index.sh"
[ -f "$_INDEX_LIB" ] || { echo "debate: index.sh not found at $_INDEX_LIB" >&2; exit 1; }
# shellcheck source=../lib/index.sh
. "$_INDEX_LIB"
unset _INDEX_LIB
_RESULT_LIB="$SCRIPT_DIR/../lib/debate-result.sh"
[ -f "$_RESULT_LIB" ] || { echo "debate: debate-result.sh not found at $_RESULT_LIB" >&2; exit 1; }
# shellcheck source=../lib/debate-result.sh
. "$_RESULT_LIB"
unset _RESULT_LIB
# shellcheck source=../lib/host.sh
. "$SCRIPT_DIR/../lib/host.sh"
# shellcheck source=../lib/selection.sh
. "$SCRIPT_DIR/../lib/selection.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-n ROUNDS] [--rotate] [--until-converged] \\
         [--primary-gen=MODEL] [--primary-crit=MODEL] \\
         [--continue-from=DIR] \\
         "topic" [context-file.md]

Run an N-round Generator vs Critic debate. Defaults to 3 rounds with no rotation.
Claude PM defaults to generator=agy, critic=codex; Codex PM defaults to
generator=agy, critic=claude. MODEL is any registered model id — run
'agent-team-models list' to see them. With --rotate, models alternate roles
every two rounds. With --continue-from=<debate-TS dir>, append N more rounds to
an existing debate (round numbering continues from last+1) and reuse its model
pair/rotation unless this invocation explicitly overrides them. A debate whose
first round never completed resumes at round 1, reusing the context file saved
with it; a context-file argument replaces that saved context.

With --until-converged (-c), stop as soon as a Critic round emits the canonical
\`Verdict: STRENGTHEN\` line; -n is then the upper bound (default cap 6).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) ROUNDS="$2"; ROUNDS_SET=1; shift 2 ;;
    --rotate) ROTATE=1; ROTATE_SET=1; shift ;;
    --until-converged|-c) UNTIL_CONVERGED=1; shift ;;
    --primary-gen=*) PRIMARY_GEN_OPT="${1#--primary-gen=}"; shift ;;
    --primary-gen) PRIMARY_GEN_OPT="${2:?--primary-gen requires a model id}"; shift 2 ;;
    --primary-crit=*) PRIMARY_CRIT_OPT="${1#--primary-crit=}"; shift ;;
    --primary-crit) PRIMARY_CRIT_OPT="${2:?--primary-crit requires a model id}"; shift 2 ;;
    --continue-from=*) CONTINUE_FROM="${1#--continue-from=}"; shift ;;
    --continue-from) CONTINUE_FROM="${2:?--continue-from requires a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$TOPIC" ]; then TOPIC="$1"; shift
      elif [ -z "$CONTEXT_FILE" ]; then CONTEXT_FILE="$1"; shift
      else echo "extra arg: $1" >&2; exit 2; fi
      ;;
  esac
done

[ -z "$TOPIC" ] && { usage >&2; exit 2; }
PM_HOST="$(debate_conductor_host)" || exit $?
case "$ROUNDS" in
  ''|*[!0-9]*) echo "ROUNDS must be a positive integer (got: $ROUNDS)" >&2; exit 2 ;;
esac
[ "$ROUNDS" -lt 1 ] && { echo "ROUNDS must be >= 1" >&2; exit 2; }

# In converge mode without an explicit -n, raise the cap from the 3-round
# default to an even cap so the loop has several Critic checkpoints and ends
# on a Critic verdict if it never converges.
if [ "$UNTIL_CONVERGED" = "1" ] && [ "$ROUNDS_SET" = "0" ]; then
  ROUNDS="$CONVERGE_DEFAULT_ROUNDS"
fi

# Per-round model dispatch.
round_model() {
  local r="$1" role="$2"
  if [ "$ROTATE" != "1" ]; then
    [ "$role" = "gen" ] && echo "$PRIMARY_GEN" || echo "$PRIMARY_CRIT"
    return
  fi
  case "$role:$((r % 4))" in
    gen:1)  echo "$PRIMARY_GEN" ;;
    gen:3)  echo "$PRIMARY_CRIT" ;;
    crit:2) echo "$PRIMARY_CRIT" ;;
    crit:0) echo "$PRIMARY_GEN" ;;
    *) echo "round_model: bad combination r=$r role=$role" >&2; exit 1 ;;
  esac
}

round_file() {
  local r="$1" role="$2" model="$3"
  if [ "$ROTATE" = "1" ]; then
    echo "$DEBATE_DIR/round-$r-$role-$model.md"
  else
    echo "$DEBATE_DIR/round-$r-$role.md"
  fi
}

if [ -n "$CONTEXT_FILE" ]; then
  [ -f "$CONTEXT_FILE" ] || { echo "context file not found: $CONTEXT_FILE" >&2; exit 2; }
fi

# A caller that needs to know what *this* invocation produced passes an
# absolute, fresh receipt path; see lib/debate-result.sh for why reading the
# `latest-debate` symlink instead is a race. Validated here, before this run
# creates anything.
DEBATE_RECEIPT="${DEBATE_RECEIPT:-}"
case "$DEBATE_RECEIPT" in
  ""|/*) ;;
  *) echo "debate: DEBATE_RECEIPT must be absolute (got: $DEBATE_RECEIPT)" >&2; exit 2 ;;
esac

TEAM=$(agent_team_detect_team) || exit 2
LOG_BASE="${DEBATE_LOG_DIR:-$PWD/.debate-conductor/log}"
LOG_DIR="$LOG_BASE/$TEAM"

# ── One writer per debate ───────────────────────────────────────────────────
# Everything under a debate directory (round files, the attempt ledger, role
# streams, models.json) has exactly one writer. Without that, two
# `--continue-from` runs read the same completed rounds, pick the same next
# round, truncate the same round files and interleave appends into the streams.
#
# The lock is a *symlink*, `.lock`, whose target is the owner line. `ln -s`
# creates the lock and publishes its owner in one atomic step, which is what
# makes this safe against a signal: there is no moment where the lock exists
# but nobody can be shown to hold it, and release_lock decides purely from
# what `readlink` returns — no bookkeeping flag a signal could arrive between.
# (`flock` is not available on bash 3.2, the macOS /bin/bash.) Nothing ever
# follows the link; it is read, not opened.
#
# There is deliberately no automatic stale recovery. A dead owner pid is not
# evidence that the writing stopped: a SIGKILL aimed at debate.sh alone leaves
# its backgrounded attempt pipeline writing the round file and the stream. And
# no sleep-and-recheck election between contenders is exclusive — two of them
# can each elect themselves, and the one that wakes second then deletes a lock
# the other is already holding. INT, TERM and HUP release the lock through the
# traps below, so clearing one that outlived its run is the user's call, and
# the refusal says how.
LOCK_PATH=""    # where this run's lock would be; removal is gated on the owner
LOCK_OWNER=""   # the exact owner line this run publishes, unique to this run

# release_lock: drop the lock if it is still ours. It reads the owner back from
# the link, so it is idempotent, safe to re-enter from a nested signal, and
# never removes a lock some other run holds.
release_lock() {
  [ -n "$LOCK_PATH" ] || return 0
  [ "$(readlink "$LOCK_PATH" 2>/dev/null || true)" = "$LOCK_OWNER" ] || return 0
  rm -f "$LOCK_PATH" 2>/dev/null || true
}

# lock_refuse DIR LOCK: report the holder of an existing lock and exit 2.
lock_refuse() {
  local owner
  owner="$(readlink "$2" 2>/dev/null || true)"
  case "$owner" in
    host=*pid=*)
      echo "debate: $1 is locked by another debate.sh run ($owner)" >&2 ;;
    *)
      echo "debate: $1 holds a lock with no readable owner — another debate.sh run may be writing it" >&2 ;;
  esac
  # Same condition as the README: a dead debate.sh is not enough, because the
  # model CLI, the filter and the tees it started can outlive it and keep
  # writing. %q so the command is safe to paste for a path with spaces.
  printf 'debate: wait for that run to finish. If it is gone, confirm that it and every process it started have stopped writing here, then: rm -rf -- %q\n' \
    "$2" >&2
  exit 2
}

# acquire_lock DIR: take the exclusive writer lock on debate dir DIR, or refuse
# with rc=2 — for a live holder, and for any lock this run cannot identify.
acquire_lock() {
  local dir="$1" lock="$1/.lock" host
  host="${HOSTNAME:-}"
  [ -n "$host" ] || host="$(uname -n 2>/dev/null || echo unknown)"
  # pid + start second + a random token: a stranded lock from a former run can
  # never read back as this one's, whatever pid the kernel reuses.
  LOCK_OWNER="host=$host pid=$$ started=$(date +%Y-%m-%dT%H:%M:%S) run=$RANDOM$RANDOM"
  # Set before the link exists: release_lock still removes nothing until the
  # link is ours, and a signal landing inside `ln -s` leaves nothing behind.
  LOCK_PATH="$lock"
  # Checked before the link is made because `ln -s TARGET DIR` puts the link
  # *inside* DIR: a lock left behind as a directory would otherwise be walked
  # straight past. Not a race with another debate.sh — this script only ever
  # creates the lock as a symlink, and `ln -s` onto an existing symlink fails.
  if [ -L "$lock" ] || [ -e "$lock" ]; then
    lock_refuse "$dir" "$lock"
  fi
  if ! ln -s "$LOCK_OWNER" "$lock" 2>/dev/null; then
    # Lost the race to another run, or nothing is in the way and the parent is
    # unwritable or missing — say which.
    if [ -L "$lock" ] || [ -e "$lock" ]; then
      lock_refuse "$dir" "$lock"
    fi
    echo "debate: cannot create the writer lock $lock" >&2
    exit 1
  fi
}

# Early traps, replaced further down once attempt recording exists. A fatal
# signal that is not trapped kills the shell without running the EXIT trap, so
# INT/TERM/HUP are trapped from here on: release, then die from the same signal
# so a bash caller still sees an interrupted child.
release_and_die() {
  release_lock
  trap - "$1" EXIT
  kill -s "$1" "$$"
}
trap 'release_lock' EXIT
trap 'release_and_die INT' INT
trap 'release_and_die TERM' TERM
trap 'release_and_die HUP' HUP

# allocate_debate_dir: create a fresh debate directory, atomically. `mkdir`
# without -p on the leaf fails when the name is taken, which is what makes the
# allocation exclusive: two debates started in the same second used to share
# `debate-<TS>/` (and `latest-debate` did not visibly retarget, so viewers
# could not tell a new debate had started). The loser takes `debate-<TS>-1`,
# and so on. The suffix is part of TS from here on, so the `latest-debate`
# symlink and the `--continue-from` TS parse keep working unchanged.
allocate_debate_dir() {
  local n=0 cand
  mkdir -p "$LOG_DIR"
  while :; do
    if [ "$n" -eq 0 ]; then cand="debate-$TS"; else cand="debate-$TS-$n"; fi
    if mkdir "$LOG_DIR/$cand" 2>/dev/null; then
      TS="${cand#debate-}"
      DEBATE_DIR="$LOG_DIR/$cand"
      return 0
    fi
    [ -d "$LOG_DIR/$cand" ] || { echo "debate: cannot create $LOG_DIR/$cand" >&2; exit 1; }
    n=$((n + 1))
    [ "$n" -lt 100 ] || { echo "debate: too many debates started in the same second under $LOG_DIR" >&2; exit 1; }
  done
}

if [ -n "$CONTINUE_FROM" ]; then
  # Append more rounds to an existing debate dir. Caller may pass either an
  # absolute path or a `latest-debate` symlink — resolve to the real dir so
  # writes land on the canonical `debate-<TS>/`. The dir's parent (not the
  # current $LOG_DIR derived from $PWD/$TEAM) is the correct place to host
  # the `latest-debate` symlink — otherwise continuing a debate from a
  # different team or absolute path lands the symlink in the wrong dir.
  [ -d "$CONTINUE_FROM" ] || { echo "continue-from dir not found: $CONTINUE_FROM" >&2; exit 2; }
  DEBATE_DIR=$(cd "$CONTINUE_FROM" && pwd -P)
  case "${DEBATE_DIR##*/}" in
    debate-*) TS="${DEBATE_DIR##*/debate-}" ;;
    *) echo "continue-from must point at a debate-<TS> dir (got: $DEBATE_DIR)" >&2; exit 2 ;;
  esac
  LOG_DIR="${DEBATE_DIR%/*}"
  # Take the writer lock before reading any completion state: the round this
  # run picks, and every file it then writes, must be decided under it.
  acquire_lock "$DEBATE_DIR"
  # Refuse sidecar-only and mixed legacy histories before the pre-touch loop
  # can overwrite their completed transcripts. The lock is released on refusal.
  debate_index_can_continue "$DEBATE_DIR" || exit 2
  # Only successful ledger ends advance the resume point. Empty/start-only
  # ledgers can retry round 1 when the saved topic shows the debate started.
  LAST_ROUND="$(last_completed_round "$DEBATE_DIR")"
  if [ -z "$LAST_ROUND" ]; then
    [ -f "$DEBATE_DIR/topic.txt" ] || { echo "no completed round in $DEBATE_DIR — start a fresh debate with /run instead of /continue" >&2; exit 2; }
    echo "debate: no completed round in $DEBATE_DIR; resuming from round 1" >&2
    LAST_ROUND=0
  fi
  # context.md is either absent or a regular file this script wrote. Anything
  # else (a directory, a symlink) would be skipped on reuse or swallow the copy
  # on save, so refuse before this run touches latest-debate or models.json.
  if [ -L "$DEBATE_DIR/context.md" ] || { [ -e "$DEBATE_DIR/context.md" ] && [ ! -f "$DEBATE_DIR/context.md" ]; }; then
    echo "debate: $DEBATE_DIR/context.md is not a regular file; remove it or start a fresh debate" >&2
    exit 2
  fi
  START_ROUND=$((LAST_ROUND + 1))
  debate_index_can_resume_at "$DEBATE_DIR" "$START_ROUND" || exit 2
  END_ROUND=$((LAST_ROUND + ROUNDS))
else
  TS=$(date +%Y%m%d-%H%M%S)
  DEBATE_DIR="$LOG_DIR/debate-$TS"
  START_ROUND=1
  END_ROUND="$ROUNDS"
fi

# Continue must keep the original model pair unless this invocation explicitly
# selects a replacement through flags or per-role env vars. Global config still
# applies to fresh debates, but it should not silently rewrite an existing
# transcript when the PM host changes.
role_has_invocation_model() {
  local role="$1" cli="$2"
  [ -n "$cli" ] && return 0
  case "$role" in
    generator)
      [ -n "${DEBATE_GENERATOR_MODEL:-}" ] && return 0
      [ -n "${DEBATE_PRIMARY_GEN:-}" ] && return 0
      ;;
    critic)
      [ -n "${DEBATE_CRITIC_MODEL:-}" ] && return 0
      ;;
    *) echo "debate: unknown role '$role'" >&2; exit 2 ;;
  esac
  return 1
}

infer_marker_model() {
  local role="$1" file base rest file_round file_model first marker_body marker_round marker_role marker_model marker_extra
  local candidate_model best_round="" best_model=""
  for file in "$DEBATE_DIR"/round-*-"$role".md "$DEBATE_DIR"/round-*-"$role"-*.md; do
    [ -e "$file" ] || continue
    base="${file##*/}"
    rest="${base#round-}"
    file_round="${rest%%-*}"
    case "$file_round" in
      ""|*[!0-9]*) continue ;;
    esac
    file_model=""
    case "$base" in
      round-*-"$role"-*.md)
        file_model="${base#"round-$file_round-$role-"}"
        file_model="${file_model%.md}"
        ;;
    esac
    candidate_model=""
    IFS= read -r first < "$file" || first=""
    case "$first" in
      "<!-- debate-round: "*)
        marker_body="${first#<!-- debate-round: }"
        case "$marker_body" in
          *" -->") marker_body="${marker_body% -->}" ;;
          *) marker_body="" ;;
        esac
        IFS=' ' read -r marker_round marker_role marker_model marker_extra <<< "$marker_body"
        if [ "$marker_round" = "$file_round" ] && [ "$marker_role" = "$role" ] && [ -n "$marker_model" ] && [ -z "$marker_extra" ]; then
          candidate_model="$marker_model"
        fi
        ;;
    esac
    [ -z "$candidate_model" ] && candidate_model="$file_model"
    if [ -n "$candidate_model" ] && { [ -z "$best_round" ] || [ "$file_round" -lt "$best_round" ]; }; then
      best_round="$file_round"
      best_model="$candidate_model"
    fi
  done
  [ -n "$best_model" ] && printf '%s\n' "$best_model"
  return 0
}

infer_rotation_from_files() {
  local file base rest file_round
  for file in "$DEBATE_DIR"/round-*-gen-*.md "$DEBATE_DIR"/round-*-crit-*.md; do
    [ -e "$file" ] || continue
    base="${file##*/}"
    rest="${base#round-}"
    file_round="${rest%%-*}"
    case "$file_round" in
      ""|*[!0-9]*) continue ;;
    esac
    printf 'true\n'
    return
  done
  return 0
}

metadata_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  jq -r --arg key "$key" '
    if $key == "rotate" then
      if (.[$key] | type) == "boolean" then (.[$key] | tostring) else "" end
    elif (.[$key] | type) == "string" then
      .[$key]
    else
      ""
    end
  ' "$file" 2>/dev/null || true
}

metadata_source_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  jq -r --arg key "$key" '
    if (.sources[$key] | type) == "string" then .sources[$key] else "" end
  ' "$file" 2>/dev/null || true
}

write_model_metadata() {
  local tmp
  tmp="$DEBATE_DIR/.models.json.$$"
  jq -n \
    --arg pm_host "$PM_HOST" \
    --arg generator "$PRIMARY_GEN" \
    --arg critic "$PRIMARY_CRIT" \
    --arg generator_source "$PRIMARY_GEN_SOURCE" \
    --arg critic_source "$PRIMARY_CRIT_SOURCE" \
    --arg rotate_source "$ROTATE_SOURCE" \
    --argjson rotate "$ROTATE" \
    '{version: 1, pm_host: $pm_host, generator: $generator, critic: $critic, rotate: ($rotate == 1),
      sources: {generator: $generator_source, critic: $critic_source, rotate: $rotate_source}}' \
    > "$tmp"
  mv "$tmp" "$DEBATE_DIR/models.json"
}

PERSISTED_GEN=""
PERSISTED_CRIT=""
PERSISTED_ROTATE=""
PERSISTED_GEN_SOURCE=""
PERSISTED_CRIT_SOURCE=""
PERSISTED_ROTATE_SOURCE=""
if [ -n "$CONTINUE_FROM" ] && [ -f "$DEBATE_DIR/models.json" ]; then
  PERSISTED_GEN="$(metadata_value "$DEBATE_DIR/models.json" generator)"
  PERSISTED_CRIT="$(metadata_value "$DEBATE_DIR/models.json" critic)"
  PERSISTED_ROTATE="$(metadata_value "$DEBATE_DIR/models.json" rotate)"
  if [ -n "$PERSISTED_GEN" ]; then
    PERSISTED_GEN_SOURCE="$(metadata_source_value "$DEBATE_DIR/models.json" generator)"
    [ -n "$PERSISTED_GEN_SOURCE" ] || PERSISTED_GEN_SOURCE="metadata"
  fi
  if [ -n "$PERSISTED_CRIT" ]; then
    PERSISTED_CRIT_SOURCE="$(metadata_source_value "$DEBATE_DIR/models.json" critic)"
    [ -n "$PERSISTED_CRIT_SOURCE" ] || PERSISTED_CRIT_SOURCE="metadata"
  fi
  if [ -n "$PERSISTED_ROTATE" ]; then
    PERSISTED_ROTATE_SOURCE="$(metadata_source_value "$DEBATE_DIR/models.json" rotate)"
    [ -n "$PERSISTED_ROTATE_SOURCE" ] || PERSISTED_ROTATE_SOURCE="metadata"
  fi
  case "$PERSISTED_ROTATE" in
    true|false|"") ;;
    *) PERSISTED_ROTATE=""; PERSISTED_ROTATE_SOURCE="" ;;
  esac
fi
if [ -n "$CONTINUE_FROM" ] && { [ -z "$PERSISTED_GEN" ] || [ -z "$PERSISTED_CRIT" ]; }; then
  if [ -z "$PERSISTED_GEN" ]; then
    PERSISTED_GEN="$(infer_marker_model gen)"
    [ -n "$PERSISTED_GEN" ] && PERSISTED_GEN_SOURCE="rounds"
  fi
  if [ -z "$PERSISTED_CRIT" ]; then
    PERSISTED_CRIT="$(infer_marker_model crit)"
    [ -n "$PERSISTED_CRIT" ] && PERSISTED_CRIT_SOURCE="rounds"
  fi
  if [ -n "$PERSISTED_GEN" ] && [ -n "$PERSISTED_CRIT" ]; then
    echo "debate: no complete models.json; inferred continue models from round markers" >&2
  elif [ -n "$PERSISTED_GEN$PERSISTED_CRIT" ]; then
    echo "debate: no complete models.json; partial continue models available (generator=${PERSISTED_GEN:-default}, critic=${PERSISTED_CRIT:-default}); unresolved roles use current model defaults" >&2
  else
    echo "debate: no models.json or readable round markers; using current model defaults" >&2
  fi
fi
if [ -n "$CONTINUE_FROM" ] && [ -z "$PERSISTED_ROTATE" ]; then
  PERSISTED_ROTATE="$(infer_rotation_from_files)"
  [ -n "$PERSISTED_ROTATE" ] && PERSISTED_ROTATE_SOURCE="round-files"
fi
if [ -n "$CONTINUE_FROM" ] && [ "$ROTATE_SET" = "1" ] && [ "$PERSISTED_ROTATE" != "true" ]; then
  echo "debate: --rotate cannot be added while continuing a non-rotated debate; start a fresh debate instead" >&2
  exit 2
fi
if [ "$ROTATE_SET" = "0" ] && [ "$PERSISTED_ROTATE" = "true" ]; then
  ROTATE=1
fi
if [ "$ROTATE_SET" = "1" ]; then
  ROTATE_SOURCE="invocation"
elif [ -n "$PERSISTED_ROTATE_SOURCE" ]; then
  ROTATE_SOURCE="$PERSISTED_ROTATE_SOURCE"
else
  ROTATE_SOURCE="current-resolution"
fi

# Generator model: flag > DEBATE_GENERATOR_MODEL > DEBATE_PRIMARY_GEN (legacy)
#                  > persisted continue metadata > config role binding
#                  > host default.
GEN_INVOCATION_MODEL=0
if role_has_invocation_model generator "$PRIMARY_GEN_OPT"; then GEN_INVOCATION_MODEL=1; fi
if [ "$GEN_INVOCATION_MODEL" = "0" ] && [ -n "$PERSISTED_GEN" ]; then
  PRIMARY_GEN="$PERSISTED_GEN"
  PRIMARY_GEN_SOURCE="$PERSISTED_GEN_SOURCE"
else
  PRIMARY_GEN="$(debate_conductor_resolve_role generator "$PRIMARY_GEN_OPT")"
  [ "$GEN_INVOCATION_MODEL" = "1" ] && PRIMARY_GEN_SOURCE="invocation" || PRIMARY_GEN_SOURCE="current-resolution"
fi
registry_model_exists "$PRIMARY_GEN" || { echo "primary-gen: unknown model '$PRIMARY_GEN' (run: agent-team-models list)" >&2; exit 2; }

# Critic model: flag > DEBATE_CRITIC_MODEL > persisted continue metadata
#               > config role binding > host default.
# Claude host preserves the legacy "other one" default. Codex host defaults to
# Claude so Codex does not call itself as an external Critic unless configured.
CRIT_INVOCATION_MODEL=0
if role_has_invocation_model critic "$PRIMARY_CRIT_OPT"; then CRIT_INVOCATION_MODEL=1; fi
if [ "$CRIT_INVOCATION_MODEL" = "0" ] && [ -n "$PERSISTED_CRIT" ]; then
  PRIMARY_CRIT="$PERSISTED_CRIT"
  PRIMARY_CRIT_SOURCE="$PERSISTED_CRIT_SOURCE"
else
  PRIMARY_CRIT="$(debate_conductor_resolve_role critic "$PRIMARY_CRIT_OPT" "$PRIMARY_GEN")"
  [ "$CRIT_INVOCATION_MODEL" = "1" ] && PRIMARY_CRIT_SOURCE="invocation" || PRIMARY_CRIT_SOURCE="current-resolution"
fi
registry_model_exists "$PRIMARY_CRIT" || { echo "primary-crit: unknown model '$PRIMARY_CRIT' (run: agent-team-models list)" >&2; exit 2; }
[ "$PRIMARY_GEN" = "$PRIMARY_CRIT" ] && { echo "primary-gen and primary-crit must differ (both = $PRIMARY_GEN)" >&2; exit 2; }
if [ -n "$CONTINUE_FROM" ] && [ "$ROTATE" = "1" ] \
   && { { [ -n "$PERSISTED_GEN" ] && [ "$PRIMARY_GEN" != "$PERSISTED_GEN" ]; } \
        || { [ -n "$PERSISTED_CRIT" ] && [ "$PRIMARY_CRIT" != "$PERSISTED_CRIT" ]; }; }; then
  echo "debate: cannot change model pair while continuing a rotated debate; start a fresh debate instead" >&2
  exit 2
fi

# Refuse missing CLIs or Codex-host Claude login before creating/retargeting the
# transcript directory, so a failed preflight cannot steal latest-debate. Limit
# the probe to role/model pairs that will actually run in START_ROUND..END_ROUND.
scheduled_uses() {
  local role="$1" model="$2" r
  for r in $(seq "$START_ROUND" "$END_ROUND"); do
    if [ $((r % 2)) -eq 1 ]; then
      [ "$role" = "gen" ] && [ "$(round_model "$r" gen)" = "$model" ] && return 0
    else
      [ "$role" = "crit" ] && [ "$(round_model "$r" crit)" = "$model" ] && return 0
    fi
  done
  return 1
}

if scheduled_uses gen "$PRIMARY_GEN"; then
  REGISTRY_CMD_OVERRIDE="${GENERATOR_CLI:-}" debate_conductor_check_cli "$PRIMARY_GEN" || exit $?
fi
if scheduled_uses crit "$PRIMARY_CRIT"; then
  REGISTRY_CMD_OVERRIDE="${CRITIC_CLI:-}" debate_conductor_check_cli "$PRIMARY_CRIT" || exit $?
fi
if [ "$ROTATE" = "1" ]; then
  if scheduled_uses gen "$PRIMARY_CRIT"; then
    REGISTRY_CMD_OVERRIDE="${GENERATOR_CLI:-}" debate_conductor_check_cli "$PRIMARY_CRIT" || exit $?
  fi
  if scheduled_uses crit "$PRIMARY_GEN"; then
    REGISTRY_CMD_OVERRIDE="${CRITIC_CLI:-}" debate_conductor_check_cli "$PRIMARY_GEN" || exit $?
  fi
fi

if [ -n "$CONTINUE_FROM" ]; then
  mkdir -p "$DEBATE_DIR"
else
  # Allocated (and locked) only once the preflight above passed, so a failed
  # preflight leaves no debate directory behind.
  allocate_debate_dir
  acquire_lock "$DEBATE_DIR"
  # Create the ledger before any attempt can fail. A fresh run interrupted
  # before its first start record can then be distinguished from a legacy run.
  : > "$DEBATE_DIR/index.jsonl" || { echo "debate: cannot create the attempt ledger" >&2; exit 1; }
fi
# Per-role live streams for tail-role.sh: append-only, never truncated or
# replaced, so `tail -F` on one file sees every attempt, retries included.
# Created before latest-debate moves so a viewer switching to this debate finds
# them. An indexed debate missing its streams gets new ones on continuation;
# its earlier rounds stay in the round files only.
for _role in gen crit; do : >> "$DEBATE_DIR/stream-$_role.log"; done
selection_rc=0
debate_selection_publish "$LOG_DIR" "$DEBATE_DIR" || selection_rc=$?
if [ "$selection_rc" != 0 ]; then
  # Remove only our new, unselected allocation. A committed selection or a
  # failed rollback can still point at it; retain that directory for recovery.
  if [ -z "$CONTINUE_FROM" ] && [ "$(readlink "$LOG_DIR/latest-debate" 2>/dev/null || true)" != "${DEBATE_DIR##*/}" ]; then
    for _file in stream-gen.log stream-crit.log index.jsonl; do
      [ -s "$DEBATE_DIR/$_file" ] || rm -f "$DEBATE_DIR/$_file"
    done
    release_lock
    rmdir "$DEBATE_DIR" || echo "debate: retained nonempty allocation: $DEBATE_DIR" >&2
  fi
  exit "$selection_rc"
fi

# Persist topic for /continue. Don't overwrite on resume — original wins.
[ ! -f "$DEBATE_DIR/topic.txt" ] && printf '%s\n' "$TOPIC" > "$DEBATE_DIR/topic.txt"
write_model_metadata

# Round-1 context. Saved beside topic.txt so a resumed round 1 gets the same
# input; a context file passed to this invocation replaces the saved one. Only
# round 1 reads it, so later-round continues leave it untouched.
CONTEXT_BLOCK=""
if [ "$START_ROUND" -eq 1 ]; then
  if [ -n "$CONTEXT_FILE" ]; then
    CONTEXT_BLOCK="$(cat "$CONTEXT_FILE")"
    CONTEXT_TMP="$(umask 077 && mktemp "$DEBATE_DIR/.context.md.XXXXXX")" \
      && cat "$CONTEXT_FILE" > "$CONTEXT_TMP" \
      && mv -f "$CONTEXT_TMP" "$DEBATE_DIR/context.md" \
      || { rm -f "${CONTEXT_TMP:-}"; echo "debate: could not save context to $DEBATE_DIR/context.md" >&2; exit 1; }
  elif [ -n "$CONTINUE_FROM" ] && [ -f "$DEBATE_DIR/context.md" ]; then
    CONTEXT_BLOCK="$(cat "$DEBATE_DIR/context.md")"
  fi
fi

# Pre-create empty round files for the scheduled range. Live panes do not
# follow round files (they follow stream-<role>.log); the placeholders mark
# which rounds this run owns, and the converge-mode epilogue and the resume
# cleanup below remove the ones never written.
#
# A resumed round's file may still hold the failed attempt; it is replaced with
# a new file rather than truncated in place. This dates from when panes tailed
# round files (GNU `tail -F` drops bytes on an in-place truncate that is
# rewritten past its old offset) and remains harmless for any external
# follower of round files.
for _r in $(seq "$START_ROUND" "$END_ROUND"); do
  if [ $((_r % 2)) -eq 1 ]; then
    _f="$(round_file "$_r" gen "$(round_model "$_r" gen)")"
  else
    _f="$(round_file "$_r" crit "$(round_model "$_r" crit)")"
  fi
  rm -f "$_f"
  : > "$_f"
done

# A resume shorter than the original run leaves that run's placeholders past
# END_ROUND behind: empty, no successful ledger end, never written. Remove
# these unused placeholders; keep any file with content or a successful end.
if [ -n "$CONTINUE_FROM" ]; then
  for _f in "$DEBATE_DIR"/round-*.md; do
    [ -e "$_f" ] || continue
    _base="${_f##*/}"
    case "$_base" in
      round-*-gen.md|round-*-gen-*.md|round-*-crit.md|round-*-crit-*.md) ;;
      *) continue ;;
    esac
    _n="${_base#round-}"
    _n="${_n%%-*}"
    case "$_n" in ""|*[!0-9]*) continue ;; esac
    [ "$_n" -gt "$END_ROUND" ] || continue
    [ -s "$_f" ] && continue
    round_is_complete "$DEBATE_DIR" "$_n" && continue
    rm -f "$_f"
  done
fi

print_header() {
  local round="$1" who="$2" model="${3:-}"
  printf '\n────────────────────────────────────────────────────\n'
  if [ -n "$model" ]; then
    printf '  Round %s · %s · %s\n' "$round" "$who" "$model"
  else
    printf '  Round %s · %s\n' "$round" "$who"
  fi
  printf '────────────────────────────────────────────────────\n\n'
}

# Machine-readable round marker emitted as the first line of each round file
# (and stdout). infer_marker_model reads it back on continue. Live panes do not
# draw banners from it: the copy that reaches the stream is dropped, and banners
# come only from the \x1e headers written by stream_header.
print_marker() {
  printf '<!-- debate-round: %s %s %s -->\n' "$1" "$2" "$3"
}

# Convergence parser (--until-converged). Echoes the Critic's verdict token by
# anchoring on the *standalone canonical line* `Verdict: TOKEN` (the critic role
# contract — see roles/critic.md) and taking the LAST match. Anchoring + tail -1
# is deliberate, mirroring tail-role.sh and the dev-trio reviewer parser: an
# errored Critic round echoes the role prompt, which contains the placeholders
# `Verdict: <STRENGTHEN | ...>` and `<one of: STRENGTHEN / ...>`. Neither matches
# `^Verdict: (TOKEN)$`, so a failed round yields no token and is treated as
# not-converged — the safe default that keeps the debate going on garbage rather
# than stopping on it. Output already passed through strip_stream_controls.
critic_verdict() {
  grep -hE '^Verdict: (STRENGTHEN|RECONSIDER|OVERTURN)[[:space:]]*$' "$1" 2>/dev/null \
    | tail -1 | awk '{print $2}'
}

# Role wrappers publish answers, not CLI console transcripts. Preserve answer
# text verbatim except for the reserved stream framing byte. Keep the filter
# unbuffered so stdout-only adapters still stream answers as they arrive.
SED_STREAM=(sed)
if printf 'x\n' | sed -u -e 's/x/y/' >/dev/null 2>&1; then
  SED_STREAM=(sed -u)
elif command -v stdbuf >/dev/null 2>&1; then
  SED_STREAM=(stdbuf -oL sed)
fi
# \x1e (ASCII record separator) marks stream headers written by this script.
# It is deleted from model output below, so model text cannot forge a header.
RS_BYTE="$(printf '\036')"
strip_stream_controls() {
  "${SED_STREAM[@]}" -e "s/$RS_BYTE//g"
}

if [ -n "$CONTINUE_FROM" ]; then
  echo "Debate continued — topic: $TOPIC"
  echo "Adding rounds $START_ROUND..$END_ROUND  ·  Team: $TEAM"
else
  echo "Debate started — topic: $TOPIC"
  echo "Rounds: $ROUNDS  ·  Team: $TEAM"
fi
if [ "$ROTATE" = "1" ]; then
  echo "Rotation: ON  ·  primary-gen=$PRIMARY_GEN  primary-crit=$PRIMARY_CRIT"
else
  echo "Rotation: OFF (gen=$PRIMARY_GEN, crit=$PRIMARY_CRIT)"
fi
[ "$PM_HOST" = "codex" ] && echo "PM host: Codex"
[ "$UNTIL_CONVERGED" = "1" ] && echo "Mode: until-converged (stop on 'Verdict: STRENGTHEN', cap round $END_ROUND)"
echo "Transcript dir: $DEBATE_DIR"

# stream_record ROLE TEXT: append one \x1e-framed record to that role's stream.
# An attempt may have ended mid-line, so a record always starts a line.
stream_record() {
  local stream="$DEBATE_DIR/stream-$1.log"
  if [ -s "$stream" ] && [ -n "$(tail -c 1 "$stream")" ]; then
    printf '\n' >> "$stream"
  fi
  printf '%s%s\n' "$RS_BYTE" "$2" >> "$stream"
}

# stream_header ROLE HEADER: publish an attempt's header in that role's stream.
stream_header() {
  stream_record "$1" "$2"
}

# An attempt's pipeline runs under errexit and pipefail in a background subshell
# that debate.sh waits for at once: a failing command anywhere in it (the model,
# or a `cat` building its prompt) makes `wait` fail with that status, and errexit
# stops debate.sh. The end record is therefore written by the EXIT trap from the
# exit status, never by capturing the pipeline's status (`pipeline || rc=$?`
# would turn off errexit inside it). The pipeline is not in the foreground
# because bash runs a trap only after a foreground pipeline ends, but at once
# during `wait`: a signal sent to debate.sh's PID alone must stop the model now,
# not when it finishes (#48). It stays in debate.sh's process group, so a signal
# to the group (Ctrl-C, a supervisor's killpg, SIGKILL too) still reaches every
# process of the attempt. CUR_ATTEMPT_* name the attempt in progress; empty
# means none.
CUR_ATTEMPT_ROUND=""
CUR_ATTEMPT_ROLE=""
CUR_ATTEMPT_ID=""
CUR_ATTEMPT_HEADER=""
CUR_ATTEMPT_PUBLISHED=""
# Basename of the round file this attempt writes — the ledger records it so a
# consumer never re-derives the round-N-role[-model].md naming rule, and so the
# rotation form is visible in the record.
CUR_ATTEMPT_FILE=""
# Set only once this attempt's `start` record reached index.jsonl, and cleared
# before CUR_ATTEMPT_ROLE arms the traps: it is what stops an end record being
# written for an attempt the ledger never opened.
CUR_ATTEMPT_INDEXED=""
# The status this attempt ends with, decided once by record_attempt_end. The two
# writers are independent and a signal can land between them, so the decision
# has to outlive the first write or a re-entry would give the ledger a different
# status than the stream already has (measured: stream rc=9, ledger rc=143).
CUR_ATTEMPT_RC=""
# Attempt ids are ATTEMPT_RUN.N: this run's PID and start time, then a counter,
# so a /continue appending to the same streams does not reuse them.
ATTEMPT_RUN="$$.$(date +%s)"
ATTEMPT_SEQ=0

# index_append LINE: append one record to the ledger. Borrows stream_record's
# rule that a record always starts a line — without it a torn line left by a
# crash glues onto the next record, and the fragment can swallow a whole start
# record. A failed append stops the normal path: without a successful end,
# the attempt is incomplete and must not be followed by another round.
index_append() {
  local idx last
  idx="$(debate_index_file "$DEBATE_DIR")"
  if [ -s "$idx" ]; then
    last="$(tail -c 1 "$idx")" || return 1
    if [ -n "$last" ]; then printf '\n' >> "$idx" || return 1; fi
  fi
  printf '%s\n' "$1" >> "$idx" || return 1
}

# index_start MODEL: open this attempt in the ledger.
index_start() {
  local line
  line="$(jq -nc \
    --arg id "$CUR_ATTEMPT_ID" --arg role "$CUR_ATTEMPT_ROLE" --arg model "$1" \
    --arg file "$CUR_ATTEMPT_FILE" --arg ts "$(date +%Y-%m-%dT%H:%M:%S)" \
    --argjson round "$CUR_ATTEMPT_ROUND" \
    '{v: 1, t: "start", id: $id, round: $round, role: $role, model: $model, file: $file, ts: $ts}')" \
    || return 1
  index_append "$line"
}

# index_end RC: close this attempt in the ledger, once. Deduped against the
# ledger's own last line, which — unlike the role stream's — is always one
# well-formed record carrying the attempt id. This does not replace the
# stream's dedupe: either write can fail on its own.
index_end() {
  local idx last line
  idx="$(debate_index_file "$DEBATE_DIR")"
  if [ -f "$idx" ] && last="$(tail -n 1 "$idx" 2>/dev/null)"; then
    case "$(printf '%s' "$last" | jq -r 'select(type == "object") | select(.t == "end") | .id' 2>/dev/null || true)" in
      "$CUR_ATTEMPT_ID") return 0 ;;
    esac
  fi
  line="$(jq -nc \
    --arg id "$CUR_ATTEMPT_ID" --arg role "$CUR_ATTEMPT_ROLE" \
    --arg file "$CUR_ATTEMPT_FILE" --arg ts "$(date +%Y-%m-%dT%H:%M:%S)" \
    --argjson round "$CUR_ATTEMPT_ROUND" --argjson rc "$1" \
    '{v: 1, t: "end", id: $id, round: $round, role: $role, file: $file, rc: $rc, ts: $ts}')" \
    || return 1
  index_append "$line"
}

# begin_attempt ROUND ROLE MODEL OUT
# Records are `R ROLE` then space-separated tokens; `id=` names the attempt, so
# a retry of the same round and model is still told apart (#53).
# The attempt is registered before its header is published, and
# CUR_ATTEMPT_ROLE is set last: it is what makes the traps record the attempt.
# A signal in between finds CUR_ATTEMPT_PUBLISHED empty, and record_attempt_end
# checks the stream for the header (#52).
begin_attempt() {
  ATTEMPT_SEQ=$((ATTEMPT_SEQ + 1))
  CUR_ATTEMPT_ROUND="$1"
  CUR_ATTEMPT_ID="$ATTEMPT_RUN.$ATTEMPT_SEQ"
  CUR_ATTEMPT_HEADER="<!-- debate-round: $1 $2 $3 id=$CUR_ATTEMPT_ID -->"
  CUR_ATTEMPT_FILE="${4##*/}"
  CUR_ATTEMPT_PUBLISHED=""
  CUR_ATTEMPT_INDEXED=""
  CUR_ATTEMPT_RC=""
  CUR_ATTEMPT_ROLE="$2"
  stream_header "$2" "$CUR_ATTEMPT_HEADER"
  CUR_ATTEMPT_PUBLISHED=1
  # After the header, not before: a ledger row names bytes in the stream, and
  # a row for an attempt whose frame never got there would be a dangling
  # reference. Set only on a successful append — the flag has to mean "the
  # start record is on disk", or an end record could stand alone. A signal
  # between the append and the flag leaves a start with no end, which is an
  # incomplete attempt: the round runs again.
  if index_start "$3"; then
    CUR_ATTEMPT_INDEXED=1
  else
    echo "debate: cannot record attempt start in $DEBATE_DIR/index.jsonl" >&2
    return 1
  fi
}

# complete_attempt: the pipeline succeeded. Freeze its status before either
# end writer can be interrupted. Only a successful ledger append makes this
# completion survive SIGKILL; a trapped signal reuses the frozen status.
complete_attempt() {
  CUR_ATTEMPT_RC=0
  record_attempt_end 0
}

# stream_attempt_end RC: best-effort diagnostic end, using the already selected
# status. A header not yet marked published is recognized by its exact id at
# the stream tail (#52); an existing end for this attempt is not duplicated.
# This helper owns no attempt state, so a failed stream read or write cannot
# affect ledger completion. Round transcripts keep their verdict as the last line.
stream_attempt_end() {
  local rc="$1" role="$CUR_ATTEMPT_ROLE" stream last prefix suffix code
  [ -n "$role" ] || return 0
  stream="$DEBATE_DIR/stream-$role.log"
  prefix="$RS_BYTE<!-- debate-round-end: $CUR_ATTEMPT_ROUND $role rc="
  suffix=" id=$CUR_ATTEMPT_ID -->"
  last=""
  if [ -e "$stream" ] && ! last="$(tail -n 1 "$stream")"; then
    return 0
  fi
  if [ -z "$CUR_ATTEMPT_PUBLISHED" ] && [ "$last" != "$RS_BYTE$CUR_ATTEMPT_HEADER" ]; then
    return 0
  fi
  case "$last" in
    "$prefix"*"$suffix")
      code="${last#"$prefix"}"
      code="${code%"$suffix"}"
      case "$code" in
        ""|*[!0-9]*) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  stream_record "$role" "<!-- debate-round-end: $CUR_ATTEMPT_ROUND $role rc=$rc id=$CUR_ATTEMPT_ID -->" || true
}

# record_attempt_end RC: select one status and close the attempt, ledger first.
# Signals can re-enter between the writes (#50); the frozen status outlives
# either writer so both records always agree. A ledger failure is returned to
# the normal path, but never stops the diagnostic write or trap cleanup.
record_attempt_end() {
  local rc="$1" write_rc=0
  [ -n "$CUR_ATTEMPT_ROLE" ] || return 0
  if [ -n "$CUR_ATTEMPT_RC" ]; then
    rc="$CUR_ATTEMPT_RC"
  else
    CUR_ATTEMPT_RC="$rc"
  fi
  if [ -n "$CUR_ATTEMPT_INDEXED" ]; then
    index_end "$rc" || write_rc=1
  fi
  stream_attempt_end "$rc" || true
  CUR_ATTEMPT_ROLE=""
  CUR_ATTEMPT_INDEXED=""
  CUR_ATTEMPT_RC=""
  if [ "$write_rc" -ne 0 ]; then
    echo "debate: cannot record attempt end in $DEBATE_DIR/index.jsonl" >&2
  fi
  return "$write_rc"
}
# Keep the incoming exit status even if recording fails; always release the lock.
trap 'record_attempt_end "$?" || true; release_lock' EXIT
# stop_attempt: terminate the running attempt and every process it started, as
# far as they can be found. Background commands start with SIGINT ignored, so
# they are always sent TERM. The attempt's processes are this shell's jobs that
# are still its children, plus their descendants; each is stopped (SIGSTOP) as
# it is found, so none forks or exits, and gets reparented out of reach, while
# the tree is collected. Best effort: a process that exited before it was found
# can leave children behind, and one that ignores TERM keeps running. Waits up
# to about 2 s for the collected processes to go — one budget, covering the
# attempt itself — and never longer: the caller's cleanup runs after it (#66).
# Needs ps (see below).
stop_attempt() {
  local roots jobs_out table new tree="" i=0 p pstat
  # Joined with parameter expansion for the reason given at attempt_running (#66).
  jobs_out=$(jobs -p)
  roots="${jobs_out//$'\n'/ }"
  [ -n "$roots" ] || return 0
  while [ "$i" -lt 50 ]; do
    if ! table="$(ps -A -o pid= -o ppid= -o stat= 2>/dev/null)"; then
      # Without ps nothing can be found: wait for the attempt to finish (the
      # behavior before #48) rather than leave it writing after debate.sh exits.
      # shellcheck disable=SC2086
      [ -n "$tree" ] || { wait $roots 2>/dev/null || true; return 0; }
      break
    fi
    new="$(printf '%s\n' "$table" | awk -v self="$$" -v roots="$roots" -v seen="$tree" '
      BEGIN { n = split(roots, r, " "); m = split(seen, s, " "); for (i = 1; i <= m; i++) had[s[i]] = 1 }
      { parent[$1] = $2; stat[$1] = $3; kids[$2] = kids[$2] " " $1 }
      END {
        q = 0
        for (i = 1; i <= n; i++) if (parent[r[i]] == self) queue[++q] = r[i]
        for (h = 1; h <= q; h++) {
          p = queue[h]
          if (stat[p] !~ /^Z/ && !(p in had)) printf "%s ", p
          c = split(kids[p], k, " ")
          for (j = 1; j <= c; j++) queue[++q] = k[j]
        }
      }')" || break
    [ -n "$new" ] || break
    # shellcheck disable=SC2086
    kill -s STOP $new 2>/dev/null || true
    tree="$tree $new"
    i=$((i + 1))
  done
  [ -n "$tree" ] || return 0
  # shellcheck disable=SC2086
  kill -s TERM $tree 2>/dev/null || true
  # shellcheck disable=SC2086
  kill -s CONT $tree 2>/dev/null || true
  # `wait $roots` stood here and was unbounded (#66). Every root has been sent
  # TERM above, but one that ignores it held this call open for as long as it
  # kept running, and on_signal's record_attempt_end and release_lock sit behind
  # it — so a root that outlives the signal also cost the ledger entry and the
  # lock. The loop below already covers the roots: `tree` is seeded from them, so
  # a root that is still alive keeps that poll going. One budget, not two.
  i=0
  # shellcheck disable=SC2086
  while [ "$i" -lt 20 ] && ps -o stat= -p "$(echo $tree | tr ' ' ',')" 2>/dev/null | grep -qv '^Z'; do
    sleep 0.1
    i=$((i + 1))
  done
  # Then reap only what ps confirms has exited. A root that is still alive is
  # left behind rather than waited on — that wait is the block being removed —
  # and one that is already gone has nothing to reap, so `Z` is the whole set.
  for p in $roots; do
    pstat="$(ps -o stat= -p "$p" 2>/dev/null)" || pstat=""
    case "$pstat" in
      Z*) wait "$p" 2>/dev/null || true ;;
    esac
  done
}

# ATTEMPT_WAIT_STEP: how long one step of wait_attempt sleeps. A fractional
# sleep is not POSIX, so it is probed once (macOS, GNU and busybox all take it).
ATTEMPT_WAIT_STEP=0.5
sleep 0.01 2>/dev/null || ATTEMPT_WAIT_STEP=1

# ATTEMPT_WAIT_POLL: whether wait_attempt steps instead of waiting once. The two
# defects here sit on opposite bash versions, and each mechanism cures one and
# causes the other (measured, one container / one machine per column):
#
#                          bash 3.2.57, 400 trials   bash 5.2.21, 3000 trials
#   plain `wait`           2 late (#57)              0 late, 0 rc=2
#   stepped poll           0 late                    0 late, 10 rc=2 (#66)
#
# #57 is a bash 3.2 `wait` that misses a trapped signal arriving as it starts;
# the poll is its workaround. #66 is the parse race the poll itself opens: every
# command substitution in the loop is re-parsed on each expansion, and a signal
# landing in that parse leaves bash unable to parse the trap string, so on_signal
# never runs. Flattening the substitutions took it from 0.32% to 0.10% (64 and 20
# in 20000) — narrower, not closed. So poll only where the poll is needed.
#
# 3.x and below, not "not 5": bash 4 is untested for #57, and the two failures
# are not equal. #57 costs latency; #66 skips stop_attempt, record_attempt_end
# and release_lock, leaving the #45 lock behind. The untested version gets the
# cheaper failure mode. Overridable so the tests can drive both paths.
if [ -z "${ATTEMPT_WAIT_POLL:-}" ]; then
  if [ "${BASH_VERSINFO[0]}" -le 3 ]; then ATTEMPT_WAIT_POLL=1; else ATTEMPT_WAIT_POLL=0; fi
fi

# attempt_running PID: is that job still running? `kill -0` is not used: once the
# attempt is reaped its PID can be reused by an unrelated process, and the wait
# below would then follow that one. Read like stop_attempt reads `jobs -p`.
#
# The PIDs are joined with parameter expansion, not `$(echo $(jobs -rp))` (#66).
# A signal delivered while bash is parsing a nested command substitution leaves
# it unable to parse the trap string: the trap does not run and bash exits 2
# with `trap: unexpected EOF while looking for matching `)'`. wait_attempt calls
# this in a loop precisely while a TERM can arrive, so the nesting sat in the
# one place that costs the most — on_signal, and with it stop_attempt,
# record_attempt_end and release_lock, was skipped. Measured on bash 5.2.21:
# 10/1000 trials exited 2 with the nesting, 0/500 without.
attempt_running() {
  local running
  running=$(jobs -rp)
  case " ${running//$'\n'/ } " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# wait_attempt PID: wait for the attempt pipeline and return its status.
# bash 3.2 (the macOS /bin/bash) can miss a trapped signal that arrives as `wait`
# starts, and then runs the trap only once the child exits — debate.sh outlived a
# TERM by the length of the whole attempt (#57). Waiting in short sleep steps
# keeps that delay to about one step: measured 0/3000 steps late against 5/400
# for a plain wait, not proved from bash internals. A stopped attempt is waited
# on as before. The final `wait` takes the attempt's status, so a failed attempt
# still stops debate.sh through errexit.
#
# Where that `wait` does not miss the signal the steps are pure cost and open
# #66 instead, so ATTEMPT_WAIT_POLL decides — see its comment above.
wait_attempt() {
  if [ "$ATTEMPT_WAIT_POLL" = 1 ]; then
    while attempt_running "$1"; do
      sleep "$ATTEMPT_WAIT_STEP" &
      wait "$!"
    done
  fi
  wait "$1"
}

# on_signal SIG STATUS: stop the running attempt, record it with the
# conventional status, then die from the same signal. Exiting normally instead would let a
# bash caller (e.g. ralph-debate.sh's loop) carry on after Ctrl-C, because
# bash only stops when its child was killed by SIGINT. Without these traps the
# EXIT trap would see status 0 after TERM or HUP (measured).
on_signal() {
  stop_attempt || true
  record_attempt_end "$2" || true
  release_lock
  trap - "$1" EXIT
  kill -s "$1" "$$"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP

# Always forward the resolved per-round model to the role dispatcher; ask-*.sh
# validate it against the registry. (Previously --model was elided for the
# built-in default, which only held while the defaults were literally agy/codex.)
gen_args()  { printf -- "--model %s" "$1"; }
crit_args() { printf -- "--model %s" "$1"; }

for r in $(seq "$START_ROUND" "$END_ROUND"); do
  if [ $((r % 2)) -eq 1 ]; then
    GEN_MODEL=$(round_model "$r" gen)
    OUT=$(round_file "$r" gen "$GEN_MODEL")
    begin_attempt "$r" gen "$GEN_MODEL" "$OUT"
    [ "$ROTATE" = "1" ] && print_header "$r" "Generator" "$GEN_MODEL" || print_header "$r" "Generator"
    # shellcheck disable=SC2046  # word-splitting on gen_args output is intentional
    if [ "$r" -eq 1 ]; then
      if [ -n "$CONTEXT_BLOCK" ]; then
        (
          {
            print_marker "$r" gen "$GEN_MODEL"
            echo "$CONTEXT_BLOCK" | "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Produce an initial substantive draft."
          } | strip_stream_controls | tee "$OUT" | tee -a "$DEBATE_DIR/stream-gen.log"
        ) <&0 &
      else
        (
          {
            print_marker "$r" gen "$GEN_MODEL"
            "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Produce an initial substantive draft."
          } | strip_stream_controls | tee "$OUT" | tee -a "$DEBATE_DIR/stream-gen.log"
        ) <&0 &
      fi
    else
      PREV_GEN_MODEL=$(round_model "$((r-2))" gen)
      PREV_CRIT_MODEL=$(round_model "$((r-1))" crit)
      PREV_GEN=$(round_file "$((r-2))" gen "$PREV_GEN_MODEL")
      PREV_CRIT=$(round_file "$((r-1))" crit "$PREV_CRIT_MODEL")
      (
        {
          print_marker "$r" gen "$GEN_MODEL"
          {
            echo "## Your previous draft (round $((r-2)))"
            cat "$PREV_GEN"
            echo
            echo "## Critic's feedback (round $((r-1)))"
            cat "$PREV_CRIT"
          } | "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Revise your draft, addressing the critic's Blocker and Major findings directly. Quote the critic's claim, then state your response (accept / reject with reason / modify)."
        } | strip_stream_controls | tee "$OUT" | tee -a "$DEBATE_DIR/stream-gen.log"
      ) <&0 &
    fi
    # Unconditional, so a failed attempt stops debate.sh through errexit.
    wait_attempt "$!"
    complete_attempt
  else
    CRIT_MODEL=$(round_model "$r" crit)
    OUT=$(round_file "$r" crit "$CRIT_MODEL")
    begin_attempt "$r" crit "$CRIT_MODEL" "$OUT"
    PREV_GEN_MODEL=$(round_model "$((r-1))" gen)
    PREV_GEN=$(round_file "$((r-1))" gen "$PREV_GEN_MODEL")
    [ "$ROTATE" = "1" ] && print_header "$r" "Critic" "$CRIT_MODEL" || print_header "$r" "Critic"
    # shellcheck disable=SC2046
    (
      {
        print_marker "$r" crit "$CRIT_MODEL"
        "$SCRIPT_DIR/../lib/ask-critic.sh" $(crit_args "$CRIT_MODEL") --with-research "$PREV_GEN" "Topic: $TOPIC. Critique the latest Generator draft adversarially. Focus on weaknesses, missed cases, and better alternatives."
      } | strip_stream_controls | tee "$OUT" | tee -a "$DEBATE_DIR/stream-crit.log"
    ) <&0 &
    wait_attempt "$!"
    complete_attempt
    # Convergence check runs only on Critic (even) rounds: a STRENGTHEN verdict
    # means the position is sound, so stop before spending another gen/crit pair.
    if [ "$UNTIL_CONVERGED" = "1" ] && [ "$(critic_verdict "$OUT")" = "STRENGTHEN" ]; then
      CONVERGED="$r"
      break
    fi
  fi
done

# Converge-mode epilogue. The pre-touched-but-unused round files past the
# convergence point have no successful ledger end (so /continue ignores them),
# but empty round-N.md files clutter the dir and the live panes — remove them.
if [ "$UNTIL_CONVERGED" = "1" ]; then
  if [ -n "$CONVERGED" ]; then
    if [ "$CONVERGED" -lt "$END_ROUND" ]; then
      for _r in $(seq $((CONVERGED + 1)) "$END_ROUND"); do
        if [ $((_r % 2)) -eq 1 ]; then
          _f="$(round_file "$_r" gen "$(round_model "$_r" gen)")"
        else
          _f="$(round_file "$_r" crit "$(round_model "$_r" crit)")"
        fi
        [ -e "$_f" ] && [ ! -s "$_f" ] && rm -f "$_f"
      done
    fi
    printf '\n✓ Converged at round %s — Critic verdict: STRENGTHEN.\n' "$CONVERGED"
  else
    printf '\n⚠ Reached round cap %s without a STRENGTHEN verdict — stopping.\n' "$END_ROUND"
  fi
fi

# The receipt, published while this run still holds the writer lock: a snapshot
# taken outside it could be advanced by a concurrent --continue-from between the
# read and the write. Success only — a failed round never reaches this line.
if [ -n "$DEBATE_RECEIPT" ]; then
  RECEIPT_DIR="$(cd "$DEBATE_DIR" && pwd -P)" || { echo "debate: cannot resolve $DEBATE_DIR" >&2; exit 1; }
  RECEIPT_LAST="$(last_completed_round "$DEBATE_DIR")"
  # Reaching this line means every scheduled round completed, so an empty
  # answer here is a broken read, not an empty debate.
  [ -n "$RECEIPT_LAST" ] || { echo "debate: no completed round to report in $DEBATE_DIR" >&2; exit 1; }
  RECEIPT_CRIT="$(last_completed_round_of_role "$DEBATE_DIR" crit)"
  RECEIPT_FILE=""
  if [ -n "$RECEIPT_CRIT" ]; then
    # A lookup that fails is an error, not "no critic round completed": the
    # receipt must not quietly claim nothing finished because a read broke.
    RECEIPT_FILE="$(completed_round_file "$DEBATE_DIR" "$RECEIPT_CRIT" crit)" || {
      echo "debate: cannot determine the transcript of completed critic round $RECEIPT_CRIT" >&2
      exit 1
    }
    [ -n "$RECEIPT_FILE" ] || { echo "debate: completed critic round $RECEIPT_CRIT has no transcript on record" >&2; exit 1; }
  fi
  debate_receipt_write "$DEBATE_RECEIPT" "$RECEIPT_DIR" "$RECEIPT_LAST" \
    "$RECEIPT_CRIT" "$RECEIPT_FILE" \
    || { echo "debate: could not publish the receipt $DEBATE_RECEIPT" >&2; exit 1; }
fi

printf '\n────────────────────────────────────────────────────\n'
printf '  Done — transcript:  %s\n' "$DEBATE_DIR"
printf '────────────────────────────────────────────────────\n'
