---
name: continue
description: Continue the most recent debate from Codex by appending more rounds to the same transcript directory.
---

# Continue a Debate from Codex

Resolve the plugin root two directories above this skill directory and use
[run-debate.sh](../../bin/run-debate.sh). Continue only an existing transcript; do not
start a fresh debate from this skill.

Read the [shared viewing/dispatch contract](../../lib/view-workflow.md).
Consume `--view=auto|tmux|none`, `--open-view` and optional `--terminal=…`.
Prefer the last validated receipt in this workspace task; otherwise use the
saved normalized base, or discovery-only absolute `team-3pane.sh --view=none`,
then find `<absolute-log-base>/*/latest-debate`, including custom roots. Ask
which team only for multiple candidates. No match means run a debate first.
Prepare with explicit `--team`/`--log-base` derived from the chosen directory
(nonstandard parent: manual `--log-dir`). Use absolute plugin helper paths.
Prepare, optionally open, **show viewing instructions in chat before dispatch**,
then dispatch in a separate long-running tool call:
Copy the actual attach command or both manual tail commands into the visible
reply first (even for `--view=none`); tool output alone does not count.
Send `user_message` verbatim immediately after preparation, before another tool.

Read `<debate-dir>/topic.txt` and run:

```bash
"<plugin-root>/bin/run-debate.sh" --host=codex --context '<context_file>' --continue-from "<debate-dir>" -- -n <extra-rounds> "<topic>"
```

If `debate.sh` prints `Claude login unverified in this environment`, follow
[the run skill's host permission rules](../run/SKILL.md#host-permission-for-a-claude-role):
one approval attempt, then stop. The transcript, its ledger and `latest-debate`
are unchanged. A continued debate keeps its saved model pair, so offering a
non-Claude model means passing an explicit model flag, which rotated
transcripts refuse; there, report the block instead.

Default extra rounds to `2` when the user does not specify a number. Rounds
continue after the last completed one, which `debate.sh` reads from the
debate's append-only attempt ledger `index.jsonl` (never edit or delete it). If
round 1 never completed and later rounds contain no output, `debate.sh` resumes
at round 1 and reuses the round-1 context saved in `context.md`. `debate.sh`
persists and reuses the transcript's model pair and any saved rotation unless
this invocation supplies explicit model flags/env vars. Start a fresh debate to
change model pairs inside rotation or to change whether rotation is enabled.
After exit 0 run the absolute `run-debate.sh --read-receipt --context
'<context_file>'`; missing/invalid receipt means incomplete. Use only its
validated `debate_dir` (never stdout/latest) and read all round files there to
summarize the latest verdict plus only the new shifts introduced by the appended
rounds. The verdict comes from the latest *completed* critic round: a critic round
counts as completed only when `index.jsonl` contains an `end` record with `"rc":0` and
`"role":"crit"` for it. Read the ledger, choose the highest such round, and read the
transcript named by its `"file"` field. Ignore malformed lines and duplicate records. If
no critic round completed, say so. Never infer completion from `.done` sidecars or
transcript filenames; if the completed round has no unambiguous recorded filename,
report that the verdict cannot be determined.

Continuation refuses a missing or unreadable ledger, legacy sidecar completions
absent from the ledger, or nonempty transcripts beyond the next retry round.
Report the refusal and start a fresh debate if requested. Do not migrate, delete
sidecars, or fabricate ledger records.

For **"뷰 열어줘" directly call the absolute `open-view.sh --context
'<saved-file>'`** under the shared standing contract. Never implicitly invoke
bootstrap or dispatch another debate. Use normal host permissions on new turns.
