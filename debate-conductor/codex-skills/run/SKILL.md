---
name: run
description: Run a Generator-vs-Critic debate from Codex and summarize the final verdict and round moves.
---

# Run a Debate from Codex

Codex is the conductor. Resolve the plugin root two directories above this skill
directory and use [debate.sh](../../bin/debate.sh). Do not call
`ask-generator.sh` or `ask-critic.sh` directly.

From the user's workspace, pass the topic as one quoted argument:

```bash
DEBATE_CONDUCTOR_PM_HOST=codex "<plugin-root>/bin/debate.sh" -n <rounds> "<topic>"
```

If the user asks for convergence, add `--until-converged`; then `-n` is the
upper bound and may be omitted to use the default cap. Preserve explicit
`--rotate`, `--primary-gen=<model>`, and `--primary-crit=<model>` choices.

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
  approval for the same argv once. Never both.
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
  persistent `prefix_rule`, name only the `debate.sh` path (never `claude`,
  never the topic), and tell the user it would allow every future debate
  through that path, and stops matching after a plugin update.

Capture the command exit code and the transcript directory printed by the
wrapper. On failure, report the incomplete debate and point to the log. On
success, read the round files in that transcript directory and report only:
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
