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
DEV_TRIO_PM_HOST=codex "<plugin-root>/bin/ask-reviewer.sh" --summary [options] -- "<focus>" </dev/null
```

Always pass `--summary`: stdout is then one JSON document instead of the
transcript (see reading the result below).
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
  list of ids (`agy,codex`). A value shaped like an option
  (`-m --with-spec spec.md`) or a comma list with an empty element
  (`agy,,codex`, `agy,`) is not dispatched, like the missing-id and attached
  forms above.
- Directly after a `-m` or `--model` value, each following word that is exactly
  `agy`, `claude` or `codex` is one more reviewer (`-m agy codex` and
  `--model agy codex` each name two). Only
  these three ids are read this way, and nothing is looked up: any other id — a
  model the user registered, `codex-no-memories` — is named in a comma list or
  with its own `-m`. The run ends at the first other word, which is read like
  any other, so a later `-m` is still an option.
- Keep the ids as written, in first-seen order, each once. Do not check that an
  id is registered: the wrapper rejects an unregistered one with exit 2 before
  any model runs.

How these rules read five requests. The last column is the focus text as
parsed; a `pr 12` focus is still resolved to a range before dispatch.

| Request | Reviewers | Focus text |
| :--- | :--- | :--- |
| `-m agy codex` | agy, codex | (full working tree) |
| `pr 12 -m agy codex` | agy, codex | `pr 12` |
| `-m agy pr 12 -m codex` | agy, codex | `pr 12` |
| `-m agy,codex claude -- codex is slow` | agy, codex, claude | `codex is slow` |
| `-m agy too` | agy | `too` |

Focus text that begins with `agy`, `claude` or `codex` directly after a model
value goes after `--`, as in the fourth row.

With several reviewers:

- Dispatch the calls in parallel with the same focus, the same flags and the
  same attachment files. The calls differ only in `--model <id>` and, by the
  next rule, in `--no-memories`. For a pull request, resolve it once and hand
  the same context file and range to every reviewer. An attachment that can
  change under the batch — a `latest-*` link, a file still being written — is
  copied to a fresh file first, and every reviewer gets the copy.
- `--no-memories` goes only on the calls whose id is exactly `codex` or
  `codex-no-memories`; say which calls carried it. With one reviewer, or with
  no `-m`, pass it through unchanged.
- One reviewer failing does not cancel the others. The Claude login line
  handled by the one-approval rule below comes first: that rule applies to each
  Claude reviewer call separately, and its "stop" ends that reviewer only.
  After it, a usage or setup failure (exit 2), a denied or unavailable host
  approval, a failed invocation, or an exit code that differs from the
  result's `exit_code` (see the result section) makes that reviewer "no
  verdict"; let the rest finish and report every reviewer.
- Report each reviewer's model, verdict and counts side by side for the
  reviewers that have a verdict, and the result section's failure report for
  each one that does not. Then every
  Blocker and Major finding labelled with its reviewer. Do not merge or
  de-duplicate findings across reviewers.
- A `NEED RESEARCH`, `NEED CONTEXT` or format repeat re-runs only the reviewer
  that asked. The files the batch shared stay as they are: copy the context or
  research file to a new file, add the new evidence there, and pass the copy.
  If what is under review changed since the batch was dispatched — the PR's
  head or base moved, a commit in the reviewed range moved, or the working tree
  was edited — the repeat is a new review and the other reviewers' verdicts
  belong to the old state: say so and ask the user whether to re-run the whole
  batch; do not present a verdict for the new state beside verdicts for the old
  one.
- For the third-round check at the end of this skill, one round is one batch
  against one revision together with its repeats. A new round starts only
  after a fix.

## Pull requests

Never pass a bare `pr N` focus: the reviewer may lack network access and
cannot tell which commits the PR contains. Resolve it with
`"<plugin-root>/bin/pr-context.sh"`, which asks `gh` for the head and base,
checks both commits are here, takes the merge base, writes a context file and
prints one JSON line. It never fetches.

- The focus (after options, including a focus written after `--`) names a PR
  when its first word is `pr` (any case) followed by `N` or `#N` (digits
  only) — the reference is `N` — or when its first word starts with
  `https://` and contains `/pull/` — the reference is that word, unchanged;
  the resolver checks its shape and repository. If the word right after the
  reference is digits only (`pr 1320 1321`), dispatch nothing and ask which
  PR. Every other word after the reference is the user's focus.
- Run `"<plugin-root>/bin/pr-context.sh" [--with-context <file>] -- <reference>`
  as its own command, not chained with other commands.
  A `--with-context` file the user gave goes here (the last one if given more
  than once); the reviewer then gets only the generated `context_file`.
- Pass the reference, an attachment path and the generated `context_file` as
  separate argv entries, never as shell text.
- Exit 0: take `context_file` and `focus` from the JSON. Exit 4 with a last
  stderr line `(pr: N, missing: …)`: show the resolver's stderr guidance as it
  stands (a fetch command, a "by hand" instruction, a shallow-clone note) and
  ask before fetching; do not fetch. Exit 4 without that line is a failure.
  Exit 2: report the `(pr: N, failed: …)` reason or the usage error. Any other
  status or no marker: report that the resolver did not finish, not that a
  commit is missing. Dispatch nothing unless it exited 0.
