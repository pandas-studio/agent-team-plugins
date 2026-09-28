#!/usr/bin/env bash
# The live viewer (tail-role.sh) and debate.sh attempt records, signals and waits.
set -euo pipefail
# shellcheck source=tests/smoke-hardening/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_worker_cli_stubs

# ---- Live viewer (tail-role.sh) over per-role streams ----------------------
# debate.sh appends every attempt to debate-<TS>/stream-<role>.log; the viewer
# follows that one file. Every count below is over the viewer's whole capture,
# so a line shown twice or dropped fails, whatever the timing. Each test waits
# until the viewer has displayed content it can only have read from the stream
# before changing anything.
TAIL_PID=""
stop_tail() {
  [ -n "$TAIL_PID" ] || return 0
  kill -TERM "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""
}
register_cleanup stop_tail
# #169: viewer checks here fail intermittently under load (markers and
# "attempt failed" lines that should not be shown). When this part fails,
# dump every viewer capture and every stream record so the failure says how
# they got there. Cleanup entries run inside smoke_cleanup and see its $rc.
dump_viewer_state() {
  [ "$1" != 0 ] || return 0
  local f
  # A capture can end without a newline; each header starts its own line.
  for f in "$TMP"/view-*.out; do
    [ -e "$f" ] || continue
    printf -- '\n--- viewer capture %s:\n' "${f##*/}" >&2
    cat -v "$f" | tail -n 120 >&2 || true
  done
  for f in "$TMP"/view-log/*/debate-*/stream-*.log; do
    [ -e "$f" ] || continue
    printf -- '\n--- records and markers in %s:\n' "${f#"$TMP"/}" >&2
    grep -an -- 'debate-round' "$f" | cat -v >&2 || true
  done
}
# shellcheck disable=SC2016  # expanded when smoke_cleanup evals it
register_cleanup 'dump_viewer_state "$rc"'
# wait_count FILE PATTERN N: poll up to 15 s until PATTERN occurs on at least N
# lines of FILE (GNU tail can take seconds to notice a file).
wait_count() {
  local i=0
  while [ "$i" -lt 150 ]; do
    [ "$(grep -ac -- "$2" "$1" 2>/dev/null || true)" -ge "$3" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "FAIL: '$2' did not reach $3 in $1" >&2
  cat "$1" >&2
  return 1
}
count() { grep -ac -- "$2" "$1" || true; }
# view ROLE TEAM OUT [VAR=value...]: start a viewer on $TMP/view-log/TEAM.
view() {
  local role="$1" team="$2" out="$3"
  shift 3
  ( cd "$TMP" && exec env -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      DEBATE_LOG_DIR="$TMP/view-log" "$@" "$ROOT/debate-conductor/bin/tail-role.sh" "$role" \
      > "$out" 2>&1 </dev/null ) &
  TAIL_PID=$!
}
# debate_in TEAM GEN_STUB CRIT_STUB ARGS...: run debate.sh ARGS "smoke: TEAM"; prints its rc.
debate_in() {
  local team="$1" gen="$2" crit="$3" rc=0
  shift 3
  ( cd "$TMP" && env -u DEBATE_GENERATOR_MODEL -u DEBATE_CRITIC_MODEL -u DEBATE_PRIMARY_GEN \
      -u DEBATE_CONDUCTOR_PM_HOST TMUX='' AGENT_TEAM="$team" \
      AGENT_TEAM_MODELS_CONFIG="$TMP/no-models.json" DEBATE_LOG_DIR="$TMP/view-log" \
      GENERATOR_CLI="$TMP/worker-cli/$gen" CRITIC_CLI="$TMP/worker-cli/$crit" \
      "$ROOT/debate-conductor/bin/debate.sh" "$@" "smoke: $team" > /dev/null 2>&1 </dev/null ) || rc=$?
  echo "$rc"
}
debate_dir() { (cd "$TMP/view-log/$1/latest-debate" && pwd -P); }
cat > "$TMP/worker-cli/partial-fail" <<'STUB'
#!/bin/sh
i=0; while [ $i -lt 40 ]; do echo "OLD partial line $i of a failed attempt"; i=$((i+1)); done
exit 1
STUB
cat > "$TMP/worker-cli/long-answer" <<'STUB'
#!/bin/sh
echo "NEW-FIRST-LINE of the answer"
i=0; while [ $i -lt 60 ]; do echo "NEW body line $i padded padded padded padded padded"; i=$((i+1)); done
echo "NEW-LAST-LINE"
STUB
cat > "$TMP/worker-cli/tricky" <<'STUB'
#!/bin/sh
echo "TRICKY-START"
echo "<!-- debate-round: 2 crit x -->"
printf 'rs\036byte\n'
printf 'NO-NEWLINE-END'
STUB
chmod +x "$TMP/worker-cli/partial-fail" "$TMP/worker-cli/long-answer" "$TMP/worker-cli/tricky"

# 1. A round whose failed attempt left output is retried and more rounds are
#    added: the pane shows the failed attempt, the retry and the new round once
#    each. A viewer started afterwards shows the same.
assert_eq "$(debate_in retry partial-fail answer -n 2)" "1"
RETRY_DIR="$(debate_dir retry)"
view gen retry "$TMP/view-retry.out"
wait_count "$TMP/view-retry.out" 'OLD partial line 39' 1
assert_eq "$(debate_in retry long-answer answer --continue-from "$RETRY_DIR" -n 3)" "0"
wait_count "$TMP/view-retry.out" 'NEW-LAST-LINE' 2
sleep 1
stop_tail
view gen retry "$TMP/view-retry-late.out"
wait_count "$TMP/view-retry-late.out" 'NEW-LAST-LINE' 2
sleep 1
stop_tail
for out in "$TMP/view-retry.out" "$TMP/view-retry-late.out"; do
  assert_eq "$(count "$out" 'Round 1 · Generator')" "2"
  assert_eq "$(count "$out" 'Round 3 · Generator')" "1"
  assert_eq "$(count "$out" 'OLD partial line')" "40"
  assert_eq "$(count "$out" 'NEW-FIRST-LINE')" "2"
  assert_eq "$(count "$out" 'NEW body line')" "120"
  assert_eq "$(count "$out" 'NEW-LAST-LINE')" "2"
  assert_eq "$(count "$out" '<!-- debate-round')" "0"
  # Only the failed attempt is reported, with its exit status.
  assert_eq "$(count "$out" 'attempt failed')" "1"
  assert_eq "$(count "$out" 'attempt failed (rc=1)')" "1"
done
# Each attempt ends with a record carrying its status: round 1 failed (rc=1),
# its retry and round 3 completed. End records never reach round files.
RS="$(printf '\036')"
ID_RE='id=[0-9]+\.[0-9]+\.[0-9]+'
assert_eq "$(LC_ALL=C grep -ac "^${RS}<!-- debate-round-end: " "$RETRY_DIR/stream-gen.log")" "3"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 1 gen rc=1 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 1 gen rc=0 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
assert_eq "$(LC_ALL=C grep -acE "^${RS}<!-- debate-round-end: 3 gen rc=0 $ID_RE -->$" "$RETRY_DIR/stream-gen.log")" "1"
# attempt_pairs STREAM: every record in order as `R/id` (header) or `R/id/end`,
# with each distinct id replaced by its first-seen index, so a stream whose
# headers and end records pair up reads 1 1/end 2 2/end ... (#53).
attempt_pairs() {
  LC_ALL=C grep -a "^$(printf '\036')<!-- debate-round" "$1" | awk '
    { id = ""; for (i = 1; i <= NF; i++) if ($i ~ /^id=/) id = substr($i, 4)
      if (!(id in seen)) seen[id] = ++n
      printf "%s%s%s ", $3, "/" seen[id], ($2 == "debate-round-end:") ? "/end" : "" }
    END { print "" }'
}
# The failed round 1, its retry by /continue and round 3: three attempts, the
# retry of the same round and model under a new id.
assert_eq "$(attempt_pairs "$RETRY_DIR/stream-gen.log")" "1/1 1/1/end 1/2 1/2/end 3/3 3/3/end "
assert_eq "$(cat "$RETRY_DIR"/round-*.md | grep -ac 'debate-round-end' || true)" "0"

# 2. Critic round 2 fails twice instantly, then a continue retries it and adds
#    rounds 3-5: every attempt is shown once, including the successful retry.
assert_eq "$(debate_in crit-retry answer denied -n 2)" "5"
CRIT_DIR="$(debate_dir crit-retry)"
view crit crit-retry "$TMP/view-crit.out"
wait_count "$TMP/view-crit.out" 'Round 2 · Critic' 1
assert_eq "$(debate_in crit-retry answer denied --continue-from "$CRIT_DIR" -n 4)" "5"
assert_eq "$(debate_in crit-retry answer answer --continue-from "$CRIT_DIR" -n 4)" "0"
wait_count "$TMP/view-crit.out" 'Round 4 · Critic' 1
wait_count "$TMP/view-crit.out" 'Verdict: RECONSIDER' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-crit.out" 'Round 2 · Critic')" "3"
assert_eq "$(count "$TMP/view-crit.out" 'Round 4 · Critic')" "1"
assert_eq "$(count "$TMP/view-crit.out" 'Verdict: RECONSIDER')" "2"
assert_eq "$(count "$TMP/view-crit.out" 'attempt failed (rc=5)')" "2"
assert_eq "$(count "$TMP/view-crit.out" 'attempt failed')" "2"

# 3. Continuing a completed debate shows only the new rounds after the old ones.
assert_eq "$(debate_in done-continue answer answer -n 2)" "0"
DONE_DIR="$(debate_dir done-continue)"
view crit done-continue "$TMP/view-done.out"
wait_count "$TMP/view-done.out" 'Verdict: RECONSIDER' 1
assert_eq "$(debate_in done-continue answer answer --continue-from "$DONE_DIR" -n 2)" "0"
wait_count "$TMP/view-done.out" 'Verdict: RECONSIDER' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-done.out" 'Round 2 · Critic')" "1"
assert_eq "$(count "$TMP/view-done.out" 'Round 4 · Critic')" "1"
assert_eq "$(count "$TMP/view-done.out" 'attempt failed')" "0"

# 3b. A command feeding the model can fail too (here: the previous generator
#     round is missing when round 3 builds its prompt). The attempt must fail
#     with that status, record it, and not be marked done.
assert_eq "$(debate_in ctx-fail answer answer -n 2)" "0"
CTX_DIR="$(debate_dir ctx-fail)"
rm -f "$CTX_DIR/round-1-gen.md"
assert_eq "$(debate_in ctx-fail answer answer --continue-from "$CTX_DIR" -n 1)" "1"
assert_fail jq -e 'select(.t == "end" and .rc == 0 and .round == 3)' "$CTX_DIR/index.jsonl"
assert_eq "$(LC_ALL=C grep -ac -E "^$(printf '\036')<!-- debate-round-end: 3 gen rc=1 $ID_RE -->$" "$CTX_DIR/stream-gen.log")" "1"

# 3c. INT, TERM and HUP to the debate's process group, or to the debate.sh PID
#     alone (#48), stop the whole attempt within seconds: the model process is
#     gone, nothing keeps writing to the stream, the end record carries 130 /
#     143 / 129, the round is not marked done, and debate.sh dies from the
#     signal (so a bash caller stops too). The parent-INT run wraps debate.sh
#     in a bash loop like ralph-debate.sh's: Ctrl-C must stop the loop. SIGKILL
#     to the group cannot be trapped, but must still reach the model.
cat > "$TMP/worker-cli/slow-stream" <<'STUB'
#!/bin/sh
[ -z "${STUB_PID_FILE:-}" ] || echo $$ > "$STUB_PID_FILE"
i=0; while [ $i -lt 100 ]; do echo "SLOW line $i"; i=$((i+1)); sleep 0.1; done
STUB
chmod +x "$TMP/worker-cli/slow-stream"
for sig in INT TERM HUP parent-INT pid-INT pid-TERM pid-HUP KILL; do
  case "$sig" in
    INT|parent-INT|pid-INT) status=130; signum=2 ;;
    TERM|pid-TERM) status=143; signum=15 ;;
    HUP|pid-HUP) status=129; signum=1 ;;
    KILL) status=""; signum=9 ;;
  esac
  if [ "$sig" = KILL ]; then
    expected="rc=-9 fast=1 model=gone grew=0 ends=0  done=0 continued=0"
  else
    expected="rc=-$signum fast=1 model=gone grew=0 ends=1 <!-- debate-round-end: 1 gen rc=$status id=HEAD --> done=0 continued=0"
  fi
  assert_eq "$(python3 - "$ROOT" "$TMP" "$sig" <<'PYCASE'
