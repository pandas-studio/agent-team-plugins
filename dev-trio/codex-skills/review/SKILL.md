---
name: review
description: Run an independent dev-trio code review from Codex, using authenticated Claude Code by default and handling research follow-ups.
---

# Review from Codex

Codex is the PM/coder; the selected external CLI is the reviewer. Resolve the
plugin root two directories above this skill directory and use the shared
[ask-reviewer.sh](../../bin/ask-reviewer.sh). Its filename names the role, not a
model. Never call a raw CLI to bypass its authentication check or logging.

From the user's workspace:

```bash
DEV_TRIO_PM_HOST=codex "<plugin-root>/bin/ask-reviewer.sh" [options] -- "<focus>" </dev/null
```

Omit focus (and the `--` before it) for the full working tree, including
untracked files. Preserve `--model <id>`, `--with-research <file>`,
`--with-spec <file>`, `--with-context <file>`, and `--no-memories` as separate
quoted argv entries before `--` when requested; pass a requested `-m <id>` as
`--model <id>`. Paths can contain spaces. Do not split a
raw argument string on whitespace or interpolate it as executable shell text.
In the user's request, a `--` ends the options: everything after it is focus,
even `--help`, `-m` or `--model x`. Before that `--`, a `-m`/`--model` with no
id or with `--` as its id, or an attached form (`-m=agy`, `--model=agy`), is not
dispatched: tell the user the id goes in its own token and that focus text
containing `-m` (such as `git commit -m`) belongs after `--`.
`--model <id>` picks the reviewer for this call and wins over
`DEV_TRIO_REVIEWER_MODEL` and the role binding; otherwise explicit role
settings still win. `--model claude` goes through the Claude login check
below. `--no-memories` is valid only with a Codex reviewer, so a Claude
reviewer will reject it before inference.

## Several reviewers

The wrapper runs one model per call. The request may name more than one
reviewer; then dispatch one call per reviewer. Model selection, before any
`--`, applies to every request that has a `-m`/`--model`:

- `-m`/`--model` may appear more than once, and its value is one id or a comma
  list of ids (`agy,codex`). A comma list with an empty element (`agy,,codex`,
  `agy,`) is not dispatched, like the missing-id and attached forms above.
- Look up the registered ids whenever a word follows a model value, or more
  than one id has been named: run `"<plugin-root>/bin/agent-team-models" list`
  once. The registered ids are the first column under `Models:` (built-ins such
  as `codex-no-memories` included). If the command fails (exit 3 means the
  models config is malformed), dispatch nothing and report it.
- Directly after a `-m` value, each following word that is exactly a registered
  id is one more reviewer (`-m agy codex` names two). Only this run of ids ends
  at the first word that is not a registered id. That word is not an error: it
  is read like any other, so a later `-m` is still an option.
- After a lookup, an id written as a `-m` value or inside a comma list that is
  not registered is an error: dispatch nothing and tell the user. A lone
  `-m <id>` with nothing after it needs no lookup; the wrapper rejects an
  unregistered id with exit 2 before any model runs.
- Keep the ids as written, in first-seen order, each once.

How these rules read five requests when only the built-in ids are registered
(`agy`, `claude`, `codex`, …). The last column is the focus text as parsed; a
`pr 12` focus is still resolved to a range before dispatch.

| Request | Reviewers | Focus text |
| :--- | :--- | :--- |
| `-m agy codex` | agy, codex | (full working tree) |
| `pr 12 -m agy codex` | agy, codex | `pr 12` |
| `-m agy pr 12 -m codex` | agy, codex | `pr 12` |
| `-m agy,codex claude -- codex is slow` | agy, codex, claude | `codex is slow` |
| `-m agy too` | agy | `too` |

A registered id changes the reading: with a user model named `too`, the last
row names two reviewers. Focus text that could be read as an id goes after
`--`.

With several reviewers:

- Dispatch the calls in parallel with the same focus, the same flags and the
  same attachment files. The calls differ only in `--model <id>` and, by the
  next rule, in `--no-memories`. For a pull request, resolve it once and hand
  the same context file and range to every reviewer.
- `--no-memories` goes only on the calls whose id is exactly `codex` or
  `codex-no-memories`; say which calls carried it. With one reviewer, or with
  no `-m`, pass it through unchanged.
- One reviewer failing does not cancel the others. The Claude login line
  handled by the one-approval rule below comes first: that rule applies to each
  Claude reviewer call separately, and its "stop" ends that reviewer only.
  After it, a usage or setup failure (exit 2), a denied or unavailable host
  approval, or a failed invocation makes that reviewer "no verdict"; let the
  rest finish and report every reviewer.
- Report each reviewer's model, verdict and counts side by side, then every
  Blocker and Major finding labelled with its reviewer. Do not merge or
  de-duplicate findings across reviewers.
- A `NEED RESEARCH`, `NEED CONTEXT` or format repeat re-runs only the reviewer
  that asked. The files the batch shared stay as they are: copy the context or
  research file to a new file, add the new evidence there, and pass the copy.
  If the PR's head or base moved, the repeat is a new review and the other
  reviewers' verdicts belong to the old revision: say so and ask the user
  whether to re-run the whole batch; do not present a verdict for the new
  revision beside verdicts for the old one.
- For the third-round check at the end of this skill, one round is one batch
  against one revision together with its repeats. A new round starts only
  after a fix.

