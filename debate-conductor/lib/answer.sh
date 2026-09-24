#!/usr/bin/env bash
# Debate answers are distinct from CLI diagnostics. Source registry.sh first.
# Native final capture is authoritative; stdout-only adapters must emit only
# answer text on stdout. RAW_LOG, when supplied, is a fresh private debug log.
# Return the CLI's failure first, else 5 for no answer or 6 for capture I/O.
#
# The native path runs the CLI itself rather than calling registry_run_answer,
# and the reason is the model's own exit status. The library reports "the model
# failed" and "the model exited 0 leaving no answer" with the same 5, which is
# right for its callers and wrong here: this side answers a third question --
# whether the capture path itself is malformed (6). Delegating and mapping 5
# back to 6 was measured to overwrite a model that exits 5 with a directory,
# FIFO, dangling link or unreadable file in place (5 -> 6 in four modes).
# What the library cannot be asked for is inspected here, and nothing else is.
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
    capture_dir="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/debate-answer.XXXXXX" 2>&9)" || {
      echo 'debate-answer: cannot create final-answer capture' >&2
      exit 6
    }
    final="$capture_dir/final"
    registry_run "$model" "$prompt" "$final" >&9 2>&9
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ ! -e "$final" ] && [ ! -L "$final" ]; then
        rc=5
        echo "debate-answer: model '$model' exited 0 but wrote no final-answer file; check CLI native-capture support and ensure *_CLI wrappers forward all arguments" >&2
      elif [ ! -f "$final" ] || [ ! -r "$final" ]; then
        # Reject FIFOs/devices/directories before grep can block or disclose
        # an internal capture path. A dangling symlink is malformed, not absent.
        rc=6
      else
        grep -q '[^[:space:]]' "$final" 2>/dev/null
        case "$?" in
          0) cat "$final" 2>/dev/null || rc=6 ;;
          1) rc=5 ;;
          *) rc=6 ;;
        esac
      fi
    fi
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
    # The registry's own reason goes to the raw diagnostics, so name rc 3 here:
    # an argv model given a prompt one Linux argument cannot hold is one (#102).
    echo "debate-answer: model '$model' failed (rc=$rc; 3=not started: unknown model, bad template, or a prompt too large for one argument; 5=no answer; 6=capture failure)" >&2
    if [ -n "$raw_log" ]; then
      echo "debate-answer: raw diagnostics: $raw_log" >&2
    else
      echo 'debate-answer: set DEBATE_RAW_LOG=1 to retain raw diagnostics on a new invocation' >&2
    fi
  fi
  exit "$rc"
)
