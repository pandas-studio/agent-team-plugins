#!/usr/bin/env bash
# scripts/check.sh [all|tests|smoke|rest]
#
# With no argument, or `all`, every section runs in order. A part runs only
# its own sections, so CI can run the parts as parallel jobs; every section
# belongs to exactly one part.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: scripts/check.sh [all|tests|smoke|rest]" >&2
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
PART="${1-all}"
case "$PART" in
  all | tests | smoke | rest) ;;
  *)
    usage
    exit 2
    ;;
esac

# Reject invalid harness settings before spending time on unrelated suites.
# Every part runs this.
SPEC_VERIFICATION_TEST="$ROOT/spec-trio/tests/test_verification.py"
if [ ! -f "$SPEC_VERIFICATION_TEST" ]; then
  echo "spec-trio verification harness missing: $SPEC_VERIFICATION_TEST" >&2
  exit 2
fi
python3 "$SPEC_VERIFICATION_TEST" --check-config

find_sources() {
  find "$ROOT" -type f -name "$1" -not -path '*/.venv/*' -not -path '*/.git/*' | sort
}

static_checks() {
  # A plugin changed since the base needs a higher version in every manifest,
  # or installed copies never refresh (#151). VERSION_BUMP_BASE picks the base.
  python3 "$ROOT/scripts/check-version-bump.py"

  while IFS= read -r file; do bash -n "$file"; done < <(find_sources '*.sh')
  while IFS= read -r file; do jq -e . "$file" >/dev/null; done < <(find_sources '*.json')

  # Gated at -S error: that is clean today. Raising to -S warning first needs the
  # existing SC2164/SC2034 backlog in the trio scripts cleared — a separate change,
  # since `cd ... || exit` fixes alter failure behaviour in files untouched here.
  if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r file; do shellcheck -S error -x "$file"; done < <(find_sources '*.sh')
  elif [ "${CI:-}" = "true" ]; then
    echo "shellcheck missing in CI" >&2
    exit 2
  else
    echo "shellcheck not installed; skipping (install it to match CI)" >&2
  fi
}

root_tests() {
  python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'
}

plugin_tests() {
  python3 -m unittest discover -s "$ROOT/eval-trio/tests" -p 'test_*.py'
  python3 -m unittest discover -s "$ROOT/spec-forge/tests" -p 'test_*.py'
}

smokes() {
  # One part at a time, in order; each runs on its own and prints its count.
  for part in "$ROOT"/tests/smoke-hardening/[0-9]*.sh; do
    echo "== ${part#"$ROOT"/}"
    "$part"
  done
  "$ROOT/tests/smoke-review-results.sh"
  "$ROOT/tests/smoke-review-callers.sh"
  "$ROOT/spec-trio/tests/smoke-pr5.sh"
}

spec_verification() {
  python3 "$SPEC_VERIFICATION_TEST"
}

doctors() {
  # The doctors' stub smokes drive the real wrappers and loops, so a contract
  # change can break them; outside this script that went unnoticed (#105).
  # --smoke-only: a developer's CLI login state is not a property of the code.
  bash "$ROOT/dev-trio/bin/dev-trio-doctor.sh" --smoke-only
  # Their dependency checks honour DEV_TRIO_BIN / DEBATE_CONDUCTOR_BIN; an
  # exported override naming another install is not a property of this checkout.
  (
    unset DEV_TRIO_BIN DEBATE_CONDUCTOR_BIN
    bash "$ROOT/ralph-trio/bin/ralph-trio-doctor.sh"
    bash "$ROOT/spec-trio/bin/spec-trio-doctor.sh"
  )
}

runtime_tests() {
  if [ -x "$ROOT/runtime/.venv/bin/pytest" ]; then
    "$ROOT/runtime/.venv/bin/ruff" check "$ROOT/runtime/src" "$ROOT/runtime/tests"
    "$ROOT/runtime/.venv/bin/pytest" "$ROOT/runtime/tests"
  elif [ "${CI:-}" = "true" ]; then
    echo "runtime/.venv missing in CI; uv sync must run first" >&2
    exit 2
  else
    # Don't block a bash-only contributor on a Python toolchain they may not have.
    echo "runtime/.venv missing; skipping runtime tests" >&2
    echo "  uv sync --directory runtime --frozen --python 3.12 --extra dev" >&2
  fi
}

# section <part> <function>: run the function when its part was asked for.
# Call it only as a plain command. Under `if`, `!`, `&&` or `||` bash switches
# errexit off inside the function, and a failing check would no longer stop
# the script.
section() {
  case "$PART" in
    all | "$1")
      echo "== check.sh: $2"
      "$2"
      ;;
  esac
}

section rest static_checks
section tests root_tests
section rest plugin_tests
section smoke smokes
section rest spec_verification
section rest doctors
section rest runtime_tests
