#!/usr/bin/env bash
# The model registry and agent-team-models.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# agent-team-models remove: role keys are printed one per line, never
# word-split or globbed (a key of `*` once listed the working directory).
for plugin in dev-trio debate-conductor; do
  printf '%s\n' '{"version":1,"models":{"mine":{"command":"x","args":["{prompt}"]}},"roles":{"*":"mine","a b":"mine","dev-trio.reviewer":"codex"}}' \
    > "$TMP/refs-models.json"
  (cd "$TMP" && AGENT_TEAM_MODELS_CONFIG="$TMP/refs-models.json" \
    "$ROOT/$plugin/bin/agent-team-models.sh" remove mine >/dev/null 2>"$TMP/refs.err") || true
  assert_eq "$(sed -n 's/^  //p' "$TMP/refs.err")" "$(printf '*\na b')"
  (cd "$TMP" && AGENT_TEAM_MODELS_CONFIG="$TMP/refs-models.json" \
    "$ROOT/$plugin/bin/agent-team-models.sh" remove mine --force --fallback codex >"$TMP/refs.out" 2>&1)
  assert_eq "$(sed -n 's/^  //p' "$TMP/refs.out")" "$(printf '*\na b')"
  assert_eq "$(jq -c '.roles' "$TMP/refs-models.json")" '{"*":"codex","a b":"codex","dev-trio.reviewer":"codex"}'
done

# agent-team-models must not overwrite a config it could not parse: a write
# built without it would drop every model.
for plugin in dev-trio debate-conductor; do
  bad_cfg='{"version":1,"models":{"mine":{"command":"x","args":["{prompt}"]}},}'
  for cmd in "preset add kimi-code" "add z --command z --arg {prompt}" "edit mine --command y" \
             "remove mine" "set-role dev-trio.reviewer codex"; do
    printf '%s\n' "$bad_cfg" > "$TMP/bad-models.json"
    rc=0
    # shellcheck disable=SC2086  # $cmd is a word list on purpose
    AGENT_TEAM_MODELS_CONFIG="$TMP/bad-models.json" "$ROOT/$plugin/bin/agent-team-models.sh" $cmd \
      >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" 2
    assert_eq "$(cat "$TMP/bad-models.json")" "$bad_cfg"
  done
done