import glob, json, os, re, signal, subprocess, sys, time
root, tmp, case = sys.argv[1:4]
sig = case.split("-")[-1]
team = f"cancel-{case}"
env = {k: v for k, v in os.environ.items()
       if k not in ("DEBATE_GENERATOR_MODEL", "DEBATE_CRITIC_MODEL", "DEBATE_PRIMARY_GEN", "DEBATE_CONDUCTOR_PM_HOST")}
pid_file = f"{tmp}/{team}.model-pid"
env.update(TMUX="", AGENT_TEAM=team, AGENT_TEAM_MODELS_CONFIG=f"{tmp}/no-models.json",
           DEBATE_LOG_DIR=f"{tmp}/view-log", GENERATOR_CLI=f"{tmp}/worker-cli/slow-stream",
           CRITIC_CLI=f"{tmp}/worker-cli/answer", STUB_PID_FILE=pid_file)
debate = [f"{root}/debate-conductor/bin/debate.sh", "-n", "2", f"smoke: {team}"]
marker = f"{tmp}/{team}.continued"
if case.startswith("parent-"):
    # A caller loop: runs the debate, then would go on to the next one.
    cmd = ["bash", "-c", 'for t in 1 2; do "$@" || true; echo continued >> "$MARKER"; done', "_", *debate]
    env["MARKER"] = marker
