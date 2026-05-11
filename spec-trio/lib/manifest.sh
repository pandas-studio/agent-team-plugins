#!/usr/bin/env bash
# Vendored from ralph-trio plugin (snapshot 2026-05-11). Re-sync with:
#   cp ../ralph-trio/lib/manifest.sh ./lib/manifest.sh
# then restore this provenance header. ralph-trio's copy is itself vendored
# from core/lib/manifest.sh; spec-trio carries its own snapshot so it has
# no cross-plugin sourcing dependency. The schema (PR 1, schema_version=1)
# is frozen, and tests/smoke-pr5.sh exercises the spec-* variants of the
# manifest API end-to-end.
#
# manifest.sh — typed run manifest helper (RFC 0004 PR 1).
#
# Sourced from a variant entry script. Each call to manifest_init seeds a
# tmp file next to the variant's run log; mutators (manifest_add_role,
# manifest_add_input, manifest_set_verdict, manifest_set_parent) edit that
# tmp via jq; manifest_finalize stamps ended_at and atomically renames it
# into <log-without-.log>.manifest.json.
#
# Schema (frozen at PR 1, schema_version=1):
#   {
#     run_id, variant, schema_version, started_at, ended_at, parent_run_id,
#     roles:  [ { name, model, prompt_path,
#                 prompt_source_sha256,   # hash of prompt file on disk
#                 prompt_resolved_sha256, # hash of post-injection prompt; PR 10
#                                         # filled by reviewer/researcher children
#                 round?                  # optional int; set by debate (per-round
#                                         # invocations); other variants omit
#               } ],
#     inputs: [ { kind, ref?, value?, path?, sha256?, verdict?, action? } ],
#     verdict: SHIP | NEEDS-FIX | DISCUSS | OUT-OF-SCOPE | null,
#     log_path                            # variant-specific: file (bisect/ralph) or
#                                         # directory (debate's per-round dir)
#   }
#
# Public API:
#   manifest_init <variant> <log_path>
#   manifest_set_parent <run_id>
#   manifest_add_role <name> <model> <prompt_path> [resolved_prompt_sha256] [round]
#   manifest_add_input kind=... [ref=...] [value=...] [path=...] [verdict=...] [action=...]
#   manifest_set_verdict <verdict>            # closed vocab; "" or "null" -> null
#   to_manifest_verdict <token>               # map out-of-vocab tokens to "null"
#   manifest_sha256_string <string>           # PR 10: hex-hash a literal string
#   manifest_finalize
#   manifest_cleanup                          # remove tmp without finalizing (trap-safe)
#   manifest_is_nested                        # rc=0 iff MANIFEST_PARENT_TMP is set
#
# Caller responsibility: source this file, then on any cleanup path
# (trap INT TERM, error exits, normal exit) call manifest_finalize on
# success or manifest_cleanup on abort. The tmp file otherwise leaks.
#
# Nesting contract (RFC 0004 PR 6, env var MANIFEST_PARENT_TMP):
#   When a parent variant (ralph-trio, spec-trio, …) invokes a child
#   dispatcher script (dev/ask-codex.sh, dev/ask-gemini.sh, …) that has
#   also adopted manifests, the child must NOT emit its own manifest:
#   a duplicate child manifest would force every consumer into
#   parent/child join logic for one logical action.
#
#   The contract: parents export MANIFEST_PARENT_TMP="$MANIFEST_TMP"
#   for the lifetime of the child's subshell. The child sources this
#   file and either (a) calls manifest_is_nested explicitly to
#   short-circuit standalone-only work, or (b) just calls manifest_init
#   / manifest_add_* / manifest_finalize unconditionally — most helpers
#   silently no-op while MANIFEST_PARENT_TMP is non-empty. The standalone
#   path (when the env var is absent) emits a normal manifest.
#
#   Carve-out (PR 9): manifest_add_role does NOT no-op when nested —
#   instead it writes the role entry to MANIFEST_PARENT_TMP. Only the
#   child dispatcher knows its resolved role-file path (REVIEWER_ROLE_FILE
#   override, etc.), so attributing the role at the child's call site is
#   what makes prompt_source_sha256 trustworthy. Parents must NOT pre-fill
#   an empty-prompt_path role entry — the child's call records it.
#   manifest_add_input / manifest_set_verdict / manifest_finalize keep
#   the no-op semantics: parent owns the input + verdict framing.
#
#   The env var name is part of the public surface. Renaming it without
#   updating all current adopters (ralph-trio, spec-trio, dev/ask-codex,
#   dev/ask-gemini, watch/ask-bug-reviewer, watch/ask-design-reviewer)
#   silently breaks nesting suppression — every nested call would emit a
#   duplicate child manifest.
#
# Dependency: jq (1.6+). manifest_init aborts the calling script if missing.