For a pull request, never pass a bare `pr N` focus: the reviewer may lack
network access and cannot tell which commits the PR contains. Run
`gh pr view N --json number,url,title,baseRefName,baseRefOid,headRefName,headRefOid`
yourself, save its output as a context file, confirm both commits exist locally
(ask before fetching; `pull/N/head` works for fork PRs), and dispatch with
`--with-context <file>` and a `<merge-base>..<headRefOid>` range focus.

## Host permission for a Claude reviewer

A Claude reviewer reads its login from macOS Keychain, both in the wrapper's
login check and in the review itself. Codex's workspace sandbox can hide
Keychain, and then a logged-in Claude reports exactly what a logged-out one
does. The wrapper therefore exits 2 before any invocation with
`Claude login unverified in this environment (auth status: …)`; it never
claims a logout. You decide, because only you know whether the host approved
the run.

- **One approval attempt per review.** Either dispatch the first attempt with
  the host's approval mechanism (for example `require_escalated`, with a
  justification naming Keychain access for the Claude reviewer) because this
  session already saw that line, or, after a sandboxed dispatch printed it,
  request approval for the same argv once. Never both.
- Before or between attempts, do not run `claude auth status`, the doctor,
  `claude auth login`, a raw `claude`, or a different reviewer as a probe or
  workaround.
- Approval denied or unavailable: stop and report that the review did not run
  and there is no verdict.
- The approved run prints the same line: stop without another prompt. Report
  that the login check failed even with host access, and ask the user to run
  `claude auth status` in their own terminal and log in there if it says so.
  Do not change authentication yourself.
- A one-time approval covers that one command; a SHA or range focus makes it
  useless for the next review. If the host lets you suggest a persistent
  `prefix_rule`, name only the wrapper path (never `claude`, never focus
  arguments), and tell the user it would allow every future review through
  that wrapper at that versioned plugin path, and stops matching after a
  plugin update.

Capture this invocation's exit code and the exact log/final/result paths from
its last stderr line. Read that exact `.review.json`: it is the parsed result
the wrapper, manifest and dashboard share. Do not parse verdicts or count
bullets in Markdown, and do not use `latest` artifacts.

- `status: "ok"`: use `verdict` (`SHIP`, `NEEDS-FIX`, `DISCUSS`, or
  `OUT-OF-SCOPE` under the spec profile) and quote `verdict_line` verbatim.
- `findings.blocker`/`.major`/`.minor` are arrays of real findings; `null`
  means the section is missing, so report that count as unknown, not zero.
  English `- None.` (case-insensitive, optional period) and Korean `- 없음` /
  `- 없음.` empty markers allow trailing whitespace and are already excluded.
- `status: "permission-denied"` (exit 3): headless agy auto-denied a tool and
  wrote no review. Report each `denied` entry (a target agy recorded as
  denied; agy 1.2.9 ignores `unsandboxed(...)` rules; empty means agy
  recorded none) and `conversation_ids`, and point to the
  README section "Resolve a confirmed agy permission denial". A
  `read_file(<path>)` entry is a path to check (outside the workspace? does it
  exist?), not a rule to add. If a denied
  `command(git ...)` target contains backticks (`` ` ``), `$()`, or shell
  operators (even inside `"..."`), agy's `unquoted_shell_operators` check
  prevented the `command(git ...)` prefix rule from matching rather than missing
  the base rule. Do not grant anything yourself.
- `status: "parse-failed"` (exit 3) or `"invocation-failed"`: report the
  failure, its `error`, and the artifact paths. There is no verdict. A
  `parse-failed` result with `invocation_rc: 0` is a finished review that broke
  the output format (#125): repeat it once with the same focus, every original
  flag (including `--model`) and the same attachments, and report both runs' artifact paths. If the
  reviewed code changed in between, that is a new review, not a retry; if the
  retry fails to parse too, stop and report both. Never read a verdict or
  counts out of `.final.md`.
- An empty marker mixed with finding bullets in the same severity, including
  repeated headings, is a parse failure. Resolved explanations belong under
  `## What I checked`. Report the failure; do not reinterpret its bullets or
  clear counts because the Markdown says `SHIP`.
- Findings use `- ` bullets at column 0; an item indented 1–3 spaces directly
  under a finding is joined onto that finding. Other list items with text
  (including empty markers) fail parsing with 1–3-space indentation, `*` / `+` /
  numbered markers, or a tab separator after `-`. Whitespace-only list items are ignored.
  Quoted and code examples stay excluded; other prose is not parsed as findings.
  Report format failures as unknown findings.
- A missing or unreadable result means the verdict is unavailable; never fall
  back to the raw log or `.final.md`.

Report the actual reviewer model, verdict, substantive Blocker/Major findings,
and the result artifact link. The `.final.md` of the same successful
invocation is supporting text only. For `NEED RESEARCH`, obtain the requested evidence
with the [research skill](../research/SKILL.md) within the user's authorized
scope. For `NEED CONTEXT`, run only the read-only commands it lists (`gh pr
view/diff/checks`, `gh issue view`, `gh run view`, `git log/show`; ask before
`git fetch` or anything that changes state) and append their outputs to the
context file. Then repeat the review once with the same focus and every
original flag, including `--model`; attachments are cumulative (one file per kind holding the old
and new evidence). If the PR's head or base moved meanwhile, start a new review
instead of a retry. Fix findings only within the authorized task.

Before a third round on the same function/file, check whether simplifying or
replacing that implementation would address the repeated findings. Preserve
the useful reproductions when replacing it.