else:
    cmd = debate
p = subprocess.Popen(cmd, cwd=tmp, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
stream = None
for _ in range(150):
    found = glob.glob(f"{tmp}/view-log/{team}/debate-*/stream-gen.log")
    if found and "SLOW line 5" in open(found[0], errors="replace").read():
        stream = found[0]
        break
    time.sleep(0.1)
if stream is None:
    os.killpg(p.pid, signal.SIGKILL)
    print("stream never showed SLOW line 5")
    sys.exit(0)
model = int(open(pid_file).read())
started = time.time()
if case.startswith("pid-"):
    os.kill(p.pid, getattr(signal, "SIG" + sig))
else:
    os.killpg(p.pid, getattr(signal, "SIG" + sig))
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    rc = "timeout"
# The model has 10 s of output left; stopping it must not wait for that.
fast = int(time.time() - started < 3)
def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                          text=True).stdout.strip()[:1] not in ("", "Z")
for _ in range(30):
    if not alive(model):
        break
    time.sleep(0.1)
model_state = "alive" if alive(model) else "gone"
if model_state == "alive":
    os.kill(model, signal.SIGKILL)
size = os.path.getsize(stream)
time.sleep(1.5)
grew = int(os.path.getsize(stream) != size)
ends = [l for l in open(stream, errors="replace") if l.startswith("\x1e<!-- debate-round-end: ")]
rows = [json.loads(l) for l in open(os.path.join(os.path.dirname(stream), "index.jsonl")) if l.strip()]
done = int(any(r["t"] == "end" and r["round"] == 1 and r["rc"] == 0 for r in rows))
continued = int(os.path.exists(marker))
end = ends[0].rstrip(chr(10))[1:] if ends else ""
# The end record names the attempt its header started.
head = [l for l in open(stream, errors="replace") if l.startswith("\x1e<!-- debate-round: ")][0]
head_id = re.search(r" id=(\S+) -->", head).group(1)
end = end.replace(f" id={head_id} -->", " id=HEAD -->")
print(f"rc={rc} fast={fast} model={model_state} grew={grew} ends={len(ends)} {end} done={done} continued={continued}")
PYCASE
)" "$expected"
done

# 3d. A TERM to the debate.sh PID right after an attempt has completed (its
#     rc=0 end record is written), while the next one may be starting: the completed round stays done with rc=0, every
#     attempt header in a stream has exactly one end record, an interrupted
#     attempt records 143 and is not done, and no model keeps running.
assert_eq "$(python3 - "$ROOT" "$TMP" <<'PYRACE'
import glob, json, os, re, signal, subprocess, sys, time
root, tmp = sys.argv[1:3]
team = "cancel-after-done"
env = {k: v for k, v in os.environ.items()
       if k not in ("DEBATE_GENERATOR_MODEL", "DEBATE_CRITIC_MODEL", "DEBATE_PRIMARY_GEN", "DEBATE_CONDUCTOR_PM_HOST")}
pid_file = f"{tmp}/{team}.model-pid"
env.update(TMUX="", AGENT_TEAM=team, AGENT_TEAM_MODELS_CONFIG=f"{tmp}/no-models.json",
           DEBATE_LOG_DIR=f"{tmp}/view-log", GENERATOR_CLI=f"{tmp}/worker-cli/answer",
           CRITIC_CLI=f"{tmp}/worker-cli/slow-stream", STUB_PID_FILE=pid_file)
p = subprocess.Popen([f"{root}/debate-conductor/bin/debate.sh", "-n", "2", f"smoke: {team}"], cwd=tmp, env=env,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
# The stream end follows the authoritative ledger end.
for _ in range(1000):
    streams = glob.glob(f"{tmp}/view-log/{team}/debate-*/stream-gen.log")
    if streams and re.search(r"^\x1e<!-- debate-round-end: 1 gen rc=0 id=\S+ -->$",
                             open(streams[0], errors="replace").read(), re.M):
        break
    time.sleep(0.01)
else:
    os.killpg(p.pid, signal.SIGKILL)
    print("round 1 end record never appeared")
    sys.exit(0)
os.kill(p.pid, signal.SIGTERM)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    rc = "timeout"
time.sleep(0.5)
d = glob.glob(f"{tmp}/view-log/{team}/debate-*")[0]
def records(role, kind):
    # The id of an end record reads ID when it names the header before it, else BAD.
    out, head = [], None
    for l in open(f"{d}/stream-{role}.log", errors="replace"):
        m = re.match(r"\x1e(<!-- debate-round(-end)?: .* id=)(\S+) -->$", l.rstrip(chr(10)))
        if not m:
            continue
        if m.group(2) is None:
            head = m.group(3)
        if (m.group(2) or str()) == kind:
            out.append(m.group(1) + ("ID" if m.group(3) == head else "BAD") + " -->")
    return out
gen_ends = records("gen", "-end")
crit_heads = records("crit", "") if os.path.exists(f"{d}/stream-crit.log") else []
crit_ends = records("crit", "-end") if crit_heads else []
balanced = int(len(crit_heads) == len(crit_ends) and all(e.endswith(" rc=143 id=ID -->") for e in crit_ends))
model = "gone"
if os.path.exists(pid_file):
    pid = int(open(pid_file).read())
    try:
        os.kill(pid, 0)
        if subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()[:1] not in ("", "Z"):
            model = "alive"
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
rows = [json.loads(l) for l in open(f"{d}/index.jsonl") if l.strip()]
completed = {r["round"] for r in rows if r["t"] == "end" and r["rc"] == 0}
print(f"rc={rc} gen={gen_ends} r1done={int(1 in completed)} "
      f"crit-balanced={balanced} r2done={int(2 in completed)} model={model}")
PYRACE
)" "rc=-15 gen=['<!-- debate-round-end: 1 gen rc=0 id=ID -->'] r1done=1 crit-balanced=1 r2done=0 model=gone"

