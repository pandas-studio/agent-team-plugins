#!/usr/bin/env bash
# Shared setup and assertions for tests/smoke-hardening/*.sh (#154). Each part
# sources this file, runs on its own, and ends with smoke_done; scripts/check.sh
# runs the parts in turn.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The drivers take DEV_TRIO_BIN / DEBATE_CONDUCTOR_BIN over PATH; an exported
# override would route these smokes past their stubs.
unset DEV_TRIO_BIN DEBATE_CONDUCTOR_BIN
# agy's home is pinned to a directory that does not exist, so agy roles get
# --add-dir but never --log-file, whatever this machine has installed (#103).
export DEV_TRIO_AGY_HOME=/nonexistent/dev-trio-test-agy-home
PASS=0

# Each assertion records where it was called before it runs. errexit stops a
# part at the first failure, so on a nonzero exit the last one recorded is where
# it failed; smoke_cleanup reports it (assert_ok and assert_fail print nothing).
SMOKE_AT=""
smoke_at() { SMOKE_AT="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"; }
assert_ok() { smoke_at; "$@"; PASS=$((PASS + 1)); }
assert_fail() { smoke_at; if "$@" >/dev/null 2>&1; then return 1; fi; PASS=$((PASS + 1)); }

assert_eq() {
  smoke_at
  if [ "$1" != "$2" ]; then
    printf 'FAIL (line %s): expected %q, got %q\n' "${BASH_LINENO[0]}" "$2" "$1" >&2
    return 1
  fi
  PASS=$((PASS + 1))
}

# Fixture repos must not pick up the contributor's git setup (signing, hooks).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"

# Cleanup runs in reverse order of registration, then $TMP goes. Each entry is
# eval'd at exit, so it sees the values its variables hold then. Register a
# resource in the shell that owns it, right after creating it: a registration
# made inside $(...) is lost with that subshell. An entry that fails does not
# stop the others, and the part keeps its own exit status.
SMOKE_CLEANUP=()
register_cleanup() { SMOKE_CLEANUP[${#SMOKE_CLEANUP[@]}]="$1"; }
smoke_cleanup() {
  local rc=$? i
  set +e
  i=${#SMOKE_CLEANUP[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    eval "${SMOKE_CLEANUP[$i]}" || :
  done
  rm -rf "$TMP"
  if [ "$rc" -ne 0 ]; then
    printf 'hardening smoke (%s): FAILED (rc=%s) after %s passed; last assertion started at %s\n' \
      "${0##*/}" "$rc" "$PASS" "${SMOKE_AT:-none}" >&2
  fi
  exit "$rc"
}
trap smoke_cleanup EXIT

smoke_done() { printf 'hardening smoke (%s): %d assertions passed\n' "$1" "$PASS"; }

# init_fixture_repo: a one-commit repo at $TMP/repo.
init_fixture_repo() {
  git init -q "$TMP/repo"
  git -C "$TMP/repo" config user.email test@example.com
  git -C "$TMP/repo" config user.name Test
  printf 'base\n' > "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  git -C "$TMP/repo" commit -qm init
}

# make_worker_cli_stubs: $TMP/worker-cli/{denied,answer,broken}. A worker CLI
# that exits 0 without an answer (denied), one that answers on stdout and to
# --output-last-message (answer), and one that fails (broken).
make_worker_cli_stubs() {
mkdir -p "$TMP/worker-cli"
printf '#!/bin/sh\necho "no output produced — auto-denied" >&2\nexit 0\n' > "$TMP/worker-cli/denied"
cat > "$TMP/worker-cli/answer" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then
    printf '## Verdict\nVerdict: RECONSIDER\n' > "$2"
    break
  fi
  shift
done
echo progress >&2
echo "## Verdict"
echo "Verdict: RECONSIDER"
STUB
printf '#!/bin/sh\necho boom >&2\nexit 9\n' > "$TMP/worker-cli/broken"
chmod +x "$TMP/worker-cli/denied" "$TMP/worker-cli/answer" "$TMP/worker-cli/broken"
}

# setup_driver: a driver fixture repo at $DRV and run_driver, which runs a
# driver there and prints its rc (stderr in $TMP/drv.err).
setup_driver() {
  DRV="$TMP/drv"
  git init -q "$DRV"
  printf 'prompt\n' > "$DRV/PROMPT.md"
  printf -- '- [ ] task\n' > "$DRV/BACKLOG.md"
  printf '# spec\n' > "$DRV/spec.md"
}
run_driver() {
  (cd "$DRV" && env PATH="$ROOT/dev-trio/bin:$ROOT/debate-conductor/bin:$PATH" \
    AGENT_TEAM=smoke TMUX="" RALPH_TRIO_WORKSPACE="$TMP/rw" SPEC_TRIO_WORKSPACE="$TMP/sw" \
    "$@" >/dev/null 2>"$TMP/drv.err" </dev/null; echo "rc=$?")
}