# #133 item 5: a malformed config is refused, never replaced by the built-ins.
# Each shape the runtime's _load refuses makes every config-reading query fail
# (rc 3) with the reason and the file first on stderr; list, show and doctor
# fail too, and writes are refused without touching the file.
for shape in '' '{} {}' '{bad' '[1]' '{"models":[]}' '{"roles":[]}' '{"roles":{"dev-trio.reviewer":1}}' '{"models":{"m":"s"}}'; do
  printf '%s' "$shape" > "$TMP/shape.json"
  out=$(AGENT_TEAM_MODELS_CONFIG="$TMP/shape.json" bash -c '
    . "$1/dev-trio/lib/registry.sh"
    for q in "registry_model_exists codex" "registry_has_final codex" "registry_prompt_via codex" \
             "registry_list_model_ids" "registry_resolve_role dev-trio reviewer" \
             "registry_config_role dev-trio.reviewer" "registry_resolve_command codex"; do
      rc=0; err=$($q 2>&1 >/dev/null) || rc=$?
      printf "%s rc=%s first=%s\n" "${q%% *}" "$rc" "$(printf "%s" "$err" | head -1 | cut -c1-17)"
    done' _ "$ROOT")
  assert_eq "$(printf '%s\n' "$out" | grep -vc ' rc=3 first=registry: config ' || true)" "0"
  # The host helpers read the config binding before applying a host default;
  # a malformed config must not turn into that default.
  hosts=$(AGENT_TEAM_MODELS_CONFIG="$TMP/shape.json" DEV_TRIO_PM_HOST=codex bash -c '
    . "$1/dev-trio/lib/registry.sh"; . "$1/dev-trio/lib/host.sh"
    rc=0; dev_trio_resolve_role reviewer >/dev/null 2>&1 || rc=$?; printf "dev=%s " "$rc"
    . "$1/debate-conductor/lib/registry.sh"; . "$1/debate-conductor/lib/host.sh"
    rc=0; debate_conductor_resolve_role critic >/dev/null 2>&1 || rc=$?; printf "debate=%s" "$rc"' _ "$ROOT")
  assert_eq "$hosts" "dev=3 debate=3"
  for plugin in dev-trio debate-conductor; do
    for cmd in "list" "show codex"; do
      rc=0
      # shellcheck disable=SC2086  # $cmd is a word list on purpose
      AGENT_TEAM_MODELS_CONFIG="$TMP/shape.json" "$ROOT/$plugin/bin/agent-team-models.sh" $cmd \
        >/dev/null 2>"$TMP/shape.err" || rc=$?
      assert_eq "$rc" 3
      assert_eq "$(head -1 "$TMP/shape.err")" "$(sed -n '1p' "$TMP/shape.err" | grep "^registry: config .*: $TMP/shape.json$")"
    done
    rc=0
    AGENT_TEAM_MODELS_CONFIG="$TMP/shape.json" "$ROOT/$plugin/bin/agent-team-models.sh" doctor \
      >"$TMP/shape.out" 2>&1 || rc=$?
    assert_eq "$rc" 1
    assert_ok grep -q "\[FAIL\] $TMP/shape.json: config " "$TMP/shape.out"
    rc=0
    AGENT_TEAM_MODELS_CONFIG="$TMP/shape.json" "$ROOT/$plugin/bin/agent-team-models.sh" \
      set-role dev-trio.reviewer codex >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" 2
    assert_eq "$(cat "$TMP/shape.json")" "$shape"
  done
done

# #103: agy's workspace_args/log_args are prefixed only when the caller passes
# REGISTRY_WORKSPACE / REGISTRY_CLI_LOG, each on its own. agy's prompt uses
# stdin even when neither prefix is present (debate-conductor sets neither).
REG_TMP=$(mktemp -d)
REG_TMP=$(cd "$REG_TMP" && pwd -P)
register_cleanup 'rm -rf "$REG_TMP"'
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\nprintf " stdin=%%s\\n" "$(wc -c | tr -d " ")"\n' > "$REG_TMP/rec"
chmod +x "$REG_TMP/rec"
registry_argv() {
  env -u REGISTRY_WORKSPACE -u REGISTRY_CLI_LOG -u REGISTRY_CMD_OVERRIDE \
    AGENT_TEAM_MODELS_CONFIG="$REG_TMP/none.json" AGY_CLI="$REG_TMP/rec" CODEX_CLI="$REG_TMP/rec" \
    "$@" bash -c '. "$1/dev-trio/lib/registry.sh"; shift; eval "$*"' _ "$ROOT" "$REG_CALL"
}
REG_CALL='registry_run agy P'
assert_eq "$(registry_argv)" '[--input-format][text][--output-format][text] stdin=2'
REG_CALL='REGISTRY_WORKSPACE=/r registry_run agy P'
assert_eq "$(registry_argv)" '[--add-dir][/r][--input-format][text][--output-format][text] stdin=2'
REG_CALL='REGISTRY_CLI_LOG=/l registry_run agy P'
assert_eq "$(registry_argv)" '[--log-file][/l][--input-format][text][--output-format][text] stdin=2'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run agy P'
assert_eq "$(registry_argv)" '[--log-file][/l][--add-dir][/r][--input-format][text][--output-format][text] stdin=2'
REG_CALL='REGISTRY_WORKSPACE= REGISTRY_CLI_LOG= registry_run agy P'
assert_eq "$(registry_argv REGISTRY_WORKSPACE=/stale REGISTRY_CLI_LOG=/stale)" '[--input-format][text][--output-format][text] stdin=2'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run codex P'
assert_eq "$(registry_argv)" '[exec][--skip-git-repo-check][-] stdin=2'
REG_CALL='REGISTRY_WORKSPACE=/r REGISTRY_CLI_LOG=/l registry_run_answer agy P; echo "rc=$?"'
assert_eq "$(registry_argv)" "$(printf '[--log-file][/l][--add-dir][/r][--input-format][text][--output-format][text] stdin=2\nrc=0')"
REG_CALL='registry_has_workspace agy && ! registry_has_workspace codex && echo yes'
assert_eq "$(registry_argv)" yes

# #102: one argument is capped at 128 KiB on Linux (MAX_ARG_STRLEN). The claude
# and codex built-ins take the prompt on stdin, whole; argv models refuse a
# prompt that one argument cannot hold, on every platform. The big prompt is
# built inside the call: passing it in REG_CALL would itself be one argument.
# Only Linux CI proves the kernel side; the byte counts below hold everywhere.
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\nprintf " stdin=%%s\\n" "$(wc -c | tr -d " ")"\n' > "$REG_TMP/count"
chmod +x "$REG_TMP/count"
mkdir "$REG_TMP/stage"
count_argv() { registry_argv AGY_CLI="$REG_TMP/count" CLAUDE_CLI="$REG_TMP/count" CODEX_CLI="$REG_TMP/count" TMPDIR="$REG_TMP/stage" "$@"; }
BIG='big=$(printf "%300000s" "" | tr " " x); '
REG_CALL="${BIG}registry_run claude \"\$big\""
assert_eq "$(count_argv)" '[-p] stdin=300001'
REG_CALL="${BIG}registry_run claude-write \"\$big\""
assert_eq "$(count_argv)" '[-p][--permission-mode][acceptEdits] stdin=300001'
REG_CALL="${BIG}registry_run codex \"\$big\""
assert_eq "$(count_argv)" '[exec][--skip-git-repo-check][-] stdin=300001'
REG_CALL="${BIG}registry_run codex-no-memories \"\$big\" /f"
assert_eq "$(count_argv)" '[exec][--skip-git-repo-check][-c][features.memories=false][--output-last-message][/f][-] stdin=300001'
REG_CALL="${BIG}registry_run_answer codex \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv)" "$(printf '[exec][--skip-git-repo-check][-] stdin=300001\nrc=0')"
# The prompt (plus the here-string's newline) is the CLI's stdin; bash leaves
# no temp file behind, and the caller's own stdin never reaches the CLI.
assert_eq "$(ls -A "$REG_TMP/stage")" ''
REG_CALL='echo CALLER-STDIN | registry_run claude P'
assert_eq "$(count_argv)" '[-p] stdin=2'
# A CLI that exits without reading the prompt keeps its own status, also
# under the caller's pipefail.
printf '#!/bin/sh\nexit "$STUB_RC"\n' > "$REG_TMP/early"
chmod +x "$REG_TMP/early"
REG_CALL="set -o pipefail; ${BIG}registry_run claude \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/early" STUB_RC=0)" 'rc=0'
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/early" STUB_RC=7)" 'rc=7'
# A child the CLI leaves holding stdin must not keep the call waiting (a
# `printf | cli` writer would block on a 300 KB prompt). The child waits at most 10 s
# for the release file and leaves a marker if it had to give up.
cat > "$REG_TMP/leaky" <<'STUB'
#!/bin/sh
( i=0
  while [ ! -e "$LEAK_RELEASE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$LEAK_RELEASE" ] || : > "$LEAK_RELEASE.gave-up" ) <&0 >/dev/null 2>&1 &
echo answered
STUB
chmod +x "$REG_TMP/leaky"
REG_CALL="${BIG}registry_run claude \"\$big\"; echo \"rc=\$?\"; ls \"\$LEAK_RELEASE.gave-up\" 2>/dev/null"
assert_eq "$(count_argv CLAUDE_CLI="$REG_TMP/leaky" LEAK_RELEASE="$REG_TMP/release")" "$(printf 'answered\nrc=0')"
: > "$REG_TMP/release"
# agy also accepts a prompt larger than one Linux argument through stdin.
REG_CALL="${BIG}registry_run agy \"\$big\"; echo \"rc=\$?\""
assert_eq "$(count_argv)" "$(printf '[--input-format][text][--output-format][text] stdin=300001\nrc=0')"
# The argv limit still applies to custom argv models. It counts bytes (NUL
# included, so the limit itself is refused), and the override moves it.
printf '%s\n' '{"models":{"argmodel":{"command":"x","env_command":"AGY_CLI","args":["-p","{prompt}"]}}}' > "$REG_TMP/argv.json"
REG_CALL='registry_run argmodel 0123456789abcdef; echo "rc=$?"'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/argv.json" REGISTRY_ARGV_MAX_BYTES=16 2>/dev/null)" 'rc=3'
REG_CALL='registry_run argmodel 0123456789abcde'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/argv.json" REGISTRY_ARGV_MAX_BYTES=16)" '[-p][0123456789abcde] stdin=0'
# #119: an argv template with no {prompt} would run the CLI without the prompt.
# It is refused, rc 3, before anything starts, whatever the prompt's size. A
# final-capable model is checked on the template a call selects: its unused
# args may lack {prompt}, until a call without a final file selects it.
printf '%s\n' '{"models":{
  "bare":{"command":"x","env_command":"AGY_CLI","args":["--ping"]},
  "finalonly":{"command":"x","env_command":"AGY_CLI","args":["--ping"],"final_args":["--final","{final}","{prompt}"]}}}' > "$REG_TMP/bare.json"