# 3e. The completion-boundary fault matrix now lives in
# tests/test_debate_conductor_hosts.py: it injects signals around status
# selection and ledger/stream ends, and failed ledger starts/ends, without
# relying on the retired sidecar touch syscall.

# 3f. record_attempt_end on its own: an end record already last in the stream
#     is not written again only when it is this attempt's (its id) and has one
#     numeric rc; a selected status survives a signal; a stream that cannot be
#     read is not written to.
record_end_case() {
  local last="$1" selected="$2" rc="$3" path="${4:-$PATH}"
  rm -rf "$TMP/rec" && mkdir -p "$TMP/rec"
  [ -z "$last" ] || printf '%s\n%s\n' "${REC_FIRST-$(printf '\036')<!-- debate-round: 1 gen agy id=7.1 -->}" "$last" > "$TMP/rec/stream-gen.log"
  PATH="$path" REC_SELECTED="$selected" REC_PUBLISHED="${REC_PUBLISHED-1}" bash -c '
    set -euo pipefail
    eval "$(awk '"'"'$0 == "stream_record() {" || $0 == "stream_attempt_end() {" || $0 == "record_attempt_end() {" { f = 1 } f { print } f && $0 == "}" { f = 0 }'"'"' "$1")"
    RS_BYTE="$(printf "\036")"; DEBATE_DIR="$2"
    CUR_ATTEMPT_ROUND=1; CUR_ATTEMPT_ROLE=gen; CUR_ATTEMPT_ID=7.1
    # No ledger here: this case drives the stream half only, and an attempt the
    # ledger never opened writes no end record to it (#44).
    CUR_ATTEMPT_FILE=round-1-gen.md; CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
    [ "$REC_SELECTED" = 0 ] || CUR_ATTEMPT_RC=0
    CUR_ATTEMPT_HEADER="<!-- debate-round: 1 gen agy id=7.1 -->"; CUR_ATTEMPT_PUBLISHED="$REC_PUBLISHED"
    record_attempt_end "$3"
    printf "role=[%s] " "$CUR_ATTEMPT_ROLE"
    if [ -e "$2/stream-gen.log" ]; then
      n="$(LC_ALL=C grep -ac "debate-round-end" "$2/stream-gen.log" || true)"
      printf "%s " "$n"
      sed -n "\$p" "$2/stream-gen.log" | LC_ALL=C tr -d "\036"
    else
      echo "no stream"
    fi
  ' _ "$ROOT/debate-conductor/bin/debate.sh" "$TMP/rec" "$rc"
}
RS_LINE="$(printf '\036')<!-- debate-round-end: 1 gen"
OWN_END="<!-- debate-round-end: 1 gen rc=143 id=7.1 -->"
assert_eq "$(record_end_case "$RS_LINE rc=143 id=7.1 -->" 0 143)" "role=[] 1 $OWN_END"
# Not this attempt's complete record: written.
for last in "rc=0garbage id=7.1" "rc= id=7.1" "id=7.1" "rc=0 rc=1 id=7.1" "rc=0 rc=x id=7.1" \
    "rc=x rc=0 id=7.1" "rc=0 id=7.0" "rc=0 id=17.1" "rc=0 id=7.11" "rc=0" "rc=0 id=7.1 id=7.1"; do
  assert_eq "$(record_end_case "$RS_LINE $last -->" 0 143)" "role=[] 2 $OWN_END"
done
assert_eq "$(record_end_case "$(printf '\036')<!-- debate-round-end: 2 gen rc=0 id=7.1 -->" 0 143)" "role=[] 2 $OWN_END"
assert_eq "$(record_end_case "partial output" 1 143)" "role=[] 1 <!-- debate-round-end: 1 gen rc=0 id=7.1 -->"
assert_eq "$(record_end_case "" 0 130)" "role=[] 1 <!-- debate-round-end: 1 gen rc=130 id=7.1 -->"
mkdir -p "$TMP/failing-tail"
printf '#!/bin/sh\nexit 1\n' > "$TMP/failing-tail/tail"
chmod +x "$TMP/failing-tail/tail"
assert_eq "$(record_end_case "partial output" 1 143 "$TMP/failing-tail:$PATH")" "role=[] 0 partial output"
# A signal inside begin_attempt (#52): the header may not be published yet. The
# record is written only when the stream ends with this attempt's exact header.
HDR_OWN="$(printf '\036')<!-- debate-round: 1 gen agy id=7.1 -->"
HDR_OLD="$(printf '\036')<!-- debate-round: 1 gen agy id=7.0 -->"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OLD" record_end_case "$HDR_OWN" 0 143)" "role=[] 1 $OWN_END"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OWN" record_end_case "$HDR_OLD" 0 143)" "role=[] 0 <!-- debate-round: 1 gen agy id=7.0 -->"
assert_eq "$(REC_PUBLISHED='' REC_FIRST="$HDR_OLD" record_end_case "$HDR_OWN output" 0 143)" "role=[] 0 <!-- debate-round: 1 gen agy id=7.1 --> output"
assert_eq "$(REC_PUBLISHED='' record_end_case "" 0 143)" "role=[] no stream"

# 3g. begin_attempt registers the attempt before publishing its header (#52).
#     The functions run in a shell whose TERM trap records the attempt, as
#     on_signal does; stream_header is wrapped to signal that shell right after
#     the header is written (after), right before (before), or to fail part way
#     through the write (fail). The stream starts with an earlier attempt's
#     header of the same round and model.
cat > "$TMP/ordering.sh" <<'ORDER'
set -euo pipefail
eval "$(awk '$0 ~ /^(stream_record|stream_header|begin_attempt|stream_attempt_end|record_attempt_end|index_append|index_start|index_end)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' "$1")"
# debate_index_file lives in lib/index.sh, which index_append calls.
# $3 is the ordering case; the lib path comes in as $4.
. "$4"
eval "real_$(declare -f stream_header)"
RS_BYTE="$(printf '\036')"; DEBATE_DIR="$2"; ATTEMPT_RUN=7; ATTEMPT_SEQ=0
CUR_ATTEMPT_ROUND=""; CUR_ATTEMPT_ROLE=""; CUR_ATTEMPT_ID=""
CUR_ATTEMPT_HEADER=""; CUR_ATTEMPT_PUBLISHED=""; CUR_ATTEMPT_FILE=""
CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
case "$3" in
  after) stream_header() { real_stream_header "$@"; kill -s TERM $$; } ;;
  before) stream_header() { kill -s TERM $$; real_stream_header "$@"; } ;;
  fail) stream_header() { printf '%s%s' "$RS_BYTE" "<!-- debate-round: 1 gen" >> "$DEBATE_DIR/stream-$1.log"; return 1; } ;;
