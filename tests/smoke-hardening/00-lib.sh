#!/usr/bin/env bash
# lib.sh's own cleanup: every registered entry runs, in reverse order, even when
# an assertion fails early or an entry fails, and the part keeps its exit status.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/smoke-hardening/lib.sh"
# cleanup_case BODY: run a part-shaped script whose body is BODY; print its
# exit status, the order its entries ran in, and whether its $TMP is gone.
cleanup_case() {
  local rc=0 part_tmp
  rm -f "$TMP/ran" "$TMP/part-tmp"
  /bin/bash -c '
    set -euo pipefail
    . "$1"
    printf "%s\n" "$TMP" > "$2/part-tmp"
    RAN="$2/ran"
    eval "$3"
  ' _ "$LIB" "$TMP" "$1" >/dev/null 2>&1 || rc=$?
  part_tmp="$(cat "$TMP/part-tmp")"
  printf 'rc=%s ran=%s tmp=%s\n' "$rc" "$(tr '\n' ' ' < "$TMP/ran" 2>/dev/null)" \
    "$([ -e "$part_tmp" ] && echo kept || echo gone)"
}
REGISTER='register_cleanup "echo first >> \"\$RAN\""; register_cleanup "echo second >> \"\$RAN\""'
assert_eq "$(cleanup_case "$REGISTER")" "rc=0 ran=second first  tmp=gone"
# An assertion that fails early still runs every entry and keeps the status.
assert_eq "$(cleanup_case "$REGISTER; assert_eq a b; echo not-reached >> \"\$RAN\"")" "rc=1 ran=second first  tmp=gone"
assert_eq "$(cleanup_case "$REGISTER; exit 7")" "rc=7 ran=second first  tmp=gone"
# An entry that fails, first to run or not, does not stop the rest.
assert_eq "$(cleanup_case "$REGISTER; register_cleanup false; exit 3")" "rc=3 ran=second first  tmp=gone"
assert_eq "$(cleanup_case "register_cleanup \"echo first >> \\\"\\\$RAN\\\"\"; register_cleanup false; register_cleanup \"echo third >> \\\"\\\$RAN\\\"\"")" \
  "rc=0 ran=third first  tmp=gone"
# An entry sees the value its variable holds at exit, not at registration.
assert_eq "$(cleanup_case 'V=early; register_cleanup "echo \$V >> \"\$RAN\""; V=late')" "rc=0 ran=late  tmp=gone"

# A failing part names itself and the line of the assertion that stopped it,
# also when assert_ok, which prints nothing itself, fails inside a helper.
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' ". \"$LIB\"" \
  'helper() { assert_ok test -n ""; }' 'assert_eq a a' 'helper' > "$TMP/failing-part.sh"
rc=0
/bin/bash "$TMP/failing-part.sh" >/dev/null 2>"$TMP/failing-part.err" || rc=$?
assert_eq "$rc:$(tail -1 "$TMP/failing-part.err")" \
  "1:hardening smoke (failing-part.sh): FAILED (rc=1) after 1 passed; last assertion started at failing-part.sh:4"

smoke_done 00-lib
