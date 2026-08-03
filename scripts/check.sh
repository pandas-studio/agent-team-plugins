#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r file; do bash -n "$file"; done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/.venv/*' | sort)
while IFS= read -r file; do jq -e . "$file" >/dev/null; done < <(find "$ROOT" -type f -name '*.json' -not -path '*/.venv/*' | sort)

"$ROOT/tests/smoke-hardening.sh"
"$ROOT/spec-trio/tests/smoke-pr5.sh"

if [ -x "$ROOT/runtime/.venv/bin/pytest" ]; then
  "$ROOT/runtime/.venv/bin/ruff" check "$ROOT/runtime/src" "$ROOT/runtime/tests"
  "$ROOT/runtime/.venv/bin/pytest" "$ROOT/runtime/tests"
else
  echo "runtime/.venv missing; run: cd runtime && uv sync --frozen --python 3.12 --extra dev" >&2
  exit 2
fi