esac
trap 'record_attempt_end 143; exit 143' TERM
trap 'record_attempt_end "$?"; : > "$DEBATE_DIR/exit-trap"' EXIT
begin_attempt 1 gen agy "$DEBATE_DIR/round-1-gen.md"
echo "begin_attempt returned" >&2
ORDER
ordering_case() {
  local rc=0
  rm -rf "$TMP/ord" && mkdir -p "$TMP/ord"
  printf '%s\n' "$(printf '\036')<!-- debate-round: 1 gen agy id=7.0 -->" > "$TMP/ord/stream-gen.log"
  /bin/bash "$TMP/ordering.sh" "$ROOT/debate-conductor/bin/debate.sh" "$TMP/ord" "$1" \
    "$ROOT/debate-conductor/lib/index.sh" 2>/dev/null || rc=$?
  printf 'rc=%s exit-trap=%s records=%s\n' "$rc" "$([ -e "$TMP/ord/exit-trap" ] && echo 1 || echo 0)" \
    "$(LC_ALL=C grep -a "^$(printf '\036')" "$TMP/ord/stream-gen.log" | LC_ALL=C tr -d '\036' | tr '\n' '|')"
}
assert_eq "$(ordering_case after)" "rc=143 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|<!-- debate-round: 1 gen agy id=7.1 -->|<!-- debate-round-end: 1 gen rc=143 id=7.1 -->|"
assert_eq "$(ordering_case before)" "rc=143 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|"
assert_eq "$(ordering_case fail)" "rc=1 exit-trap=1 records=<!-- debate-round: 1 gen agy id=7.0 -->|<!-- debate-round: 1 gen|"

# 3i. The stream record and the ledger record of one attempt always carry the
#     same status (#44). The two writes are independent, so a signal can land
#     between them: without a decision that outlives the first write, the
#     re-entry normalises again and the records split (measured: stream rc=9,
#     ledger rc=143). index_end is wrapped to signal right after it writes,
#     before the stream end, which is exactly that window.
cat > "$TMP/rcsplit.sh" <<'RCSPLIT'
set -euo pipefail
eval "$(awk '$0 ~ /^(stream_record|stream_header|stream_attempt_end|record_attempt_end|index_append|index_start|index_end)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' "$1")"
. "$3"
eval "real_$(declare -f index_end)"
DEBATE_DIR="$2"; RS_BYTE="$(printf '\036')"
CUR_ATTEMPT_ROUND=1; CUR_ATTEMPT_ROLE=gen; CUR_ATTEMPT_ID=7.1
CUR_ATTEMPT_FILE=round-1-gen.md
CUR_ATTEMPT_HEADER="<!-- debate-round: 1 gen agy id=7.1 -->"; CUR_ATTEMPT_PUBLISHED=1
CUR_ATTEMPT_INDEXED=""; CUR_ATTEMPT_RC=""
printf '%s%s\n' "$RS_BYTE" "$CUR_ATTEMPT_HEADER" > "$2/stream-gen.log"
index_start agy && CUR_ATTEMPT_INDEXED=1
[ "$5" = 0 ] || CUR_ATTEMPT_RC=0
# Signal once, not on every call: the trap re-enters record_attempt_end, which
# calls this again, and bash 5 runs the trap recursively where bash 3.2 blocks
# the signal for the duration of its own handler — an unconditional kill here
# looped until the shell died on Linux and passed on macOS.
signalled=""
index_end() {
  real_index_end "$@"
  [ -n "$signalled" ] || { signalled=1; kill -s TERM $$; }
}
trap 'record_attempt_end 143' TERM
record_attempt_end "$4"
RCSPLIT
rcsplit_case() {
  rm -rf "$TMP/rcsplit" && mkdir -p "$TMP/rcsplit"
  /bin/bash "$TMP/rcsplit.sh" "$ROOT/debate-conductor/bin/debate.sh" "$TMP/rcsplit" \
    "$ROOT/debate-conductor/lib/index.sh" "$1" "$2" >/dev/null 2>&1 || true
  printf 'stream=%s ledger=%s\n' \
    "$(LC_ALL=C grep -ao 'rc=[0-9]*' "$TMP/rcsplit/stream-gen.log" | tr '\n' ' ')" \
    "$(jq -r 'select(.t == "end") | "rc=\(.rc)"' "$TMP/rcsplit/index.jsonl" | tr '\n' ' ')"
}
assert_eq "$(rcsplit_case 9 0)" "stream=rc=9  ledger=rc=9 "
assert_eq "$(rcsplit_case 143 0)" "stream=rc=143  ledger=rc=143 "
# Success selected: both records say 0, and the re-entry keeps saying 0.
assert_eq "$(rcsplit_case 9 1)" "stream=rc=0  ledger=rc=0 "

# 3h. wait_attempt waits for an attempt in short steps (#57). bash 3.2's `wait`
#     can miss a trapped signal that arrives as it starts and then run the trap
#     only when the child exits, so debate.sh outlived a TERM by a whole attempt.
#     The helper still returns the attempt's status, so errexit is unchanged, and
#     stop_attempt cleans up the step as well as the attempt.
# The functions are extracted once: 400 trials re-running awk over debate.sh cost
# ~20 s of the suite.
awk '$0 ~ /^(attempt_running|wait_attempt|stop_attempt)\(\) \{$/ { f = 1 } f { print } f && $0 == "}" { f = 0 }' \
  "$ROOT/debate-conductor/bin/debate.sh" > "$TMP/wait57-funcs.sh"
assert_eq "$(grep -c '^wait_attempt() {\|^attempt_running() {\|^stop_attempt() {' "$TMP/wait57-funcs.sh")" "3"
# The gate is extracted too, so the assertion below reads debate.sh's own value
# rather than a copy of its condition that could drift from it (#66).
awk '/^if \[ -z "\$\{ATTEMPT_WAIT_POLL/ { f = 1 } f { print } f && $0 == "fi" { exit }' \
  "$ROOT/debate-conductor/bin/debate.sh" > "$TMP/wait57-gate.sh"
