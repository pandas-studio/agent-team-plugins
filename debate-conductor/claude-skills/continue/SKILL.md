---
description: Extend the most recent debate by N more rounds in the same `debate-<TS>/` dir. Round numbering continues; tail panes pick up new rounds without retarget. Reads topic from prior debate's topic.txt.
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: '"${CLAUDE_PLUGIN_ROOT}/bin/announce-view.sh"'
allowed-tools: Bash(team-3pane.sh:*) Bash(run-debate.sh:*) Bash(open-view.sh:*) Bash(ls:*) Bash(cat:*) Read Glob
argument-hint: "[--view=auto|tmux|none] [--open-view] [--terminal=auto|ghostty|terminal] [extra-rounds]"
---

# Continue a debate

Read the [shared viewing/dispatch contract](../../lib/view-workflow.md), consume
its leading controls, then extend the chosen debate by the remaining number
(default 2). Round numbers continue after the last completed round; an
incomplete first round resumes at 1 using the saved context. Verified viewers
follow appended streams; do not assume viewers exist before preparation.

## 1 · Resolve the prior debate

- Prefer the last validated receipt for this ongoing workspace task. Otherwise
  obtain the normalized configured base from the saved context, or from a
  discovery-only `team-3pane.sh --view=none` call, then Glob
  `<absolute-log-base>/*/latest-debate` (honor custom `DEBATE_LOG_DIR`).
- **Exactly one match** → use it.
- **Multiple matches** → list each as `<team-name>: <real dir>` and ask which to continue.
- **No matches** → tell the user: "No prior debate found in this workspace. Run `/debate-conductor:run` first."

Use the selected absolute directory. For a normal `<base>/<team>/debate-*`,
prepare with both `--team=<team>` and `--log-base=<absolute-base>`. The runner
resolves the selected path physically once and checks its parent against the
prepared context. Nonstandard parents use manual `--log-dir=<absolute-parent>`
context as described in the shared contract; strict tmux refuses that case.

## 2 · Resolve the topic

- Read `<real-dir>/topic.txt`. If present, use its contents as the topic.
- If absent (older debate created before `topic.txt` was added) → ask the user to re-state the original topic; pass that string.

## 3 · Resolve `extra-rounds`

- `$ARGUMENTS` is a single integer (1–9) → that many more rounds.
- `$ARGUMENTS` is empty → default `2`.
- Anything else → ask for a number.

## 4 · Run the extension

Prepare a fresh context, optionally open, and **show viewing instructions in
chat before dispatch** in a separate tool call. Use the returned context file.
Copy the actual attach command or both manual tail commands into that visible
reply; tool output does not count, including for `--view=none`. Only `present`
permits confirming current-window viewers. Do not dispatch before this reply.
Send the latest helper's `user_message` verbatim before dispatch: use the opener's
message if opening was requested, otherwise preparation's, even for `--view=none`.
It reuses the debate directory's saved model pair and any saved rotation unless
this invocation passes explicit model flags/env vars. Start a fresh debate to
change model pairs inside rotation or to change whether rotation is enabled.

```
run-debate.sh --host=claude --context '<context_file>' --continue-from '<absolute-debate-dir>' -- -n <EXTRA> "<topic>"
```

Only say the current panes are ready for `present`; detached/manual states
need their actual connection/tail instructions. Use a host timeout or
background/poll mechanism sufficient for the long run.

## 5 · Summarise after completion

After exit 0 call `run-debate.sh --read-receipt --context '<context_file>'`.
Missing/invalid receipt is incomplete. Use its validated `debate_dir` and
enumerate all `round-*.md` files there (not just new ones), then report:

- **Latest verdict** — the canonical 3-token line (`Verdict: STRENGTHEN | RECONSIDER | OVERTURN`) at the bottom of the most recent *completed* critic round. Quote it verbatim. A critic round counts as completed only when `index.jsonl` contains an `end` record with `"rc":0` and `"role":"crit"` for it. Read the ledger, choose the highest such round, and read the transcript named by its `"file"` field. Ignore malformed lines and duplicate records. If no critic round completed, say so. Never infer completion from `.done` sidecars or transcript filenames; if the completed round has no unambiguous recorded filename, report that the verdict cannot be determined.
- **What changed** between the new rounds and the prior set: did Generator's stance evolve? Did Critic discover new lines of attack? One bullet per shift, ≤25 words each.
- **Two follow-up questions** worth asking next — concrete, not generic.

## Constraints

- **Do not call `ask-generator.sh` / `ask-critic.sh` directly.** Use the runner's own `--continue-from` option, never forward it after `--`.
- **Do not rewrite or delete prior round files yourself.** `debate.sh` keeps completed rounds and only re-runs an incomplete one — a round without a successful end record in the attempt ledger `index.jsonl` — overwriting that failed transcript.
- **Never edit or delete `index.jsonl`.** It is the debate's append-only attempt ledger and `debate.sh` is its only writer; `/continue` decides where to resume from it.
- **Do not start a new `debate-<TS>/` dir.** If the user wants a fresh debate on a different topic, they should use `/debate-conductor:run` instead — tell them so rather than silently switching.
- **Each new round only sees the immediately preceding generator+critic pair**, not the full transcript. If the user expects round 6 to remember round 1's framing, prompt them to restate it as part of the topic — the engine intentionally keeps prompts bounded as the debate grows.

Continuation refuses a missing or unreadable ledger, legacy sidecar completions absent from the ledger, or nonempty transcripts beyond the next retry round. Report the refusal and start a fresh debate if requested. Do not migrate, delete sidecars, or fabricate ledger records.

For **"뷰 열어줘" directly call `open-view.sh --context '<saved-file>'`** under
the shared standing contract. Never implicitly invoke bootstrap or dispatch a
debate for that action. New turns use normal host permissions.
