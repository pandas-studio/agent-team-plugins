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
#   - $LOG_DIR/latest-debate → symlink to most recent debate dir
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
# shellcheck source=../lib/host.sh
. "$SCRIPT_DIR/../lib/host.sh"

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
pair/rotation unless this invocation explicitly overrides them.

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

TEAM=$(agent_team_detect_team) || exit 2
LOG_BASE="${DEBATE_LOG_DIR:-$PWD/.debate-conductor/log}"
LOG_DIR="$LOG_BASE/$TEAM"

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
  # LAST_ROUND counts only *completed* rounds — those with a hidden sidecar
  # `.round-N-...done` file written by `write_round_end` after the wrapper
  # exits 0. Pre-touched files and crashed-mid-round files have no sidecar,
  # so /continue resumes from the failed round, not after it.
  #
  # The `|| true` wrap is required because `set -euo pipefail` is on and
  # `ls` returns non-zero when the glob matches nothing — without it, an
  # empty result aborts the script before our custom error message fires.
  LAST_ROUND=$( { ls "$DEBATE_DIR"/.round-*.done 2>/dev/null || true; } \
    | sed -E 's@.*/\.round-([0-9]+)-.*@\1@' \
    | sort -n | tail -1)
  [ -z "$LAST_ROUND" ] && { echo "no completed round in $DEBATE_DIR — start a fresh debate with /run instead of /continue" >&2; exit 2; }
  START_ROUND=$((LAST_ROUND + 1))
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

mkdir -p "$DEBATE_DIR"
ln -sfn "debate-$TS" "$LOG_DIR/latest-debate"

# Persist topic for /continue. Don't overwrite on resume — original wins.
[ ! -f "$DEBATE_DIR/topic.txt" ] && printf '%s\n' "$TOPIC" > "$DEBATE_DIR/topic.txt"
write_model_metadata

CONTEXT_BLOCK=""
[ -n "$CONTEXT_FILE" ] && CONTEXT_BLOCK="$(cat "$CONTEXT_FILE")"

# Pre-create empty round files so tail-role.sh's `tail -F` can follow them
# from the start. Without this, BSD/GNU tail glob expands once at invocation
# time and won't auto-add new files matching the pattern, so rounds 2+ would
# silently bypass the live-tail panes.
for _r in $(seq "$START_ROUND" "$END_ROUND"); do
  if [ $((_r % 2)) -eq 1 ]; then
    : > "$(round_file "$_r" gen "$(round_model "$_r" gen)")"
  else
    : > "$(round_file "$_r" crit "$(round_model "$_r" crit)")"
  fi
done

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

# Machine-readable round marker emitted as the first line of each round file.
# tail-role.sh's awk parses these to render banners — independent of tail's
# per-file `==> path <==` headers (which are absent when only one file is
# being tailed) and immune to startup ghost banners on pre-touched empty files.
print_marker() {
  printf '<!-- debate-round: %s %s %s -->\n' "$1" "$2" "$3"
}

# Completion sentinel: a hidden sidecar `.round-N-role[-model].done` written
# alongside the .md transcript after a round's wrapper exits 0. Sidecar (vs
# in-transcript marker) so the transcript itself still ends on the canonical
# `Verdict: ...` / draft body line — preserving SKILL.md's "bottom of the
# last critic round" parsing path and the critic role contract that the
# final output line is the verdict. /continue's LAST_ROUND scans these
# sidecars; crash/CLI-failure rounds leave the .md but no .done, so resume
# happens *from* that round, not after it.
write_round_end() {
  local out_file="$2"
  local base="${out_file##*/}"
  local dir="${out_file%/*}"
  touch "$dir/.${base%.md}.done"
}

# Convergence parser (--until-converged). Echoes the Critic's verdict token by
# anchoring on the *standalone canonical line* `Verdict: TOKEN` (the critic role
# contract — see roles/critic.md) and taking the LAST match. Anchoring + tail -1
# is deliberate, mirroring tail-role.sh and the dev-trio reviewer parser: an
# errored Critic round echoes the role prompt, which contains the placeholders
# `Verdict: <STRENGTHEN | ...>` and `<one of: STRENGTHEN / ...>`. Neither matches
# `^Verdict: (TOKEN)$`, so a failed round yields no token and is treated as
# not-converged — the safe default that keeps the debate going on garbage rather
# than stopping on it. Output already passed through strip_cli_banner.
critic_verdict() {
  grep -hE '^Verdict: (STRENGTHEN|RECONSIDER|OVERTURN)[[:space:]]*$' "$1" 2>/dev/null \
    | tail -1 | awk '{print $2}'
}

