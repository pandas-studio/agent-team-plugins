---
name: run
description: Run a Generator-vs-Critic debate from Antigravity and summarize the final verdict and round moves.
---

# Run a Debate from Antigravity

Antigravity is the conductor. Resolve the plugin root two directories above this skill
directory and use [run-debate.sh](../../bin/run-debate.sh). Do not call
`ask-generator.sh` or `ask-critic.sh` directly.

Read the [shared viewing/dispatch contract](../../lib/view-workflow.md).
Consume leading `--view=auto|tmux|none`, `--open-view` and optional
`--terminal=auto|ghostty|terminal`; bootstrap is optional. Use absolute plugin
paths for all helpers, never assume bin is on PATH. Prepare in one tool call,
optionally open in another, **show the viewing instructions in chat before
dispatch**, then pass the topic as one quoted argument:

Copy the actual attach command (`ready-detached`) or **both tail commands**
(`manual`, even for `--view=none`) into your visible reply before the dispatch
tool call. Tool output alone does not count. For `present`, confirm the verified
current-window viewers. Do not skip this reply to save a message.
Send the latest helper's `user_message` verbatim before dispatch: call the opener
first if opening was requested; otherwise send preparation's message immediately.
This includes short runs and `--view=none`.

```bash
"<plugin-root>/bin/run-debate.sh" --host=agy --context '<exact context_file>' -- -n <rounds> [flags] "<topic>" [context-file.md]
```

Ordinary debates default to **4 rounds**: proposal, critique, revision, final
critique. Use `2` for a quick pass and honor every explicit round count.

If the user asks for convergence, add `--until-converged`; then `-n` is the
upper bound and may be omitted to use the default cap. Preserve explicit
`--rotate`, `--primary-gen=<model>` (`--gen=<model>`), and
`--primary-crit=<model>` (`--crit=<model>`) choices, and translate natural-language
role requests (e.g. `gen=agy crit=kimi-code`, `claude vs agy`) into those flags
rather than leaving model labels inside `<topic>`.

Generator and Critic run in **non-interactive headless mode** where unapproved
shell discovery commands (`rg`, `find`, `grep`, compound commands) are
auto-denied and abort the round. When a short topic references repository-internal
entities (e.g. `"Track 4"`, local specs, plans, or module names) without
self-contained context, read the relevant workspace files first and include the
essential repository facts directly in `<topic>` (every round — Generator and
Critic alike — sees `<topic>`), optionally passing longer Round-1 Generator
background via `[context-file.md]` (`--context=<file>`, written under
`.debate-conductor/log/` or `$TMPDIR`; read by Round 1's Generator only).

When no topic is supplied, inspect workspace `topics/*.txt` first, then the
plugin's bundled `topics/*.txt`; ask the user to choose only if the topic is
still ambiguous. Free-form multi-word input is the topic verbatim.

## Host permissions

Use Antigravity's command execution tool for the absolute helper commands and
its native file tools for reading artifacts. Keep preparation, optional opening,
dispatch and receipt validation in separate calls. Poll a running command to its
actual exit; do not let a short tool timeout abort a multi-minute debate.

In interactive agy, approve the specific helper command when prompted. In
headless print mode a command requiring unavailable approval can be soft-denied
even with CLI exit 0. Stop and report the denied command; ask the user to run
this skill in interactive agy and approve it there. Do not alter permission
settings, encode commands to evade policy, or use bypass flags. Never report
completion without a successful dispatch and validated receipt.

If a Claude role prints `Claude login unverified in this environment`, stop
and report that no round started. Antigravity has no Codex-style
`require_escalated` parameter: do not invent one or repeatedly probe auth. Ask
the user to check `claude auth status` in their own terminal. Do not change
credentials, billing, or the selected role models yourself.

Capture the dispatch exit code. On failure, report the incomplete debate.
Only after exit 0, run the absolute `run-debate.sh --read-receipt --context
'<context_file>'` and use its validated `debate_dir`; never bind results by
parsing stdout or following `latest-debate`. Missing/invalid receipt means
incomplete. On success, read the files in that directory and report only:
the canonical latest Critic verdict, one short move per round, and two concrete
follow-up questions. Do not paste full transcripts. A critic round counts as completed
only when `index.jsonl` contains an `end` record with `"rc":0` and `"role":"crit"` for
it. Read the ledger, choose the highest such round, and read the transcript named by its
`"file"` field. Ignore malformed lines and duplicate records. If no critic round
completed, say so. Never infer completion from `.done` sidecars or transcript filenames;
if the completed round has no unambiguous recorded filename, report that the verdict
cannot be determined.

In Antigravity host mode, Generator defaults to Claude Code and Critic to
Codex. Explicit model settings still win.

For a later **"뷰 열어줘" directly call the absolute `open-view.sh --context
'<saved-file>'`**, following the shared standing instructions. Never invoke
bootstrap implicitly or dispatch another debate for that request.
