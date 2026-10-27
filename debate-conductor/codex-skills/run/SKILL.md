---
name: run
description: Run a Generator-vs-Critic debate from Codex and summarize the final verdict and round moves.
---

# Run a Debate from Codex

Codex is the conductor. Resolve the plugin root two directories above this skill
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
"<plugin-root>/bin/run-debate.sh" --host=codex --context '<exact context_file>' -- -n <rounds> [flags] "<topic>" [context-file.md]
```

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

## Host permission for a Claude role

A Claude generator or critic reads its login from macOS Keychain, in the
preflight and in each round. Codex's workspace sandbox can hide Keychain, and
then a logged-in Claude reports exactly what a logged-out one does. `debate.sh`
therefore exits 2 with `Claude login unverified in this environment (auth
status: …)` before creating a debate directory or moving `latest-debate`; it
never claims a logout. You decide, because only you know whether the host
approved the run.

- **One approval attempt per debate command.** Either run it the first time
  with the host's approval mechanism (for example `require_escalated`, with a
  justification naming Keychain access for the Claude role) because this
  session already saw that line, or, after a sandboxed run printed it, request
  approval once. Prepare a fresh context with the same frozen team/base and
  retry the same engine arguments through the runner. Never both.
- Before or between attempts, do not run `claude auth status`, the doctor,
  `claude auth login`, a raw `claude`, or `ask-generator.sh`/`ask-critic.sh`
  as a probe or workaround.
- Approval denied or unavailable: stop and report that the debate did not
  start. Offer a non-Claude model for that role (`--primary-gen=<model>` or
  `--primary-crit=<model>`) as the user's choice; never switch it yourself.
- The approved run prints the same line: stop without another prompt. Ask the
  user to run `claude auth status` in their own terminal and log in there if
  it says so. Do not change authentication yourself.
- A one-time approval covers that one command. If the host lets you suggest a
  persistent `prefix_rule`, name only the `run-debate.sh` path (never `claude`,
  never the topic), and tell the user it would allow every future debate
  through that path, and stops matching after a plugin update.

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

In Codex host mode, the default Critic is Claude Code so Codex does not review
its own debate output as an external agent. Explicit model settings still win.

For a later **"뷰 열어줘" directly call the absolute `open-view.sh --context
'<saved-file>'`**, following the shared standing instructions. Never invoke
bootstrap implicitly or dispatch another debate for that request.