assert_eq "$(grep -c 'BASH_VERSINFO' "$TMP/wait57-gate.sh")" "1"
cat > "$TMP/wait57.sh" <<'WAIT57'
set -euo pipefail
. "$1"
ATTEMPT_WAIT_STEP=0.2
# Both paths of the #66 gate are driven from here; 1 keeps the pre-gate behavior
# for the cases written against the stepped wait.
ATTEMPT_WAIT_POLL="${ATTEMPT_WAIT_POLL:-1}"
case "$2" in
  status0)  ( exit 0 ) & wait_attempt "$!"; echo "rc=$?" ;;
  status7)  ( exit 7 ) & rc=0; wait_attempt "$!" || rc=$?; echo "rc=$rc" ;;
  reaped)   ( exit 5 ) & pid=$!; sleep 0.5; rc=0; wait_attempt "$pid" || rc=$?; echo "rc=$rc" ;;
  errexit)  ( exit 7 ) & wait_attempt "$!"; echo "not reached" ;;
  race)     trap 'exit 143' TERM
            ( sleep 3 ) <&0 &
            pid=$!
            kill -s TERM $$ &
            wait_attempt "$pid"
            exit 0 ;;
  cleanup)  trap 'stop_attempt; exit 143' TERM
            ( sleep 30 ) <&0 &
            wait_attempt "$!" ;;
  ignore)   rm -f "$1.ready"
            ( trap '' TERM; : > "$1.ready"
              i=0; while [ $i -lt 80 ]; do sleep 0.1; i=$((i+1)); done ) <&0 &
            pid=$!
            i=0
            while [ ! -f "$1.ready" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
            stop_attempt
            if kill -0 "$pid" 2>/dev/null; then echo "bounded=1"; else echo "bounded=0"; fi
            # Reap it here, stderr closed: left to exit, bash may report the
            # killed job ("Killed: 9") into wait57's captured output (#169).
            { kill -9 "$pid" && wait "$pid"; } 2>/dev/null || true ;;
esac
WAIT57
wait57() { /bin/bash "$TMP/wait57.sh" "$TMP/wait57-funcs.sh" "$1" 2>&1; }
# Both sides of the gate must return the attempt's status and keep errexit, so
# every one of these runs twice (#66).
for POLL in 1 0; do
  export ATTEMPT_WAIT_POLL="$POLL"
  assert_eq "poll=$POLL $(wait57 status0)" "poll=$POLL rc=0"
  assert_eq "poll=$POLL $(wait57 status7)" "poll=$POLL rc=7"
  # reaped runs in the python driver below, with a timeout: a liveness regression
  # would hang it here instead of failing.
  assert_eq "poll=$POLL $(wait57 errexit; echo "exit=$?")" "poll=$POLL exit=7"
done
unset ATTEMPT_WAIT_POLL
# Cleanup and bounded latency, timed outside the shell under test: the parent
# sends TERM only once a sleep step is actually running, and inspects the
# process group before its own safety-net kill.
assert_eq "$(python3 - "$ROOT" "$TMP" <<'PYWAIT'
import os, platform, signal, subprocess, sys, time
root, tmp = sys.argv[1:3]
def trial(case, timeout=10):
    p = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", case],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        out, rc = "", "timeout"
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    return out.strip(), rc
def group(pid):
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if l.split()[1] == str(pid)]
# 1. TERM while a step is running: the trap runs stop_attempt, and nothing of the
#    attempt or the step is left behind.
p = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", "cleanup"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
stepped = False
for _ in range(200):
    if any(" sleep 0.2" in l for l in group(p.pid)):
        stepped = True
        break
    time.sleep(0.05)
os.kill(p.pid, signal.SIGTERM)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    rc = "timeout"
time.sleep(0.3)
left = len(group(p.pid))
try:
    os.killpg(p.pid, signal.SIGKILL)
except (ProcessLookupError, PermissionError):
    pass
# 2. An attempt that exited and was reaped before the call: its status, no hang.
reaped = trial("reaped", timeout=10)[0]
# 3. Isolated trials: a TERM racing the start of the wait must never delay the exit
#    by the length of the attempt. Measured 5/400 late with a plain `wait`. The race
#    is a bash 3.2 one (0/300 on 5.2), and a loaded Linux runner could exceed the
#    threshold without it, so only macOS asserts latency.
#    The exit status is asserted on both, and Linux runs the larger batch: it is
#    where #66 lives, a trial costs ~1 ms, and 25 trials missed the pre-gate rate
#    four runs out of five. 500 is ~0.6 s.
#    The stderr of a trial is kept rather than dropped: #66 cost two days because
#    the failure printed only a set of exit codes, while the cause was one line on
#    the stderr this loop used to send to DEVNULL. No apostrophes in this block:
#    bash 3.2 parses the heredoc inside the command substitution around it.
strict = platform.system() == "Darwin"
# Which side of the gate this bash uses, and whether debate.sh agrees. The batch
# runs the path that is actually configured: the stepped poll is only reachable
# on bash 3.x, and forcing it on bash 5 would reintroduce the #66 window the gate
# exists to avoid — 0.10% a trial, which over a batch this size is most runs.
major = int(subprocess.run(["/bin/bash", "-c", "echo ${BASH_VERSINFO[0]}"],
                           capture_output=True, text=True).stdout.strip())
want = "1" if major <= 3 else "0"
gate = subprocess.run(["/bin/bash", "-c", f". {tmp}/wait57-gate.sh; echo $ATTEMPT_WAIT_POLL"],
                      capture_output=True, text=True).stdout.strip()
