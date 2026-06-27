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
#
# Model pair:
#   --primary-gen=MODEL   generator model — flag > DEBATE_GENERATOR_MODEL >
#                         DEBATE_PRIMARY_GEN (legacy) > config role > default (agy)
#   --primary-crit=MODEL  critic model    — flag > DEBATE_CRITIC_MODEL > config role
#                         > "the other one" (codex unless gen=codex, then agy)
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
ROUNDS="$DEFAULT_ROUNDS"
TOPIC=""
CONTEXT_FILE=""
ROTATE=0
PRIMARY_GEN_OPT=""
PRIMARY_CRIT_OPT=""
CONTINUE_FROM=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REGISTRY_LIB="$SCRIPT_DIR/../lib/registry.sh"
[ -f "$_REGISTRY_LIB" ] || { echo "debate: registry.sh not found at $_REGISTRY_LIB" >&2; exit 1; }
# shellcheck source=../lib/registry.sh
. "$_REGISTRY_LIB" || { echo "debate: failed to load registry.sh (jq missing?)" >&2; exit 2; }
unset _REGISTRY_LIB

usage() {
  cat <<EOF
Usage: $(basename "$0") [-n ROUNDS] [--rotate] \\
         [--primary-gen=MODEL] [--primary-crit=MODEL] \\
         [--continue-from=DIR] \\
         "topic" [context-file.md]

Run an N-round Generator vs Critic debate. Defaults to 3 rounds with no rotation
(generator=agy, critic=codex). MODEL is any registered model id — run
'agent-team-models list' to see them. With --rotate, models alternate roles
every two rounds. With --continue-from=<debate-TS dir>, append N more rounds to
an existing debate (round numbering continues from last+1).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) ROUNDS="$2"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
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
case "$ROUNDS" in
  ''|*[!0-9]*) echo "ROUNDS must be a positive integer (got: $ROUNDS)" >&2; exit 2 ;;
esac
[ "$ROUNDS" -lt 1 ] && { echo "ROUNDS must be >= 1" >&2; exit 2; }

# Generator model: flag > DEBATE_GENERATOR_MODEL > DEBATE_PRIMARY_GEN (legacy)
#                  > config role binding > built-in default (agy).
if [ -n "$PRIMARY_GEN_OPT" ]; then
  PRIMARY_GEN="$PRIMARY_GEN_OPT"
elif [ -n "${DEBATE_GENERATOR_MODEL:-}" ]; then
  PRIMARY_GEN="$DEBATE_GENERATOR_MODEL"
elif [ -n "${DEBATE_PRIMARY_GEN:-}" ]; then
  PRIMARY_GEN="$DEBATE_PRIMARY_GEN"
else
  PRIMARY_GEN="$(registry_resolve_role debate-conductor generator "")"
fi
registry_model_exists "$PRIMARY_GEN" || { echo "primary-gen: unknown model '$PRIMARY_GEN' (run: agent-team-models list)" >&2; exit 2; }

# Critic model: flag > DEBATE_CRITIC_MODEL > config role binding > legacy
# "the other one" default (codex unless gen=codex, then agy). The auto-derive
# keeps `--primary-gen=codex` working with no critic flag, exactly as before.
if [ -n "$PRIMARY_CRIT_OPT" ]; then
  PRIMARY_CRIT="$PRIMARY_CRIT_OPT"
elif [ -n "${DEBATE_CRITIC_MODEL:-}" ]; then
  PRIMARY_CRIT="$DEBATE_CRITIC_MODEL"
elif [ -n "$(registry_config_role debate-conductor.critic)" ]; then
  PRIMARY_CRIT="$(registry_config_role debate-conductor.critic)"
elif [ "$PRIMARY_GEN" = "codex" ]; then
  PRIMARY_CRIT="agy"
else
  PRIMARY_CRIT="codex"
fi
registry_model_exists "$PRIMARY_CRIT" || { echo "primary-crit: unknown model '$PRIMARY_CRIT' (run: agent-team-models list)" >&2; exit 2; }
[ "$PRIMARY_GEN" = "$PRIMARY_CRIT" ] && { echo "primary-gen and primary-crit must differ (both = $PRIMARY_GEN)" >&2; exit 2; }

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

# Team detection (matches wrappers — for log isolation per tmux window)
detect_team() {
  if [ -n "${AGENT_TEAM:-}" ]; then echo "$AGENT_TEAM"; return; fi
  if [ -n "${TMUX:-}" ]; then
    local n
    n=$(tmux show-options -wqv -t "${TMUX_PANE:-}" '@team-name' 2>/dev/null) || n=""
    [ -n "$n" ] && { echo "$n"; return; }
    n=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null) || n=""
    [ -n "$n" ] && { echo "$n"; return; }
  fi
  echo default
}

if [ -n "$CONTEXT_FILE" ]; then
  [ -f "$CONTEXT_FILE" ] || { echo "context file not found: $CONTEXT_FILE" >&2; exit 2; }
fi

TEAM=$(detect_team)
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
  # Re-affirm latest-debate symlink (idempotent — same dir, no retarget).
  ln -sfn "debate-$TS" "$LOG_DIR/latest-debate"
else
  TS=$(date +%Y%m%d-%H%M%S)
  DEBATE_DIR="$LOG_DIR/debate-$TS"
  mkdir -p "$DEBATE_DIR"
  ln -sfn "debate-$TS" "$LOG_DIR/latest-debate"
  START_ROUND=1
  END_ROUND="$ROUNDS"
fi

# Persist topic for /continue. Don't overwrite on resume — original wins.
[ ! -f "$DEBATE_DIR/topic.txt" ] && printf '%s\n' "$TOPIC" > "$DEBATE_DIR/topic.txt"

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
  fi
done

printf '\n────────────────────────────────────────────────────\n'
printf '  Done — transcript:  %s\n' "$DEBATE_DIR"
printf '────────────────────────────────────────────────────\n'
