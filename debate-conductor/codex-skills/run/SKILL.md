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

Capture the command exit code and the transcript directory printed by the
wrapper. On failure, report the incomplete debate and point to the log. On
success, read the round files in that transcript directory and report only:
the canonical latest Critic verdict, one short move per round, and two concrete
follow-up questions. Do not paste full transcripts. A critic round counts as
completed when either `index.jsonl` in that directory holds a line with
`"t":"end"`, `"rc":0` and `"role":"crit"` for it, or a `.round-<N>-crit*.done`
sidecar exists for it; take the verdict from the highest such N, whose `"file"`
(when the ledger has it) names the round file. Check both: a debate started
before the ledger keeps its early rounds in the sidecars alone. Only when the
directory has neither an `index.jsonl` nor any `.done` sidecar may you fall back
to the highest-numbered non-empty `round-*-crit*.md`; if it has them and none
records a completed critic round, report that no critic round completed.

In Codex host mode, the default Critic is Claude Code so Codex does not review
its own debate output as an external agent. Explicit model settings still win.