gate_ok = int(gate == want)
env = dict(os.environ, ATTEMPT_WAIT_POLL=want)
late = 0
codes = set()
errs = set()
for _ in range(400 if strict else 500):
    t0 = time.monotonic()
    with open(f"{tmp}/race-err.txt", "w") as eh:
        q = subprocess.Popen(["/bin/bash", f"{tmp}/wait57.sh", f"{tmp}/wait57-funcs.sh", "race"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=eh,
                             start_new_session=True, env=env)
        try:
            code = q.wait(timeout=10)
        except subprocess.TimeoutExpired:
            code = "timeout"
    codes.add(code)
    if str(code) != "143":
        lines = open(f"{tmp}/race-err.txt").read().strip().splitlines()
        errs.add(lines[0][:120] if lines else "(no stderr)")
    if strict and time.monotonic() - t0 >= 1.5:
        late += 1
    try:
        os.killpg(q.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
print(f"stepped={int(stepped)} rc={rc} left={left} reaped=[{reaped}] "
      f"codes={sorted(str(c) for c in codes)} late={late} err={sorted(errs)} gate_ok={gate_ok}")
PYWAIT
)" "stepped=1 rc=143 left=0 reaped=[rc=5] codes=['143'] late=0 err=[] gate_ok=1"

# 3b. stop_attempt is bounded even when a root ignores TERM (#66): it returns
#     while that root is still running, rather than waiting out its lifetime with
#     record_attempt_end and release_lock behind it. Asserted as "stop_attempt
#     returned before the root did", not as a wall-clock threshold: the budget is
#     20 sleeps of 0.1 s plus a ps and a grep each, which a loaded runner stretches
#     — the suite already carries two load-sensitive failures. The child publishes
#     readiness after installing its TERM-ignore trap, so it cannot be stopped
#     before the trap exists and fail this for the wrong reason.
assert_eq "$(wait57 ignore)" "bounded=1"

# 4. Model text cannot draw a banner or move text: a quoted marker is dropped,
#    \x1e is removed, and an answer without a final newline does not swallow the
#    next attempt's header.
assert_eq "$(debate_in tricky tricky answer -n 3)" "0"
TRICKY_DIR="$(debate_dir tricky)"
view gen tricky "$TMP/view-tricky.out"
wait_count "$TMP/view-tricky.out" 'Round 3 · Generator' 1
wait_count "$TMP/view-tricky.out" 'NO-NEWLINE-END' 2
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-tricky.out" 'Round 1 · Generator')" "1"
assert_eq "$(count "$TMP/view-tricky.out" 'Round 3 · Generator')" "1"
assert_eq "$(count "$TMP/view-tricky.out" 'TRICKY-START')" "2"
assert_eq "$(count "$TMP/view-tricky.out" '<!-- debate-round')" "0" || {
  cat "$TMP/view-tricky.out" >&2
  exit 1
}
assert_eq "$(count "$TMP/view-tricky.out" 'rsbyte')" "2"
# Only debate.sh's records carry \x1e (two headers, two end records), each at the
# start of a line: the end record after the unterminated answer starts its own.
assert_eq "$(LC_ALL=C tr -cd '\036' < "$TRICKY_DIR/stream-gen.log" | wc -c | tr -d ' ')" "4"
assert_eq "$(LC_ALL=C grep -ac "^$(printf '\036')" "$TRICKY_DIR/stream-gen.log")" "4"
assert_eq "$(LC_ALL=C grep -ac -E "^$(printf '\036')<!-- debate-round-end: [13] gen rc=0 $ID_RE -->$" "$TRICKY_DIR/stream-gen.log")" "2"
# Round files and the critic stream are untouched by the generator's quoted marker.
assert_eq "$(LC_ALL=C tr -cd '\036' < "$TRICKY_DIR/round-1-gen.md" | wc -c | tr -d ' ')" "0"
assert_eq "$(head -1 "$TRICKY_DIR/round-1-gen.md")" "<!-- debate-round: 1 gen agy -->"
assert_eq "$(LC_ALL=C grep -ac "^$(printf '\036')" "$TRICKY_DIR/stream-crit.log")" "2"

# 4b. Records carry tokens after the role (#53). One stream mixing records
#     without ids, with ids, with unknown tokens and malformed end records: the
#     viewer draws each header, reports each failed attempt once, and drops
#     only framed lines it cannot read. A model line that merely looks like a
#     marker with extra words is model text and stays visible.
CRAFT_DIR="$TMP/view-log/crafted/debate-20260101-000002"
mkdir -p "$CRAFT_DIR"
ln -s debate-20260101-000002 "$TMP/view-log/crafted/latest-debate"
{
  printf '\036<!-- debate-round: 1 gen agy -->\nLEGACY-BODY\n\036<!-- debate-round-end: 1 gen rc=3 -->\n'
  printf '\036<!-- debate-round: 1 gen agy id=9.1 -->\nID-BODY\n\036<!-- debate-round-end: 1 gen rc=4 id=9.1 -->\n'
  printf '\036<!-- debate-round: 2 gen codex id=9.2 future=x -->\nFUTURE-BODY\n'
  printf '\036<!-- debate-round-end: 2 gen id=9.2 rc=6 future=x -->\n'
  printf '\036<!-- debate-round: 3 gen id=9.3 -->\nNO-MODEL-BODY\n'
  printf '<!-- debate-round: 2 crit example extra words -->\n'
  printf '<!-- debate-round: 2 crit x -->\n'
  for bad in "id=9.3" "rc= id=9.3" "rc=1x id=9.3" "rc=7 rc=8 id=9.3" "rc=7 rc=x id=9.3" "rc=x rc=7 id=9.3"; do
    printf '\036<!-- debate-round-end: 3 gen %s -->\n' "$bad"
  done
  printf '\036<!-- debate-round-end: 3 gen rc=0 id=9.3 -->\nCRAFT-END\n'
} > "$CRAFT_DIR/stream-gen.log"
# check_crafted OUT [VAR=value...]: view the crafted stream and check it.
check_crafted() {
  local out="$1" body
  : > "$out"
  view gen crafted "$@"
  wait_count "$out" 'CRAFT-END' 1
  stop_tail
  assert_eq "$(count "$out" 'Round 1 · Generator · agy')" "2"
  assert_eq "$(count "$out" 'Round 2 · Generator · codex')" "1"
  assert_eq "$(count "$out" 'Round 3 · Generator')" "1"
  assert_eq "$(count "$out" 'Round 3 · Generator · ')" "0"
  assert_eq "$(grep -ao 'attempt failed (rc=[^)]*)' "$out" | tr '\n' ' ')" \
    "attempt failed (rc=3) attempt failed (rc=4) attempt failed (rc=6) "
  # A signalled viewer must not append Bash's job notice with the awk source.
  assert_eq "$(count "$out" 'Terminated: ')" "0"
  assert_eq "$(count "$out" 'example extra words')" "1"
  assert_eq "$(count "$out" '2 crit x')" "0"
  assert_eq "$(count "$out" 'id=')" "0"
  assert_eq "$(LC_ALL=C grep -ac "$(printf '\036')" "$out" || true)" "0"
  for body in LEGACY-BODY ID-BODY FUTURE-BODY NO-MODEL-BODY; do
    assert_eq "$(count "$out" "$body")" "1"
  done
}
check_crafted "$TMP/view-crafted.out"

# 5. A new debate: the pane stops the old one before announcing the new one, and
#    shows each debate's content exactly once.
assert_eq "$(debate_in retarget partial-fail answer -n 2)" "1"
view gen retarget "$TMP/view-retarget.out"
wait_count "$TMP/view-retarget.out" 'OLD partial line 39' 1
sleep 1.1  # a new debate-<TS> directory needs a different second
assert_eq "$(debate_in retarget long-answer answer -n 2)" "0"
wait_count "$TMP/view-retarget.out" 'NEW-LAST-LINE' 1
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-retarget.out" 'new debate run detected')" "1"
assert_eq "$(count "$TMP/view-retarget.out" 'OLD partial line')" "40"
assert_eq "$(count "$TMP/view-retarget.out" 'NEW body line')" "60"
assert_eq "$(sed -n '/new debate run detected/,$p' "$TMP/view-retarget.out" | grep -ac 'OLD partial line' || true)" "0"
assert_eq "$(sed -n '1,/new debate run detected/p' "$TMP/view-retarget.out" | grep -ac 'NEW body line' || true)" "0"

# 6. A debate created before streams existed: the pane says so once, then shows
#    the rounds a continue adds.
assert_eq "$(debate_in legacy answer answer -n 2)" "0"
LEGACY_DIR="$(debate_dir legacy)"
rm -f "$LEGACY_DIR/stream-gen.log" "$LEGACY_DIR/stream-crit.log"
view crit legacy "$TMP/view-legacy.out"
wait_count "$TMP/view-legacy.out" 'predates live streams' 1
assert_eq "$(debate_in legacy answer answer --continue-from "$LEGACY_DIR" -n 2)" "0"
wait_count "$TMP/view-legacy.out" 'Round 4 · Critic' 1
sleep 1
stop_tail
assert_eq "$(count "$TMP/view-legacy.out" 'predates live streams')" "1"
assert_eq "$(count "$TMP/view-legacy.out" 'Round 2 · Critic')" "0"
assert_eq "$(count "$TMP/view-legacy.out" 'Round 4 · Critic')" "1"
# The note also appears when the round files show up after the viewer started.
mkdir -p "$TMP/view-log/legacy-late/debate-20260101-000000"
ln -s debate-20260101-000000 "$TMP/view-log/legacy-late/latest-debate"
view crit legacy-late "$TMP/view-legacy-late.out"
sleep 1.5
cp "$LEGACY_DIR/round-2-crit.md" "$TMP/view-log/legacy-late/debate-20260101-000000/"
wait_count "$TMP/view-legacy-late.out" 'predates live streams' 1
stop_tail
assert_eq "$(count "$TMP/view-legacy-late.out" 'predates live streams')" "1"

# 6b. If the follower dies (its tail killed), the pane says so and stops rather
#     than replaying the stream and showing everything twice.
view crit done-continue "$TMP/view-killed.out"
wait_count "$TMP/view-killed.out" 'Round 4 · Critic' 1
KILLED_STREAM="$DONE_DIR/stream-crit.log"
i=0
while [ "$i" -lt 50 ] && ! pgrep -f "tail -n [+]1 -F $KILLED_STREAM" >/dev/null; do sleep 0.1; i=$((i + 1)); done
pkill -f "tail -n [+]1 -F $KILLED_STREAM"
wait_count "$TMP/view-killed.out" 'stream follower stopped' 1
i=0
while [ "$i" -lt 50 ] && kill -0 "$TAIL_PID" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
assert_fail kill -0 "$TAIL_PID"
TAIL_PID=""
assert_eq "$(count "$TMP/view-killed.out" 'Round 2 · Critic')" "1"
assert_eq "$(count "$TMP/view-killed.out" 'Round 4 · Critic')" "1"

# 7. mawk reads a pipe in blocks unless run with -W interactive. The fake mawk
#    below identifies itself like mawk and, without -W interactive, holds all
#    input until EOF, which `tail -F` never sends. When the host awk is itself
#    mawk, the pass-through keeps -W interactive.
REAL_AWK="$(command -v awk)"
REAL_AWK_STREAM=""
case "$("$REAL_AWK" -W version 2>&1 </dev/null || true)" in mawk*) REAL_AWK_STREAM="-W interactive" ;; esac
mkdir -p "$TMP/fake-mawk"
cat > "$TMP/fake-mawk/awk" <<STUB
#!/bin/sh
if [ "\$1" = -W ] && [ "\$2" = version ]; then echo "mawk 1.3.4 fake"; exit 0; fi
if [ "\$1" = -W ] && [ "\$2" = interactive ]; then shift 2; exec "$REAL_AWK" $REAL_AWK_STREAM "\$@"; fi
held="$TMP/fake-mawk/held.\$\$"
cat > "\$held"
exec "$REAL_AWK" "\$@" "\$held"
STUB
chmod +x "$TMP/fake-mawk/awk"
view crit done-continue "$TMP/view-mawk.out" PATH="$TMP/fake-mawk:$PATH"
wait_count "$TMP/view-mawk.out" 'Round 4 · Critic' 1
stop_tail
assert_eq "$(count "$TMP/view-mawk.out" 'Round 2 · Critic')" "1"
check_crafted "$TMP/view-crafted-fake-mawk.out" PATH="$TMP/fake-mawk:$PATH"
# The fake only checks line-by-line reading; the parsing runs on the host awk.
# Parse the crafted stream with each other awk installed too.
for other_awk in mawk gawk nawk; do
  other_path="$(command -v "$other_awk" 2>/dev/null || true)"
  [ -n "$other_path" ] || continue
  mkdir -p "$TMP/awk-$other_awk"
  ln -sf "$other_path" "$TMP/awk-$other_awk/awk"
  check_crafted "$TMP/view-crafted-$other_awk.out" PATH="$TMP/awk-$other_awk:$PATH"
done

# 8. A short first line reaches the stream while the model is still running
#    (sed must not block-buffer; #42).
cat > "$TMP/worker-cli/held-open" <<STUB
#!/bin/sh
echo "EARLY-LINE"
# Also stop when the fixture is gone, so a failed assertion cannot leave it running.
while [ ! -e "$TMP/held-open.release" ] && [ -d "$TMP" ]; do sleep 0.1; done
echo "LATE-LINE"
STUB
chmod +x "$TMP/worker-cli/held-open"
rm -f "$TMP/held-open.release"
( debate_in held held-open answer -n 1 > "$TMP/held-open.rc" ) &
HELD_PID=$!
i=0
while [ "$i" -lt 100 ] && ! grep -aq 'EARLY-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
assert_eq "$(grep -ac 'EARLY-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null || true)" "1"
assert_eq "$(grep -ac 'LATE-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log" 2>/dev/null || true)" "0"
: > "$TMP/held-open.release"
wait "$HELD_PID"
assert_eq "$(cat "$TMP/held-open.rc")" "0"
assert_eq "$(grep -ac 'LATE-LINE' "$TMP/view-log/held/latest-debate/stream-gen.log")" "1"

smoke_done 60-viewer