NO_PROMPT=' takes its prompt as an argument (prompt_via "argv") but its args template has no {prompt}, so the CLI would never see the prompt'
REG_CALL="${BIG}registry_run bare \"\$big\" </dev/null; echo \"rc=\$?\""
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/bare.json" 2>&1)" \
  "$(printf "registry: model 'bare'%s; add {prompt} where the prompt belongs, or use prompt_via \"stdin\"\nrc=3" "$NO_PROMPT")"
REG_CALL='registry_run finalonly P /f; echo "rc=$?"; registry_run finalonly P; echo "rc=$?"'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/bare.json" 2>&1)" \
  "$(printf "[--final][/f][P] stdin=0\nrc=0\nregistry: model 'finalonly'%s; nothing was started\nrc=3" "$NO_PROMPT")"
# registry_check_def is the whole rule. Shapes the runtime's preflight refuses
# are refused here too, and an empty final_args is never the running template.
check_def_rc() { bash -c '. "$1/dev-trio/lib/registry.sh"; registry_check_def m "$2" 2>/dev/null; echo $?' _ "$ROOT" "$1"; }
for def in '{"args":["{prompt}"]}' '{"prompt_via":"argv","args":["-p","{prompt}"]}' \
           '{"args":["{prompt}"],"final_args":[]}' '{"args":["-p"],"final_args":["{final}","{prompt}"]}' \
           '{"prompt_via":"stdin","args":["-p"]}'; do
  assert_eq "$(check_def_rc "$def")" 0
