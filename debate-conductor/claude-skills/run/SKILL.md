---
description: Run a Generator vs Critic debate, prepare optional live viewers, and summarize verdict and round moves. Accept a topics/ reference or free-form text; bootstrap is optional.
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: '"${CLAUDE_PLUGIN_ROOT}/bin/announce-view.sh"'
allowed-tools: Bash(team-3pane.sh:*) Bash(run-debate.sh:*) Bash(open-view.sh:*) Bash(ls:*) Bash(cat:*) Read Glob Grep Write
argument-hint: "[--view=auto|tmux|none] [--open-view] [--terminal=auto|ghostty|terminal] [--gen=<model>] [--crit=<model>] [--rotate] [--until-converged] [topic-or-text] [rounds]"
---

# Run a debate

You are the **conductor**. You orchestrate; you do not generate or critique.
Read and follow the [viewing and dispatch contract](../../lib/view-workflow.md).
Consume its leading view/open controls before resolving the topic below.

## 1 · Parse role/model labels, mode flags, and topic from `$ARGUMENTS`

Strip any explicit CLI flags or natural-language role/model assignments from `$ARGUMENTS` before resolving the topic string:

- **Role / model assignment** (`agy` / `antigravity`, `claude`, `codex`, `kimi-code` / `kimi`, or any registered model id):
  - Flags: `--primary-gen=<model>` (or `--gen=<model>`), `--primary-crit=<model>` (or `--crit=<model>`).
  - Natural-language labels in the prompt (e.g. `gen=claude crit=codex`, `Generator: agy, Critic: kimi`, `claude vs codex로`): translate them into `--primary-gen=<model>` and/or `--primary-crit=<model>` flags on `debate.sh` and strip them from the topic text.
  - Defaults (when not specified): Generator = `agy`, Critic = `codex` (or `agy` if Generator is `codex`). Generator and Critic must differ.
- **Mode & round flags**:
  - `--rotate` (or "rotate ON"): alternate Generator and Critic models every two rounds.
  - `--until-converged` / `-c` (or "합의/수렴할 때까지", "until they agree"): stop early on `Verdict: STRENGTHEN`.
  - `-n <ROUNDS>` or a trailing bare integer (1–9): round count (default 3, or cap 6 with `--until-converged`).

**Topic decision tree — apply to the remaining argument text in order, stop at first match**:

1. **Empty** → list `$PWD/topics/*.txt` with each filename + first line of body, ask the user to pick (or to type a free-form topic). Do not proceed without a topic.

2. **Pure digit (1–9, no spaces)** → topic file number. Match `$PWD/topics/0N-*.txt`. Pass file content via `cat "$file"`.

3. **Single short token (no spaces, ≤15 chars)** → topic name fragment. Glob `$PWD/topics/*<fragment>*.txt`. If exactly one matches, use it. If multiple match, ask which. If none match, **fall through to step 4 with the token as free-form**.

4. **Anything else (contains a space OR longer than 15 chars)** → **free-form topic**. Use `$ARGUMENTS` (or its leading portion, minus any trailing rounds integer) **verbatim** as the topic. Pass the string directly to `debate.sh`. **Do NOT** look it up in `topics/`. **Do NOT** ask the user "should I create a topic file?". **Do NOT** suggest existing topics. Just run the debate.

   Examples that go straight to free-form (no questions asked):
   - `/debate-conductor:run 찍먹 vs 부먹` → topic = `"찍먹 vs 부먹"`, default 3 rounds
   - `/debate-conductor:run "FastAPI vs Django for new project" 5` → topic = `"FastAPI vs Django for new project"`, 5 rounds
   - `/debate-conductor:run Server Components 도입 시점` → topic = `"Server Components 도입 시점"`, default rounds

**Optional rounds**: if `$ARGUMENTS` ends with a bare integer (1–9) separated by space, use it as the round count and strip it from the topic. Default 3.

**Workspace `topics/` always takes priority** over the plugin's bundled examples (`${CLAUDE_SKILL_DIR}/../../topics/`). Only fall back to bundled if `$PWD/topics/` does not exist or is empty. Do not mix sources.

## 2 · Confirm rounds and prepare repository context (when needed)