if ! command -v jq >/dev/null 2>&1; then
  echo "manifest.sh: jq not found in PATH — required for run manifests" >&2
  return 1 2>/dev/null || exit 1
fi

MANIFEST_PATH=""
MANIFEST_TMP=""
MANIFEST_RUN_ID=""

_manifest_now_iso() {
  # ISO-8601 with timezone, portable across BSD (macOS) and GNU date.
  # `date +%z` outputs +0900; sed inserts the colon -> +09:00.
  date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}

# manifest_is_nested — rc=0 iff MANIFEST_PARENT_TMP is set (non-empty).
# When nested, every public helper short-circuits to a silent no-op so
# child dispatchers can be called from a parent variant without duplicate
# manifests landing on disk. See the "Nesting contract" header note.
manifest_is_nested() {
  [ -n "${MANIFEST_PARENT_TMP:-}" ]
}

_manifest_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# manifest_sha256_string <string>
#   Echo the sha256 of the literal string argument (no trailing newline added).
#   Public helper for child dispatchers (RFC 0004 PR 10) that hold the resolved
#   prompt in memory rather than on disk: hashing in-process avoids a tmp file
#   + trap dance. The output is the same 64-hex-char form _manifest_sha256
#   produces for files, so it's a drop-in 4th arg for manifest_add_role.
manifest_sha256_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

_manifest_require_init() {
  if [ -z "${MANIFEST_TMP:-}" ] || [ ! -f "$MANIFEST_TMP" ]; then
    echo "manifest.sh: manifest_init was not called (or tmp missing): ${MANIFEST_TMP:-<unset>}" >&2
    return 1
  fi
}

# Apply a jq filter to a specific tmp file atomically. Extra args after the
# filter (e.g. --arg name value) are forwarded to jq. The two callers are:
# (a) _manifest_jq_inplace, which targets MANIFEST_TMP after init-check;
# (b) manifest_add_role's nested-write path, which targets MANIFEST_PARENT_TMP.
_manifest_jq_inplace_to() {
  local target="$1"
  local filter="$2"
  shift 2
  local out
  if ! out=$(jq "$@" "$filter" "$target" 2>&1); then
    echo "manifest.sh: jq edit failed: $out" >&2
    return 1
  fi
  printf '%s\n' "$out" > "$target"
}

# Apply a jq filter to MANIFEST_TMP atomically. Extra args (e.g. --arg name value)
# are forwarded to jq.
_manifest_jq_inplace() {
  _manifest_require_init || return 1
  local filter="$1"
  shift
  _manifest_jq_inplace_to "$MANIFEST_TMP" "$filter" "$@"
}

# manifest_init <variant> <log_path>
#   <log_path> is the variant's existing log file (e.g. .../bisect-20260508.log)
#   OR the variant's run directory (e.g. .../debate-20260508/) when the
#   variant emits per-round files instead of a single log stream. The manifest
#   is written next to it: any trailing ".log" is stripped, then ".manifest.json"
#   is appended. log_path is recorded as-is into the manifest so consumers
#   (bisect-meta, ralph-meta, spec-coverage) can navigate from manifest -> log
#   without re-resolving.
manifest_init() {
  # Nested context: parent variant attributes us, no child manifest emitted.
  # Subsequent helpers also no-op while MANIFEST_PARENT_TMP is set.
  if manifest_is_nested; then
    return 0
  fi
  # Re-init guard: refuse to overwrite an in-flight manifest. Hard-exits
  # rather than `return 1` because callers may run with `set -uo pipefail`
  # (no -e) — under those settings a return-failure would silently no-op
  # and the next mutator would corrupt the prior stage's tmp file. RFC 0004
  # PR 3 added this when ralph-trio's six-stage chain made missed-finalize
  # bugs much easier to introduce.
  if [ -n "${MANIFEST_TMP:-}" ] && [ -f "$MANIFEST_TMP" ]; then
    echo "manifest_init: prior manifest still open ($MANIFEST_TMP) — caller forgot finalize/cleanup" >&2
    exit 1
  fi
  local variant="$1"
  local log_path="$2"
  local log_dir log_base
  log_dir=$(dirname "$log_path")
  log_base=$(basename "$log_path")
  log_base="${log_base%.log}"
  MANIFEST_PATH="$log_dir/$log_base.manifest.json"
  MANIFEST_TMP="$MANIFEST_PATH.tmp"
  local rand
  rand=$(printf '%04x' "$((RANDOM % 65536))")
  local run_id="$log_base-$rand"
  MANIFEST_RUN_ID="$run_id"
  jq -n \
    --arg run_id "$run_id" \
    --arg variant "$variant" \
    --arg started_at "$(_manifest_now_iso)" \
    --arg log_path "$log_path" \
    '{
       run_id: $run_id,
       variant: $variant,
       schema_version: 1,
       started_at: $started_at,
       ended_at: null,
       parent_run_id: null,
       roles: [],
       inputs: [],
       verdict: null,
       log_path: $log_path
     }' > "$MANIFEST_TMP"
}