done
for def in '{"prompt_via":null,"args":["{prompt}"]}' '{"prompt_via":false,"args":["{prompt}"]}' \
           '{"args":["{prompt}"],"final_args":"x"}' '{"args":["{prompt}"],"final_args":null}' \
           '{"args":"-p {prompt}"}' '{"args":[1,"{prompt}"]}' '"invalid"' 'not json' \
           '{"args":["-p"],"final_args":[]}' '{"args":["{prompt}"],"final_args":["{final}"]}'; do
  assert_eq "$(check_def_rc "$def")" 3
done
# agent-team-models applies the same rule: add/edit refuse to save such a model,
# preset add checks what it saves, and doctor fails one written by hand.
for plugin in dev-trio debate-conductor; do
  printf '%s\n' '{"version":1,"models":{"mine":{"command":"x","args":["{prompt}"]}}}' > "$REG_TMP/atm.json"
  for cmd in "add z --command z --arg -p" "add z --command z --arg -p --final-arg {final}" \
             "edit mine --arg -p" "edit mine --argv --arg -p"; do
    rc=0
    # shellcheck disable=SC2086  # $cmd is a word list on purpose
    AGENT_TEAM_MODELS_CONFIG="$REG_TMP/atm.json" "$ROOT/$plugin/bin/agent-team-models.sh" $cmd \
      >/dev/null 2>"$REG_TMP/atm.err" || rc=$?
    assert_eq "$rc" 2
    assert_eq "$(grep -c 'template has no {prompt}' "$REG_TMP/atm.err")" 1
    assert_eq "$(jq -c .models "$REG_TMP/atm.json")" '{"mine":{"command":"x","args":["{prompt}"]}}'
  done
  AGENT_TEAM_MODELS_CONFIG="$REG_TMP/atm.json" "$ROOT/$plugin/bin/agent-team-models.sh" \
    add f --command f --arg -p --final-arg {final} --final-arg {prompt} >/dev/null 2>&1
  AGENT_TEAM_MODELS_CONFIG="$REG_TMP/atm.json" "$ROOT/$plugin/bin/agent-team-models.sh" \
    preset add kimi-code >/dev/null 2>&1
  assert_eq "$(jq -c '.models["kimi-code"].args' "$REG_TMP/atm.json")" '["-p","{prompt}"]'
  assert_eq "$(jq -c .models.f "$REG_TMP/atm.json")" '{"command":"f","args":["-p"],"final_args":["{final}","{prompt}"]}'
  rc=0
  AGENT_TEAM_MODELS_CONFIG="$REG_TMP/bare.json" "$ROOT/$plugin/bin/agent-team-models.sh" doctor \
    >"$REG_TMP/doctor.out" 2>&1 || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(grep -c "^  \[FAIL\] bare: model 'bare'$NO_PROMPT;" "$REG_TMP/doctor.out")" 1
  assert_eq "$(grep -c '^  \[FAIL\] finalonly' "$REG_TMP/doctor.out")" 0
done
REG_CALL='registry_run argmodel "한글ab"; echo "rc=$?"'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/argv.json" REGISTRY_ARGV_MAX_BYTES=8 2>/dev/null)" 'rc=3'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/argv.json" REGISTRY_ARGV_MAX_BYTES=9)" "$(printf '[-p][한글ab] stdin=0\nrc=0')"
# Configuration errors are refused before anything runs.
printf '%s\n' '{"models":{
  "leaky":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"stdin","args":["-p","{prompt}"]},
  "odd":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"file","args":["-p"]},
  "mine":{"command":"x","env_command":"CLAUDE_CLI","prompt_via":"stdin","args":["--print"]}}}' > "$REG_TMP/via.json"
REG_CALL='registry_run leaky P; echo "rc=$?"; registry_run odd P; echo "rc=$?"; registry_run mine P'
assert_eq "$(count_argv AGENT_TEAM_MODELS_CONFIG="$REG_TMP/via.json" 2>/dev/null)" "$(printf 'rc=3\nrc=3\n[--print] stdin=2')"
rm -rf "$REG_TMP"

smoke_done 70-registry-models