- **Rounds**: Default 3 (or cap 6 with `--until-converged`). Honour explicit `-n` or trailing integer. Ask the user only when the count is non-default and ambiguous.
- **Repository context (`<topic>` + optional `context-file.md`)**: Generator and Critic run in **non-interactive headless mode**, where arbitrary shell search commands (`rg`, `find`, `grep`, compound commands) are auto-denied and abort the round.
  - If the topic is a general/self-contained question (e.g. `"FastAPI vs Django"`, `"찍먹 vs 부먹"`), pass it directly.
  - If the topic references **repository-internal entities** (e.g. `"Track 4"`, local roadmap/spec docs, module names, or current codebase constraints) that are not self-contained in the user's message, use `Glob` / `Grep` / `Read` to gather the relevant facts first. Put the **essential repository facts and constraints directly into the `<topic>` string** (because every round — both Generator and Critic — receives `Topic: $TOPIC`), and optionally pass a `[context-file.md]` (`--context=<file>`, written under `.debate-conductor/log/` or `$TMPDIR`) when Round 1's Generator needs longer supporting material (note: only Round 1's Generator reads `context-file.md`).

## 3 · Run the debate

Use separate stages from the shared contract: prepare with `team-3pane.sh`,
optionally open with `open-view.sh`, **show the viewing instructions in chat
before dispatch**, then run `run-debate.sh`. These scripts are on the plugin
PATH. Preserve the exact returned `context_file`. Bootstrap is optional.
Use a host timeout or background/poll mechanism for a 3–10 minute run.

**Required visible reply between setup and dispatch:** copy the actual attach
command (`ready-detached`) or **both actual tail commands** (`manual`, including
`--view=none`) into your chat reply, with the state. Tool output alone does not
count. Do not issue the dispatch Bash call before this reply. For `present`,
explicitly confirm the verified current-window viewers.
The helper's `user_message` is already formatted: if opening was requested,
call the opener first and send its message; otherwise send preparation's message
immediately. Never dispatch before that reply, even with `--view=none` or a
short run.

For a **topics/ reference**:
```
run-debate.sh --host=claude --context '<context_file>' -- -n <ROUNDS> [model/mode flags] "<read topic-file content as one argument>" [context-file.md]
```

For a **free-form topic**:
```
run-debate.sh --host=claude --context '<context_file>' -- -n <ROUNDS> [model/mode flags] "<the user's topic text, verbatim>" [context-file.md]
```

Pass the topic as one argument. Only `present` permits saying the current
panes are ready. `ready-detached` needs the emitted attach command in another
terminal; a background session alone is not visible. `manual` needs both tail
commands. Do not paste full transcripts into chat.

For role rotation experiments, add `--rotate` (model alternates each pair of rounds). For non-default model assignments, pass `--primary-gen=<model>` (`--gen=<model>`) and/or `--primary-crit=<model>` (`--crit=<model>`).

**Run until the debate converges** instead of a fixed count: add `--until-converged`. The debate then stops as soon as a Critic round returns `Verdict: STRENGTHEN`, and `-n` becomes the upper bound (a hard cap; default cap 6 if `-n` is omitted). Use this when the user asks to debate "합의/수렴할 때까지", "until they agree", or "keep going until the critic is satisfied". Reach for it instead of guessing a round count:

```
run-debate.sh --host=claude --context '<context_file>' -- --until-converged "<topic>" [context-file.md]       # cap 6
run-debate.sh --host=claude --context '<context_file>' -- --until-converged -n 8 "<topic>" [context-file.md]  # cap 8
```

A converged run prints `✓ Converged at round N`; hitting the cap without a STRENGTHEN prints a `⚠ Reached round cap` alert — surface whichever fired when you summarise.

## 4 · Summarise after completion

After exit 0, call `run-debate.sh --read-receipt --context '<context_file>'`.
Use only its validated `debate_dir`, including custom log roots; missing or
invalid receipt means incomplete. Use `Glob`/`Read` there, then report:

- **Verdict** — the canonical 3-token line at the bottom of the last *completed* critic round: `Verdict: STRENGTHEN`, `Verdict: RECONSIDER`, or `Verdict: OVERTURN` (note: `kimi-code` may prefix lines with `• ` or two spaces; strip the margin when quoting the canonical `Verdict: <TOKEN>`). Quote it verbatim. A critic round counts as completed only when `index.jsonl` contains an `end` record with `"rc":0` and `"role":"crit"` for it. Read the ledger, choose the highest such round, and read the transcript named by its `"file"` field. Ignore malformed lines and duplicate records. If no critic round completed, say so. Never infer completion from `.done` sidecars or transcript filenames; if the completed round has no unambiguous recorded filename, report that the verdict cannot be determined.
- **Move-by-move** — one bullet per round using the actual model recorded in the round marker / `index.jsonl`: `R1 (Gen, <model>): <opening claim in 1 line>` → `R2 (Crit, <model>): <main attack>` → `R3 (Gen, <model>): <accept/reject/modify of each Blocker/Major>`. Keep each line under 25 words.
- **Two follow-up questions** worth asking next, e.g. "what if the Critic's Blocker #2 had been about X instead?" — concrete, not generic.

## 5 · Stay in the conversation

For another run prepare a fresh context; for analysis read this invocation's
transcript. For **"뷰 열어줘" directly call `open-view.sh --context '<saved-file>'`**
under the standing shared contract. Do not implicitly invoke bootstrap or
start another debate. A new turn uses normal host permission checks.

## Constraints

- **Do not call `ask-generator.sh` / `ask-critic.sh` directly.** Dispatch only through `run-debate.sh`.
- **Do not paste round transcripts back to the chat in full.** Surface only the synthesis.
- **Do not edit transcripts.** The conductor is read-only after a debate completes.
