---
description: Extend the most recent debate by N more rounds in the same `debate-<TS>/` dir. Round numbering continues; tail panes pick up new rounds without retarget. Reads topic from prior debate's topic.txt.
disable-model-invocation: true
allowed-tools: Bash(debate.sh:*) Bash(ls:*) Bash(cat:*) Bash(readlink:*) Read Glob
argument-hint: [extra-rounds]
---

# Continue a debate

Extend the most recent debate in the workspace by `$ARGUMENTS` more rounds (default 2). New rounds (N+1, N+2, ...) are appended to the existing `debate-<TS>/` directory, where N is the last *completed* round. If round 1 itself never completed (for example its generator call failed), `debate.sh` reports "resuming from round 1" and runs rounds 1..E, reusing the round-1 context saved in `context.md`. The middle/right panes follow appended per-role streams. Continuing the current directory leaves the selection sequence unchanged, so the `── new debate run detected — following it ──` separator does **not** fire.

## 1 · Resolve the prior debate

- Glob `$PWD/.debate-conductor/log/*/latest-debate` (one symlink per team).
- **Exactly one match** → use it.
- **Multiple matches** → list each as `<team-name>: <real dir>` and ask which to continue.
- **No matches** → tell the user: "No prior debate found in this workspace. Run `/debate-conductor:run` first."

You may pass the `latest-debate` symlink directly to `debate.sh --continue-from` — the script does `cd && pwd -P` internally to canonicalise. If you need the real path explicitly (e.g. for chat output), use a portable resolver since macOS `readlink` lacks `-f`:

```
REAL=$(cd "$LATEST" && pwd -P)
```

## 2 · Resolve the topic

- Read `<real-dir>/topic.txt`. If present, use its contents as the topic.
- If absent (older debate created before `topic.txt` was added) → ask the user to re-state the original topic; pass that string.

## 3 · Resolve `extra-rounds`

- `$ARGUMENTS` is a single integer (1–9) → that many more rounds.
- `$ARGUMENTS` is empty → default `2`.
- Anything else → ask for a number.

## 4 · Run the extension

Single Bash call, blocking. `debate.sh` is on PATH while the plugin is active.
It reuses the debate directory's saved model pair and any saved rotation unless
this invocation passes explicit model flags/env vars. Start a fresh debate to
change model pairs inside rotation or to change whether rotation is enabled.

```
debate.sh --continue-from <real-dir> -n <EXTRA> "<topic>"
```

Streaming output is already visible in the middle/right panes — do not duplicate it in the chat. Acknowledge that round N+1..N+E are running and wait.

## 5 · Summarise after completion

Use `Glob` to enumerate **all** `round-*.md` files in `<real-dir>` (not just the new ones — the user wants the full arc), then `Read` to load. Report:

- **Latest verdict** — the canonical 3-token line (`Verdict: STRENGTHEN | RECONSIDER | OVERTURN`) at the bottom of the most recent *completed* critic round. Quote it verbatim. A critic round counts as completed when **either** `index.jsonl` in that directory holds a line with `"t":"end"`, `"rc":0` and `"role":"crit"` for it, **or** a `.round-<N>-crit*.done` sidecar exists for it; take the highest such N. Both, not just the index: a debate started before the ledger keeps its early rounds in the sidecars alone, so the index can cover only part of it. `index.jsonl` is a handful of short lines — `Read` it — and a completed line's `"file"` names the transcript. Only when the directory has neither an `index.jsonl` nor any `.done` sidecar (a debate older than both) may you fall back to the highest-numbered non-empty `round-*-crit*.md`. If it has them and none records a completed critic round, say that no critic round completed — do not quote an unfinished transcript.
- **What changed** between the new rounds and the prior set: did Generator's stance evolve? Did Critic discover new lines of attack? One bullet per shift, ≤25 words each.
- **Two follow-up questions** worth asking next — concrete, not generic.

## Constraints

- **Do not call `ask-generator.sh` / `ask-critic.sh` directly.** `debate.sh --continue-from` is the only entry point for this skill.
- **Do not rewrite or delete prior round files yourself.** `debate.sh` keeps completed rounds and only re-runs an incomplete one — a round that neither the attempt ledger `index.jsonl` nor a `.done` sidecar records as completed — overwriting that failed transcript.
- **Never edit or delete `index.jsonl`.** It is the debate's append-only attempt ledger and `debate.sh` is its only writer; `/continue` decides where to resume from it.
- **Do not start a new `debate-<TS>/` dir.** If the user wants a fresh debate on a different topic, they should use `/debate-conductor:run` instead — tell them so rather than silently switching.
- **Each new round only sees the immediately preceding generator+critic pair**, not the full transcript. If the user expects round 6 to remember round 1's framing, prompt them to restate it as part of the topic — the engine intentionally keeps prompts bounded as the debate grows.