# Drop CLI metadata noise so the transcript shows only model output.
# Handles both legacy codex banner (workdir:/model:/...) and current codex
# format which echoes the input prompt between `user`/`codex` markers and
# tails with `tokens used\n<count>`.
#
# stdbuf -oL forces line-buffered output so each cleaned line streams to the
# downstream `tee` (and viewers) immediately rather than waiting for sed's
# default full-buffer to fill on a long response.
LINEBUF=""
command -v stdbuf >/dev/null 2>&1 && LINEBUF='stdbuf -oL'
strip_cli_banner() {
  # Range start uses `Reading additional input from stdin` (a strong codex
  # preamble marker that is virtually never in body text) instead of the bare
  # `^user$` line — the bare-marker version was deleting transcript content
  # whenever a model legitimately wrote a `user` line followed later by a
  # `codex` line. Same robustness reasoning for the trailer range start.
  $LINEBUF sed -E \
    -e '/^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+\]/d' \
    -e '/^(OpenAI Codex|workdir:|model:|provider:|sandbox:|reasoning( (effort|summaries))?:|approval:|tokens used:)/d' \
    -e '/^session id:/d' \
    -e '/^--------+$/d' \
    -e '/^Reading additional input from stdin/,/^codex$/d' \
    -e '/^tokens used$/,$d'
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

# Always forward the resolved per-round model to the role dispatcher; ask-*.sh
# validate it against the registry. (Previously --model was elided for the
# built-in default, which only held while the defaults were literally agy/codex.)
gen_args()  { printf -- "--model %s" "$1"; }
crit_args() { printf -- "--model %s" "$1"; }

for r in $(seq "$START_ROUND" "$END_ROUND"); do
  if [ $((r % 2)) -eq 1 ]; then
    GEN_MODEL=$(round_model "$r" gen)
    OUT=$(round_file "$r" gen "$GEN_MODEL")
    [ "$ROTATE" = "1" ] && print_header "$r" "Generator" "$GEN_MODEL" || print_header "$r" "Generator"
    # shellcheck disable=SC2046  # word-splitting on gen_args output is intentional
    if [ "$r" -eq 1 ]; then
      if [ -n "$CONTEXT_BLOCK" ]; then
        {
          print_marker "$r" gen "$GEN_MODEL"
          echo "$CONTEXT_BLOCK" | "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Produce an initial substantive draft."
        } | strip_cli_banner | $LINEBUF tee "$OUT"
      else
        {
          print_marker "$r" gen "$GEN_MODEL"
          "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Produce an initial substantive draft."
        } | strip_cli_banner | $LINEBUF tee "$OUT"
      fi
    else
      PREV_GEN_MODEL=$(round_model "$((r-2))" gen)
      PREV_CRIT_MODEL=$(round_model "$((r-1))" crit)
      PREV_GEN=$(round_file "$((r-2))" gen "$PREV_GEN_MODEL")
      PREV_CRIT=$(round_file "$((r-1))" crit "$PREV_CRIT_MODEL")
      {
        print_marker "$r" gen "$GEN_MODEL"
        {
          echo "## Your previous draft (round $((r-2)))"
          cat "$PREV_GEN"
          echo
          echo "## Critic's feedback (round $((r-1)))"
          cat "$PREV_CRIT"
        } | "$SCRIPT_DIR/../lib/ask-generator.sh" $(gen_args "$GEN_MODEL") "Topic: $TOPIC. Revise your draft, addressing the critic's Blocker and Major findings directly. Quote the critic's claim, then state your response (accept / reject with reason / modify)."
      } | strip_cli_banner | $LINEBUF tee "$OUT"
    fi
    write_round_end "$r" "$OUT"
  else
    CRIT_MODEL=$(round_model "$r" crit)
    OUT=$(round_file "$r" crit "$CRIT_MODEL")
    PREV_GEN_MODEL=$(round_model "$((r-1))" gen)
    PREV_GEN=$(round_file "$((r-1))" gen "$PREV_GEN_MODEL")
    [ "$ROTATE" = "1" ] && print_header "$r" "Critic" "$CRIT_MODEL" || print_header "$r" "Critic"
    # shellcheck disable=SC2046
    {
      print_marker "$r" crit "$CRIT_MODEL"
      "$SCRIPT_DIR/../lib/ask-critic.sh" $(crit_args "$CRIT_MODEL") --with-research "$PREV_GEN" "Topic: $TOPIC. Critique the latest Generator draft adversarially. Focus on weaknesses, missed cases, and better alternatives."
    } | strip_cli_banner | $LINEBUF tee "$OUT"
    write_round_end "$r" "$OUT"
    # Convergence check runs only on Critic (even) rounds: a STRENGTHEN verdict
    # means the position is sound, so stop before spending another gen/crit pair.
    if [ "$UNTIL_CONVERGED" = "1" ] && [ "$(critic_verdict "$OUT")" = "STRENGTHEN" ]; then
      CONVERGED="$r"
      break
    fi
  fi
done

# Converge-mode epilogue. The pre-touched-but-unused round files past the
# convergence point have no `.done` sidecar (so /continue already ignores them),
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

printf '\n────────────────────────────────────────────────────\n'
printf '  Done — transcript:  %s\n' "$DEBATE_DIR"
printf '────────────────────────────────────────────────────\n'