- Dispatch with `--summary`, the user's other options in the order written
  (each attachment kind once, the last one given), `--with-context
  <context_file>`, `--`, and the JSON's `focus` followed by
  ` — <user focus>` when the user wrote one.

| Request | Resolver argv | Reviewer argv, one call per reviewer |
| :--- | :--- | :--- |
| `pr 55` | `-- 55` | `--summary --with-context <cf> -- "<focus>"` |
| `PR #55 check auth -m codex` | `-- 55` | `--summary --model codex --with-context <cf> -- "<focus> — check auth"` |
| `--with-context notes.md pr 55 -m agy codex` | `--with-context notes.md -- 55` | agy and codex, each `--summary --model <id> --with-context <cf> -- "<focus>"` |
| `https://github.com/o/r/pull/55` | `-- https://github.com/o/r/pull/55` | as in the first row |
| `pr 1320 1321` | (not run) | (ask the user) |
| `--with-context a.md pr 55 --with-context b.md --with-spec s.md -m agy codex --no-memories` | `--with-context b.md -- 55` | agy: `--summary --with-spec s.md --model agy --with-context <cf> -- "<focus>"`; codex: `--summary --with-spec s.md --model codex --no-memories --with-context <cf> -- "<focus>"` |

`<cf>` is the JSON's `context_file` and `<focus>` its `focus`. If the user's
focus itself contains a git range (`A..B`) and agy is a reviewer, say that agy
may have reviewed without its workspace snapshot (the wrapper skips it for a
focus with more than one range and does not say so).

Host approval counts per command. The resolver needs GitHub network access,
which a workspace sandbox can block. If the host already permits it, run the
resolver normally. If it is known to be blocked and the host supports
approval, request approval once for this resolver call, naming GitHub access;
do not probe `gh` some other way. If approval is unavailable or refused, or the
resolver fails, start no reviewer. A Claude reviewer call then gets its own
approval attempt under the next section.

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

Capture this invocation's exit code from the host's result for the command,
and the exact log/final/result paths from the last stderr line that starts
with `(log:` (a notice can follow it). The
parsed result the wrapper, manifest and dashboard share is that exact
`.review.json`. Check the summary first: when exactly one stdout line starts
with `{"summary_version":1`, parses as JSON, has a non-null `result`, and its
`paths.result` equals the `result:` path in that `(log:` line, its `result` is
that `.review.json` as published, so use it and do not open the file. In every
other case read that exact `.review.json`. Do not parse verdicts or count
bullets in Markdown, and do not use `latest` artifacts.

Then, before anything below, compare the selected result's `exit_code` with
the exit code the host reported for the command — never with the `(log:`
line's `rc=`, the summary's `exit_code` or `invocation_rc`. If they differ, or
the host reported no exit code, the run did not finish normally: report the
result's `exit_code`, the host's exit code (or "unavailable") and the log,
final and result paths. Give no verdict and no counts, and take no follow-up
— no `NEED RESEARCH` or `NEED CONTEXT` handling, no format repeat. The process
status is the authority: a wrapper killed after publishing its result exits
differently while the result still reads `ok`. When they match, the rules
below apply as written. Every call gets this check, repeats included. An
invocation is **successful** only when its result is `ok` and this check
passed; a verdict, counts or a NEED section come only from a successful one.

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
  flag (including `--summary` and `--model`) and the same attachments, and report both runs' artifact paths. If the
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

For a successful invocation (defined above), report
the actual reviewer model, verdict, substantive Blocker/Major findings, and
the result artifact link. Its `.final.md` is supporting text only. Look for `NEED RESEARCH` and `NEED
CONTEXT` in that final, whether the result came from the summary or the file:
the summary's `final_text` on the fast path when it is not `null`, otherwise
the exact `.final.md` path from the `(log:` line. For `NEED RESEARCH`, obtain the requested evidence
with the [research skill](../research/SKILL.md) within the user's authorized
scope. For `NEED CONTEXT`, run only the read-only commands it lists (`gh pr
view/diff/checks`, `gh issue view`, `gh run view`, `git log/show`; ask before
`git fetch` or anything that changes state) and write their outputs to a new
context file that starts with a copy of the original one; never edit a file
that a finished or still-running review was given. Then repeat the review once
with the same focus and every original flag, including `--summary` and `--model`; attachments
are cumulative (one new file per kind holding the old and new evidence). Check
before every repeat, the format repeat above included, whether the PR's head or
base moved: if it did, start a new review instead of a retry (resolve the PR
again, passing the resolver the `--with-context` file the user originally
gave, if any), and with several
reviewers stop and ask first (**Several reviewers**). Fix findings only within
the authorized task.

Before a third round on the same function/file, check whether simplifying or
replacing that implementation would address the repeated findings. Preserve
the useful reproductions when replacing it.