manifest_set_parent() {
  if manifest_is_nested; then return 0; fi
  local pid="$1"
  _manifest_jq_inplace '.parent_run_id = $pid' --arg pid "$pid"
}

# manifest_add_role <name> <model> <prompt_path> [resolved_prompt_sha256] [round]
#   <prompt_path> is the role file on disk (e.g. core/bisect/roles/judge.md).
#   Its sha256 fills prompt_source_sha256.
#   <resolved_prompt_sha256> is a precomputed sha256 of the post-injection
#   prompt — the byte-exact string actually sent to the model. PR 10: child
#   dispatchers hold $PROMPT in memory, so they hash it via
#   manifest_sha256_string and pass the hash directly. Empty leaves the
#   field null (debate, bisect, ralph stages, spec stages skip it because
#   they don't assemble a single $PROMPT at the manifest call site).
#   <round> is an optional integer (PR 4): debate sets it per-round so a
#   single manifest can hold N role entries that are still self-describing
#   under jq. Other variants omit it, leaving the field absent.
#
#   Nested-write carve-out (PR 9): when MANIFEST_PARENT_TMP is set, this
#   helper writes to the parent's tmp instead of no-op'ing. Rationale: only
#   the child dispatcher (ask-codex / ask-gemini / …) knows the resolved
#   role-file path — REVIEWER_ROLE_FILE override, etc. — so the role entry
#   belongs to its call site. Parents must NOT pre-fill an empty-prompt_path
#   role entry before invoking the child; the child's own call records it.
#   manifest_add_input / manifest_set_verdict still no-op when nested
#   (parent owns input + verdict framing).
manifest_add_role() {
  local target_tmp
  if manifest_is_nested; then
    target_tmp="$MANIFEST_PARENT_TMP"
    if [ ! -f "$target_tmp" ]; then
      echo "manifest_add_role: MANIFEST_PARENT_TMP set but file missing: $target_tmp" >&2
      return 1
    fi
  else
    _manifest_require_init || return 1
    target_tmp="$MANIFEST_TMP"
  fi
  local name="$1"
  local model="$2"
  local prompt_path="$3"
  local resolved_hash="${4:-}"
  local round="${5:-}"
  local source_hash=""
  if [ -n "$prompt_path" ] && [ -f "$prompt_path" ]; then
    source_hash=$(_manifest_sha256 "$prompt_path")
  fi
  _manifest_jq_inplace_to "$target_tmp" \
    '.roles += [(
        {
          name: $name,
          model: $model,
          prompt_path: $pp,
          prompt_source_sha256:   ( if $sh != "" then $sh else null end ),
          prompt_resolved_sha256: ( if $rh != "" then $rh else null end )
        }
        + ( if $round != "" then { round: ($round | tonumber) } else {} end )
     )]' \
    --arg name "$name" \
    --arg model "$model" \
    --arg pp "$prompt_path" \
    --arg sh "$source_hash" \
    --arg rh "$resolved_hash" \
    --arg round "$round"
}

