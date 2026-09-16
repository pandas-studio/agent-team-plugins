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

Capture this invocation's exit code and the exact log/final/result paths from
its last stderr line. Read that exact `.review.json`: it is the parsed result
the wrapper, manifest and dashboard share. Do not parse verdicts or count
bullets in Markdown, and do not use `latest` artifacts.

- `status: "ok"`: use `verdict` (`SHIP`, `NEEDS-FIX`, `DISCUSS`, or
  `OUT-OF-SCOPE` under the spec profile) and quote `verdict_line` verbatim.
- `findings.blocker`/`.major`/`.minor` are arrays of real findings; `null`
  means the section is missing, so report that count as unknown, not zero.
- `status: "parse-failed"` (exit 3) or `"invocation-failed"`: report the
  failure, its `error`, and the artifact paths. There is no verdict.
- A missing or unreadable result means the verdict is unavailable; never fall
  back to the raw log or `.final.md`.

Report the actual reviewer model, verdict, substantive Blocker/Major findings,
and the result artifact link. The `.final.md` of the same successful
invocation is supporting text only. For `NEED RESEARCH`, obtain the requested evidence
with the [research skill](../research/SKILL.md) within the user's authorized
scope, then repeat the original review with the same focus and spec plus the
new research file. Fix findings only within the authorized task.

Before a third round on the same function/file, check whether simplifying or
replacing that implementation would address the repeated findings. Preserve
the useful reproductions when replacing it.
