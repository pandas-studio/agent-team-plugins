#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_sources() {
  find "$ROOT" -type f -name "$1" -not -path '*/.venv/*' -not -path '*/.git/*' | sort
}

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

"$ROOT/tests/smoke-hardening.sh"
"$ROOT/spec-trio/tests/smoke-pr5.sh"

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