# manifest_add_input KEY=VAL [KEY=VAL ...]
#   kind=<...>           required
#   ref=<sha-or-ref>     for git refs (good-ref, bad-ref, candidate, first-bad-commit)
#   value=<string>       for inline values (test-cmd, judge-mode flag, free-form)
#   path=<file-path>     auto-hashes via sha256
#   verdict=<vocab>      per-step verdicts inside an input (e.g. candidate step)
#   action=<good|bad|skip>  per-step bisect dispatch action
#   Unknown keys -> error.
manifest_add_input() {
  if manifest_is_nested; then return 0; fi
  local kind="" ref="" value="" path="" verdict="" action=""
  local arg k v
  for arg in "$@"; do
    k="${arg%%=*}"
    v="${arg#*=}"
    case "$k" in
      kind)    kind="$v" ;;
      ref)     ref="$v" ;;
      value)   value="$v" ;;
      path)    path="$v" ;;
      verdict) verdict="$v" ;;
      action)  action="$v" ;;
      *)       echo "manifest_add_input: unknown key '$k' (expected kind|ref|value|path|verdict|action)" >&2; return 1 ;;
    esac
  done
  if [ -z "$kind" ]; then
    echo "manifest_add_input: kind=<...> is required" >&2
    return 1
  fi
  local file_hash=""
  if [ -n "$path" ] && [ -f "$path" ]; then
    file_hash=$(_manifest_sha256 "$path")
  fi
  _manifest_jq_inplace \
    '.inputs += [
       (
         { kind: $kind }
         + ( if $ref     != "" then { ref:     $ref     } else {} end )
         + ( if $value   != "" then { value:   $value   } else {} end )
         + ( if $path    != "" then { path:    $path    } else {} end )
         + ( if $h       != "" then { sha256:  $h       } else {} end )
         + ( if $verdict != "" then { verdict: $verdict } else {} end )
         + ( if $action  != "" then { action:  $action  } else {} end )
       )
     ]' \
    --arg kind "$kind" \
    --arg ref "$ref" \
    --arg value "$value" \
    --arg path "$path" \
    --arg h "$file_hash" \
    --arg verdict "$verdict" \
    --arg action "$action"
}

# manifest_set_verdict <verdict>
#   Closed vocabulary: SHIP | NEEDS-FIX | DISCUSS | OUT-OF-SCOPE.
#   Empty string or "null" -> verdict stays/returns to null.
manifest_set_verdict() {
  if manifest_is_nested; then return 0; fi
  local v="${1:-}"
  case "$v" in
    SHIP|NEEDS-FIX|DISCUSS|OUT-OF-SCOPE) ;;
    ""|null) v="" ;;
    *) echo "manifest_set_verdict: closed-vocab violation: '$v' (expected SHIP|NEEDS-FIX|DISCUSS|OUT-OF-SCOPE|null)" >&2; return 1 ;;
  esac
  if [ -z "$v" ]; then
    _manifest_jq_inplace '.verdict = null'
  else
    _manifest_jq_inplace '.verdict = $v' --arg v "$v"
  fi
}

# to_manifest_verdict <token>
#   Map a verdict token (e.g. parse_codex_verdict's UNKNOWN) onto manifest's
#   closed vocab. Anything out-of-vocab → "null", the literal string
#   manifest_set_verdict treats as "no verdict". Callers should record the
#   raw out-of-vocab token separately as a kind=raw-verdict input for
#   forensics. Hoisted from ralph-trio / spec-trio in RFC 0004 PR 8.
to_manifest_verdict() {
  case "${1:-}" in
    SHIP|NEEDS-FIX|DISCUSS|OUT-OF-SCOPE) printf '%s' "$1" ;;
    *)                                   printf 'null' ;;
  esac
}

manifest_finalize() {
  if manifest_is_nested; then return 0; fi
  if [ -z "${MANIFEST_TMP:-}" ] || [ ! -f "$MANIFEST_TMP" ]; then
    return 0
  fi
  _manifest_jq_inplace '.ended_at = $ea' --arg ea "$(_manifest_now_iso)" || return 1
  mv "$MANIFEST_TMP" "$MANIFEST_PATH"
  MANIFEST_TMP=""
  MANIFEST_RUN_ID=""
}

# manifest_cleanup — remove the tmp without finalizing. For trap INT/TERM
# paths where the run aborted and the partial manifest is misleading. Safe
# to call when nothing is initialized. Nested-tolerant: trap handlers in
# child dispatchers can call this unconditionally.
manifest_cleanup() {
  if manifest_is_nested; then return 0; fi
  if [ -n "${MANIFEST_TMP:-}" ] && [ -f "$MANIFEST_TMP" ]; then
    rm -f "$MANIFEST_TMP"
  fi
  MANIFEST_TMP=""
  MANIFEST_RUN_ID=""
}
