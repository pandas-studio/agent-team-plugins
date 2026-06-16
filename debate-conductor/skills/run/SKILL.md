---
description: Run an N-round Generator(Antigravity) vs Critic(Codex) debate on a chosen topic, then summarise verdict and round-by-round moves. Topic can be a topics/ file reference OR free-form text. Use when the user wants to start, resume, or analyse a debate. Bootstrap must have run first.
disable-model-invocation: true
allowed-tools: Bash(debate.sh:*) Bash(ls:*) Bash(cat:*) Read Glob
argument-hint: [topic-or-text] [rounds]
---

# Run a debate

You are the **conductor**. Generator = Antigravity (middle pane), Critic = Codex (right pane). You orchestrate; you do not generate or critique.

## 1 · Resolve the topic from `$ARGUMENTS`

**Decision tree — apply in order, stop at first match**:

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

## 2 · Confirm rounds

Default 3. Honour `$ARGUMENTS[1]` if numeric. Ask the user only when the count is non-default and not explicit.

## 3 · Run the debate

Single Bash call (blocking, ~3–10 min depending on rounds). `debate.sh` is in the plugin's `bin/` and added to PATH while the plugin is active — call it bare (no absolute path).

For a **topics/ reference**:
```
debate.sh -n <ROUNDS> "$(cat topics/<file>.txt)"
```

For a **free-form topic**:
```
debate.sh -n <ROUNDS> "<the user's topic text, verbatim>"
```

Either form passes the topic string to `debate.sh` as a single argument — the engine doesn't care whether it came from a file or from chat. **Streaming output is already visible in the middle and right panes — do not duplicate it in the chat.** Just acknowledge that it's running and wait.

For role rotation experiments, add `--rotate` (model alternates each pair of rounds). For non-default model assignments, pass `--primary-gen=<model>` and/or `--primary-crit=<model>`.

## 4 · Summarise after completion

Transcripts live at `$PWD/.debate-conductor/log/<team>/latest-debate/round-*.md`. Use `Glob` to enumerate, `Read` to load each file. Then report:

- **Verdict** — the canonical 3-token line at the bottom of the last critic round: `Verdict: STRENGTHEN`, `Verdict: RECONSIDER`, or `Verdict: OVERTURN`. Quote it verbatim.
- **Move-by-move** — one bullet per round: `R1 (Gen, agy): <opening claim in 1 line>` → `R2 (Crit, codex): <main attack>` → `R3 (Gen, agy): <accept/reject/modify of each Blocker/Major>`. Keep each line under 25 words.
- **Two follow-up questions** worth asking next, e.g. "what if the Critic's Blocker #2 had been about X instead?" — concrete, not generic.

## 5 · Stay in the conversation

The user may follow up with "round 3 결정타가 뭐였어?", "5라운드로 다시", "rotate ON으로 한 번 더", "topic 2번도 돌려줘". Handle naturally — for re-runs, re-invoke this skill. For analysis, use `Read` on the relevant round file.

## Constraints

- **Do not call `ask-generator.sh` / `ask-critic.sh` directly.** `debate.sh` is the only entry point.
- **Do not paste round transcripts back to the chat in full.** The user has them in the panes; surface only the synthesis.
- **Do not edit transcripts.** The conductor is read-only after a debate completes.
