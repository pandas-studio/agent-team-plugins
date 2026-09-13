---
name: review
description: Run an independent dev-trio code review from Codex, using authenticated Claude Code by default and handling research follow-ups.
---

# Review from Codex

Codex is the PM/coder; the selected external CLI is the reviewer. Resolve the
plugin root two directories above this skill directory and use the shared
[ask-codex.sh](../../bin/ask-codex.sh). Its legacy filename does not select a
model. Never call a raw CLI to bypass its authentication check or logging.

From the user's workspace:

```bash
DEV_TRIO_PM_HOST=codex "<plugin-root>/bin/ask-codex.sh" "<focus>" </dev/null
```

Omit focus for the full working tree, including untracked files. Preserve
`--with-research <file>`, `--with-spec <file>`, and `--no-memories` as separate
quoted argv entries when requested. Paths can contain spaces. Do not split a
raw argument string on whitespace or interpolate it as executable shell text.
Explicit role settings still win; `--no-memories` is valid only with a Codex
reviewer, so a Claude reviewer will reject it before inference.

Capture this invocation's exit code and exact final/log paths from stderr.
On nonzero exit, or absent/empty final response, report an incomplete review.
Do not use old `latest` artifacts. On success read the `.final.md` and extract
only the canonical token line immediately after `## Verdict`:
`SHIP`, `NEEDS-FIX`, or `DISCUSS` followed by its reason. If that format is
missing, report an unparseable review rather than inferring SHIP from prose.

Report the actual reviewer model, verdict, substantive Blocker/Major findings,
and the final artifact link. For `NEED RESEARCH`, obtain the requested evidence
with the [research skill](../research/SKILL.md) within the user's authorized
scope, then repeat the original review with the same focus and spec plus the
new research file. Fix findings only within the authorized task.

Before a third round on the same function/file, check whether simplifying or
replacing that implementation would address the repeated findings. Preserve
the useful reproductions when replacing it.
