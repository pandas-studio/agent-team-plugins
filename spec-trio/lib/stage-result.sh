#!/usr/bin/env bash
# Canonical copy: ralph-trio/lib/stage-result.sh. Vendored byte-for-byte in
# spec-trio so installed plugins need no additional cross-plugin dependency.
# stdout is evidence; the existing log is only a diagnostic transcript.
# Callers provide ORIGINAL_DIR and the STAGE_IGNORE_PATHS array. Helpers do not
# require pipefail: each pipeline status or sequential operation is checked.
STAGE_CLI_RC=''
STAGE_EVIDENCE=none
STAGE_STDOUT=''
# The next stage_run's prompt, for a CLI that reads it on stdin (`claude -p`).
# stage_run consumes and unsets it on entry, so it never reaches a later call.
unset STAGE_PROMPT

stage_path_absolute() {
  local path="$1" parent
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd) || {
    printf '%s\n' "$path"
    return 0
  }
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

# Ignore exact harness paths and their descendants, including the corresponding
# paths in a throwaway worktree. Callers supply STAGE_IGNORE_PATHS as an array.
stage_prepare_ignores() {
  local work_dir="$1" original="$2" path resolved link hops repo_root
  STAGE_RESOLVED_IGNORES=()
  original=$(cd -P "$original" && pwd) || return 6
  if repo_root=$(git -C "$original" rev-parse --show-toplevel 2>/dev/null); then original="$repo_root"; fi
  if repo_root=$(git -C "$work_dir" rev-parse --show-toplevel 2>/dev/null); then work_dir="$repo_root"; fi
  for path in "${STAGE_IGNORE_PATHS[@]}"; do
    [ -n "$path" ] || continue
    resolved=$(stage_path_absolute "$path") || return 6
    hops=0
    while :; do
      STAGE_RESOLVED_IGNORES+=("$resolved")
      case "$resolved" in
        "$original"/*) STAGE_RESOLVED_IGNORES+=("$work_dir/${resolved#"$original"/}") ;;
      esac
      [ -L "$resolved" ] || break
      hops=$((hops + 1))
      [ "$hops" -le 40 ] || return 6
      link=$(readlink "$resolved") || return 6
      case "$link" in /*) ;; *) link="$(dirname "$resolved")/$link" ;; esac
      resolved=$(stage_path_absolute "$link") || return 6
    done
    if [ -d "$resolved" ]; then
      resolved=$(cd -P "$resolved" && pwd) || return 6
      STAGE_RESOLVED_IGNORES+=("$resolved")
    fi
  done
}

stage_path_ignored() {
  local path="$1" ignored
  for ignored in "${STAGE_RESOLVED_IGNORES[@]}"; do
    case "$path" in "$ignored"|"$ignored"/*) return 0 ;; esac
  done
  return 1
}

# Content snapshot, not HEAD/status text. The regular-file hot path uses one
# Git hash process and one jq assembly process per snapshot, regardless of file
# count. Git's quoted stdin-paths format preserves embedded newlines/backslashes.
# No index/object writes; ignored untracked files are intentionally not evidence.
stage_snapshot() (
  local root="$1" scratch="$2" path digest mode subroot quoted
  mkdir "$scratch" || return 6
  git -C "$root" ls-files --cached --others --exclude-standard -z > "$scratch/paths" || return 6
  : > "$scratch/regular" || return 6
  : > "$scratch/hash-paths" || return 6
  : > "$scratch/special" || return 6
  while IFS= read -r -d '' path; do
    path=${path%/}
    stage_path_ignored "$root/$path" && continue
    if [ -L "$root/$path" ]; then
      readlink "$root/$path" > "$scratch/link" || return 6
      digest=$(git hash-object --no-filters -- "$scratch/link") || return 6
      printf '%s\0%s\0%s\0' "$path" symlink "$digest" >> "$scratch/special" || return 6
    elif [ -f "$root/$path" ]; then
      mode=file
      [ ! -x "$root/$path" ] || mode=executable
      printf '%s\0%s\0' "$path" "$mode" >> "$scratch/regular" || return 6
      quoted="$root/$path"
      quoted=${quoted//\\/\\\\}
      quoted=${quoted//\"/\\\"}
      quoted=${quoted//$'\n'/\\n}
      printf '"%s"\n' "$quoted" >> "$scratch/hash-paths" || return 6
    elif [ -d "$root/$path" ]; then
      subroot=$(git -C "$root/$path" rev-parse --show-toplevel 2>/dev/null) || return 6
      if [ "$subroot" = "$root/$path" ]; then
        stage_snapshot "$subroot" "$scratch/submodule" > "$scratch/submodule-content" || return 6
        digest=$(git hash-object --no-filters -- "$scratch/submodule-content") || return 6
        rm -rf "$scratch/submodule" || return 6
        printf '%s\0%s\0%s\0' "$path" submodule "$digest" >> "$scratch/special" || return 6
      fi
      # Otherwise this is an unpopulated gitlink with no working-tree content.
    elif [ ! -e "$root/$path" ]; then
      continue
    else
      echo "stage: cannot inspect $root/$path" >&2
      return 6
    fi
  done < "$scratch/paths"
  git hash-object --no-filters --stdin-paths < "$scratch/hash-paths" > "$scratch/hashes" || return 6
  jq -cn --rawfile paths "$scratch/regular" --rawfile hashes "$scratch/hashes" \
    --rawfile special "$scratch/special" '
    ($paths | split("\u0000") | if length == 0 then [] else .[:-1] end) as $p |
    ($hashes | split("\n") | if length == 0 then [] else .[:-1] end) as $h |
    ($special | split("\u0000") | if length == 0 then [] else .[:-1] end) as $s |
    if ($p|length) != 2*($h|length) or ($s|length)%3 != 0
       or any($h[]; test("^[0-9a-f]+$") | not) then error("invalid content snapshot")
    else
      ([range(0; $h|length) as $i | {path:$p[2*$i],mode:$p[2*$i+1],hash:$h[$i]}] +
       [range(0; $s|length; 3) as $i | {path:$s[$i],mode:$s[$i+1],hash:$s[$i+2]}]) |
      unique_by(.path)
    end' || return 6
)

# stage_pipe_prompt WORK_DIR PROMPT COMMAND [ARGS...] — run COMMAND in WORK_DIR
# with PROMPT piped to its stdin; the status is COMMAND's, never the writer's.
stage_pipe_prompt() (
  cd "$1" || exit
  prompt="$2"
  shift 2
  set +e
  printf '%s' "$prompt" | "$@"
  statuses=("${PIPESTATUS[@]}")
  exit "${statuses[1]}"
)

stage_reset_result() {
  STAGE_CLI_RC=''
  STAGE_EVIDENCE=none
  STAGE_STDOUT="${1%.log}.stdout.log"
}

# stage_run ROLE WORK_DIR LOG COMMAND [ARGS...]
# Sets STAGE_CLI_RC (empty if not invoked), STAGE_EVIDENCE, STAGE_STDOUT.
# Returns original nonzero CLI rc, 6 for capture/inspection errors, 5 for missing
# evidence, or 0. The caller records these fields in its open stage manifest.
# With STAGE_PROMPT set, it is piped to the CLI's stdin (one argument is capped
# at 128 KiB on Linux, #102); otherwise the CLI's stdin is /dev/null. Never the
# caller's stdin. The CLI's status is kept even if it leaves the prompt unread.
stage_run() {
  local role="$1" work_dir="$2" log="$3"
  local has_prompt=${STAGE_PROMPT+1} prompt="${STAGE_PROMPT-}"
  unset STAGE_PROMPT
  shift 3
  local scratch root='' before='' after='' rc=0 capture_rc=0 inspect_rc=0
  local has_stdout=0 changed=0 statuses
  stage_reset_result "$log"
  work_dir=$(cd -P "$work_dir" && pwd) || return 6
  stage_prepare_ignores "$work_dir" "$ORIGINAL_DIR" || return 6
  scratch=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/trio-stage.XXXXXX") || return 6
  scratch=$(cd -P "$scratch" && pwd) || return 6
  # Always exclude our own scratch even if TMPDIR points inside the repository.
  STAGE_RESOLVED_IGNORES+=("$scratch" "$log" "$STAGE_STDOUT")
  if [ "$role" = coder ] && git -C "$work_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    root=$(git -C "$work_dir" rev-parse --show-toplevel) || rc=6
    if [ "$rc" -eq 0 ]; then
      before=$(stage_snapshot "$root" "$scratch/before") || rc=6
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    # Open the transcript first, outside the CLI pipeline. Its stderr never
    # enters tee or the stdout artifact. PIPESTATUS preserves both failures.
    if {
      if [ -n "$has_prompt" ]; then
        stage_pipe_prompt "$work_dir" "$prompt" "$@" </dev/null | tee "$STAGE_STDOUT"
      else
        ( cd "$work_dir" && "$@" ) </dev/null | tee "$STAGE_STDOUT"
      fi
      statuses=("${PIPESTATUS[@]}")
    } > "$log" 2>&1; then
      STAGE_CLI_RC=${statuses[0]}
      capture_rc=${statuses[1]}
    else
      capture_rc=6
    fi
    # Preserve the actual CLI failure even when capture also fails. The tee
    # diagnostic remains in the transcript; stdout-log names its destination,
    # not a guarantee that a failed invocation produced a readable artifact.
    if [ -n "$STAGE_CLI_RC" ] && [ "$STAGE_CLI_RC" -ne 0 ]; then
      rc=$STAGE_CLI_RC
    elif [ "$capture_rc" -ne 0 ]; then
      rc=6
    else
      grep -q '[^[:space:]]' "$STAGE_STDOUT" || inspect_rc=$?
      case "$inspect_rc" in 0) has_stdout=1 ;; 1) ;; *) rc=6 ;; esac
      if [ -n "$root" ] && [ "$rc" -eq 0 ]; then
        after=$(stage_snapshot "$root" "$scratch/after") || rc=6
        [ "$before" = "$after" ] || changed=1
      fi
      if [ "$rc" -eq 0 ]; then
        case "$has_stdout:$changed" in
          1:1) STAGE_EVIDENCE=stdout-and-change ;;
          1:0) STAGE_EVIDENCE=stdout ;;
          0:1) STAGE_EVIDENCE=change ;;
          *) rc=5 ;;
        esac
      fi
    fi
  fi
  rm -rf "$scratch"
  if [ "$rc" -ne 0 ]; then
    printf 'stage: %s failed (cli rc=%s, stage rc=%s, evidence=%s); see %s\n' \
      "$role" "${STAGE_CLI_RC:-not-run}" "$rc" "$STAGE_EVIDENCE" "$log" >&2
  fi
  return "$rc"
}

stage_record_result() {
  [ -n "${STAGE_STDOUT:-}" ] || { echo "stage: no invocation to record" >&2; return 6; }
  manifest_add_input kind=stdout-log path="$STAGE_STDOUT" || return 1
  manifest_add_input kind=cli-rc value="${STAGE_CLI_RC:-not-run}" || return 1
  manifest_add_input kind=stage-rc value="$1" || return 1
  manifest_add_input kind=stage-evidence value="$STAGE_EVIDENCE"
}
