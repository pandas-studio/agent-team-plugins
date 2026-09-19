#!/usr/bin/env bash
# Debate answers are distinct from CLI diagnostics. Source registry.sh first.
# Native final capture is authoritative; stdout-only adapters must emit only
# answer text on stdout. RAW_LOG, when supplied, is a fresh private debug log.
# Return the CLI's failure first, else 5 for no answer or 6 for capture I/O.
#
# This is the debate-side boundary over registry_run_answer, not a second
# implementation of it. The library inspects and validates the answer; what it
# does not do is keep the CLI's console off the caller's stdout, and the round
# file is built from that stdout (debate.sh: strip_cli_banner | tee "$OUT"),
# which is what issue #67 reports. Everything below exists for that boundary.
debate_run_answer() (
  local model="$1" prompt="$2" raw_log="${3:-}" capture_dir="" final="" rc=0
  local statuses=()
  trap '[ -z "$capture_dir" ] || rm -rf -- "$capture_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  set +e

  case "${DEBATE_RAW_LOG:-0}" in
    0|1) ;;
    *) echo 'debate-answer: unrecognized DEBATE_RAW_LOG value; use 1 to retain raw diagnostics (retention disabled)' >&2 ;;
  esac

  # No raw diagnostics reach the caller, even when debugging is enabled.
  if [ -n "$raw_log" ]; then
    if ! (umask 077; set -C; : > "$raw_log") || ! exec 9>>"$raw_log"; then
      echo "debate-answer: cannot create raw log: $raw_log" >&2
      exit 6
    fi
  else
    exec 9>/dev/null || exit 6
  fi

  if registry_has_final "$model"; then
    capture_dir="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/debate-answer.XXXXXX")" || {
      echo 'debate-answer: cannot create final-answer capture' >&2
      exit 6
    }
    final="$capture_dir/final"
    # The library runs the CLI, captures natively and judges the artifact. Its
    # stdout is the transcript and its diagnostics name $final, an internal
    # path: both go to fd 9, never to the caller.
    registry_run_answer "$model" "$prompt" "$final" >&9 2>&9
    rc=$?
    # The library reports a missing artifact and a malformed one alike (rc=5).
    # A directory, FIFO, device, dangling link or unreadable file is a capture
    # failure, not an answerless run, so it keeps this side's rc=6.
    if [ "$rc" -eq 5 ] && { [ -e "$final" ] || [ -L "$final" ]; } &&
       { [ ! -f "$final" ] || [ ! -r "$final" ]; }; then
      rc=6
    elif [ "$rc" -eq 5 ] && [ ! -e "$final" ] && [ ! -L "$final" ]; then
      echo "debate-answer: model '$model' exited 0 but wrote no final-answer file; check CLI native-capture support and ensure *_CLI wrappers forward all arguments" >&2
    fi
    # Publication happens only after the library has validated the artifact.
    [ "$rc" -ne 0 ] || cat "$final" 2>/dev/null || rc=6
  elif [ -n "$raw_log" ]; then
    registry_run_answer "$model" "$prompt" 2>&9 | tee -a "$raw_log"
    statuses=("${PIPESTATUS[@]}")
    rc=${statuses[0]}
    if [ "$rc" -eq 0 ] && [ "${statuses[1]}" -ne 0 ]; then rc=6; fi
  else
    registry_run_answer "$model" "$prompt" 2>&9
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    echo "debate-answer: model '$model' failed (rc=$rc; 5=no answer, 6=capture failure)" >&2
    if [ -n "$raw_log" ]; then
      echo "debate-answer: raw diagnostics: $raw_log" >&2
    else
      echo 'debate-answer: set DEBATE_RAW_LOG=1 to retain raw diagnostics on a new invocation' >&2
    fi
  fi
  exit "$rc"
)
