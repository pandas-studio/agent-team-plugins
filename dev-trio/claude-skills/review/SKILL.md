---
name: review
description: One-shot Codex review. Default scope = uncommitted working-tree changes. Optional --with-research <file>, --with-spec <file> and --with-context <file> for context injection. Streaming output lands in the bottom-right dashboard pane; chat-side surfaces the verdict (SHIP/NEEDS-FIX/DISCUSS) + Blocker/Major counts and handles NEED RESEARCH and NEED CONTEXT blocks.
disable-model-invocation: true
allowed-tools: Bash(ask-reviewer.sh:*) Bash(pr-context.sh:*) Bash(ask-researcher.sh:*) Bash(gh pr view:*) Bash(gh pr diff:*) Bash(gh pr checks:*) Bash(gh issue view:*) Bash(gh run view:*) Bash(git:*) Bash(cat:*) Bash(ls:*) Bash(date:*) Bash(mkdir:*) Bash(echo:*) Bash(sed:*) Read
argument-hint: "[focus] [-m|--model <id>[,<id>...]] [--with-research <file>] [--with-spec <file>] [--with-context <file>] [--no-memories] [-- <focus>]"
---

# Review (Codex, one-shot)

You are the **PM**. Codex is the reviewer (bottom-right pane). You dispatch one review, surface the verdict, and route a `NEED RESEARCH` block through Antigravity and a `NEED CONTEXT` block through your own read-only `gh`/`git` commands.

## Arguments

<arguments>
$ARGUMENTS
</arguments>

Everything between the tags is the argument string the user typed. It may be empty.

## 1 · Parse the argument string and build the dispatch command

The argument string may interleave six pieces in any order:

- **Optional `--with-research <file>`** — research context from a previous Antigravity call (typically `latest-researcher.log` or a curated `research-<TS>.md`).
- **Optional `--with-spec <file>`** — spec/contract the changes are expected to satisfy.
- **Optional `--with-context <file>`** — repository facts you fetched (PR commit IDs, issue text, CI output) for a reviewer that may not reach the network.
- **Optional `--model <id>`** (short: `-m <id>`) — reviewer model for this call only (`codex`, `claude`, `agy`, or any id from `agent-team-models list`); wins over `DEV_TRIO_REVIEWER_MODEL` and the role binding. More than one reviewer can be named — see **Several reviewers** below.
- **Optional `--no-memories`** — bare flag; Codex runs without its memory summary from earlier sessions.
- **Optional free-form focus** — review scope, possibly multi-word. Examples:
  - `focus on the new retry logic in src/agent.py — concurrency safety`
  - `review HEAD~2..HEAD`
  - `review only the changes to src/auth/`

**You must parse the argument string yourself and assemble the bash command with explicit shell quoting.** Do NOT paste the argument string after `ask-reviewer.sh` as it stands — unquoted, the shell word-splits the focus across multiple args, and `ask-reviewer.sh` rejects extra positionals with rc=2.

Algorithm:

1. Tokenise the argument string on whitespace, walk left-to-right. A token before `--` that is an attached model form (`-m=agy`, `--model=agy`) is malformed wherever it stands: dispatch nothing, as in step 4.
2. If a token is `--with-research`, the next token is `<research-file>`; consume both.
3. If a token is `--with-spec`, the next token is `<spec-file>`; consume both.
   Likewise `--with-context` and `<context-file>`.
4. If a token is `--model` or `-m`, the next token is its value: one model id, or a comma list of ids (`agy,codex`). Consume both. `-m`/`--model` may appear more than once.
   - **Malformed value — dispatch nothing.** Tell the user the model id goes in its own token and that focus text containing `-m` belongs after `--`, when: there is no next token; the next token is `--` or is shaped like an option (`-m --with-spec spec.md`); a token is an attached form (step 1); or a comma list has an empty element (`agy,,codex`, `agy,`).
   - **Ids written after the value.** While the token after the value is exactly `agy`, `claude` or `codex`, consume it as one more reviewer (`-m agy codex` names two). Only these three ids are read this way, and you do not look anything up: any other id — a model the user registered, `codex-no-memories` — is named in a comma list or with its own `-m`. The run ends at the first other token, which these steps handle like any other, so a later `-m` is still an option.
   - Keep the ids as written, in first-seen order, each once. With one id, dispatch it as `--model <id>`; with several, follow **Several reviewers** below. You do not check that an id is registered: the wrapper rejects an unregistered one with exit 2 before any model runs.
5. If a token is `--no-memories`, pass it through as its own argv slot; consume only it.
6. If a token is `--`, stop: it and nothing after it is an option, so every later token goes to the focus (`--model agy -- --help` reviews the focus `--help`; `-- --model codex` reviews the focus `--model codex`). A focus that mentions `-m`, such as `git commit -m`, must come after `--`, or step 4 reads it as a model option.
7. Every remaining token belongs to the focus; join them with a single space into one FOCUS string.
8. If FOCUS is empty, omit it entirely (the wrapper falls back to the default working-tree scope). Otherwise put the options first and pass the focus last as `-- "$FOCUS"`, so a focus that starts with a dash is never read as an option.
9. If FOCUS names a pull request, resolve it with `pr-context.sh` before dispatch — see **PR reviews** below. Never send a bare PR reference as the focus: the reviewer may run without network access, and then cannot tell which commits the PR contains (measured: Codex under `workspace-write` failed `gh pr view` and returned `DISCUSS` with zero findings).

### PR reviews

You have network access; the reviewer may not. `pr-context.sh` asks `gh` for the PR's head and base commits, checks that both are in this repository, takes their merge base, writes a context file and prints one JSON line. It never fetches.

**Is FOCUS a PR reference?** Look at FOCUS as step 7 built it; a focus written after `--` counts too.

- First token `pr` (any case) and second token `N` or `#N`, digits only: the reference is `N`.
- First token starts with `https://` and contains `/pull/`: the reference is that token, unchanged. `pr-context.sh` checks its shape and that it names this repository.
- Anything else is not a PR reference.

If the token right after the reference is digits only (`pr 1320 1321`), dispatch nothing and ask which pull request to review: one review covers one PR. Every other token after the reference is the user's focus.

**Resolve it** with one foreground call (it makes one `gh` request). Run it as its own command, not chained with `;` or `&&`: the tool result already carries its exit status.

```bash
pr-context.sh -- 55
pr-context.sh --with-context notes.md -- 55    # the user gave --with-context notes.md
```

Single-quote the reference and any path in the command (as `'https://github.com/o/r/pull/55'`, `'notes.md'`), and the generated `context_file` when you dispatch; a value that itself contains `'` is written as `'\''`. A `--with-context` file the user gave goes to `pr-context.sh`, which appends it to the context file it writes; given more than once, pass the last one, as the wrapper would. The reviewer then gets only the generated `context_file`.

- Exit 0: stdout is one JSON line. Take its `context_file` and `focus`.
- Exit 4 with a last stderr line `(pr: N, missing: …, rc=4)`: a commit is missing locally, or the head and base share no history here. Show the user what `pr-context.sh` printed on stderr as it stands — a fetch command, a "by hand" instruction, a shallow-clone note — and ask before fetching. Do not fetch.
- Exit 2: report the reason in the last stderr line, `(pr: N, failed: <reason>, rc=2)`, or the usage error when that line is the `--help` hint.
- Any other status, or no such marker line: report that `pr-context.sh` did not finish. Do not say that a commit is missing.

Dispatch nothing unless it exited 0. On any other status, discard its stdout.

**Dispatch** with `--summary`, then the user's other options in the order written (each attachment kind once, the last one given), then `--with-context <context_file>`, `--`, and the focus: the JSON's `focus`, followed by ` — <user focus>` when the user wrote one.

| Argument string | `pr-context.sh` argv | `ask-reviewer.sh` argv, one call per reviewer |
| :--- | :--- | :--- |
| `pr 55` | `-- 55` | `--summary --with-context <cf> -- "<focus>"` |
| `PR #55 check auth -m codex` | `-- 55` | `--summary --model codex --with-context <cf> -- "<focus> — check auth"` |
| `--with-context notes.md pr 55 -m agy codex` | `--with-context notes.md -- 55` | agy and codex, each `--summary --model <id> --with-context <cf> -- "<focus>"` |
| `https://github.com/o/r/pull/55` | `-- https://github.com/o/r/pull/55` | as in the first row |
| `pr 1320 1321` | (not called) | (ask the user) |
| `--with-context a.md pr 55 --with-context b.md --with-spec s.md -m agy codex --no-memories` | `--with-context b.md -- 55` | agy: `--summary --with-spec s.md --model agy --with-context <cf> -- "<focus>"`; codex: `--summary --with-spec s.md --model codex --no-memories --with-context <cf> -- "<focus>"` |

`<cf>` is the JSON's `context_file` and `<focus>` its `focus`.

If the user's focus itself contains a git range (`A..B`) and agy is among the reviewers, say in your report that agy may have reviewed without its workspace snapshot: the wrapper skips the snapshot for a focus that names more than one range, and does not say so on stderr.

### Several reviewers

The wrapper runs one model per call. When step 4 yields more than one id, you dispatch one call per id.

How step 4 reads five argument strings. The last column is the focus text as parsed; a `pr 12` focus is still resolved to a range before dispatch (step 9).

| Argument string | Reviewers | Focus text |
| :--- | :--- | :--- |
| `-m agy codex` | agy, codex | (default scope) |
| `pr 12 -m agy codex` | agy, codex | `pr 12` |
| `-m agy pr 12 -m codex` | agy, codex | `pr 12` |
| `-m agy,codex claude -- codex is slow` | agy, codex, claude | `codex is slow` |
| `-m agy too` | agy | `too` |

Focus text that begins with `agy`, `claude` or `codex` directly after a model value goes after `--`, as in the fourth row.

1. **Dispatch one call per reviewer, in parallel** — one background Bash call each (§2) — with the same focus, the same flags and the same attachment files. The calls differ only in `--model <id>` and, by item 2, in `--no-memories`. For a pull request, resolve it once (**PR reviews** above) and hand the same context file and the same range to every reviewer. An attachment that can change under the batch — a `latest-*` link, a file still being written — is copied to a fresh file first, and every reviewer gets the copy.
2. **`--no-memories` with several reviewers** goes only on the calls whose id is exactly `codex` or `codex-no-memories`; the wrapper refuses it for any other model. Say in your report which calls carried it. With one reviewer, or with no `-m` at all, pass it through unchanged and let the wrapper decide.
3. **One reviewer failing does not cancel the others.** A usage or setup failure (exit 2), a declined permission prompt or a failed invocation makes that reviewer "no verdict"; let the rest finish and report every reviewer.
4. **Report side by side.** §3 applies to each result: one verdict line and one findings count per reviewer, then every Blocker and Major bullet labelled with its reviewer. Do not merge or de-duplicate findings across reviewers.
5. **Retries.** A `NEED RESEARCH`, `NEED CONTEXT` or format retry (§4, §4b, Retry rule) re-runs only the reviewer that asked. The files the batch shared stay as they are: copy the context or research file to a new file, append the new evidence there, and pass the copy. If what is under review changed since the batch was dispatched — the PR's head or base moved, a commit in the reviewed range moved, or the working tree was edited — the retry is a new review and the other reviewers' verdicts belong to the old state. Say so and ask the user whether to re-run the whole batch; do not present a verdict for the new state beside verdicts for the old one.
6. **Rounds.** For §6, one round is one batch against one revision together with its retries. A new round starts only after a fix.

## 2 · Dispatch

One Bash call per review. `ask-reviewer.sh` is on the plugin's `bin/` PATH while the plugin is active. **Every call passes `--summary` first**, so stdout is one JSON document instead of the transcript (§3). **Wrap FOCUS in double quotes** so it stays a single positional argument; the `--with-*` flag pairs go through as their own argv slots.

If `pr-context.sh` is not found (the shell's `command not found`, status 127), or `ask-reviewer.sh` exits 2 with exactly `error: unknown option: --summary`, the dev-trio on this session's PATH is older than this skill. Tell the user to update the plugin and start a new session, and stop. Any other failure of either script is not this case.

A review takes minutes, not seconds: over 319 measured Codex reviews the median was about 3 minutes and one in ten took more than 11; an agy reviewer is slower. That is past the Bash tool's default timeout (2 minutes) and sometimes past its cap (10 minutes). **Run the call with `run_in_background: true`** and wait for its completion notice. Do not poll it, and do not edit the files under review while it runs.

Concrete shapes (these are what you actually invoke):

```bash
ask-reviewer.sh --summary                                                 # empty argument string → default scope
ask-reviewer.sh --summary -- "focus on src/agent.py concurrency"          # focus only
ask-reviewer.sh --summary --with-research notes.md -- "concurrency focus" # flag written before the focus
ask-reviewer.sh --summary --with-spec docs/auth.md -- "focus on auth flow"  # flag written after the focus
ask-reviewer.sh --summary --with-spec docs/rfcs/0004.md --with-research notes.md -- "review against the spec"
ask-reviewer.sh --summary --no-memories -- "fresh-eyes pass over the branch"   # no Codex memory summary
ask-reviewer.sh --summary --model agy -- "second opinion on the parser"   # a different reviewer for this call
ask-reviewer.sh --summary --model codex                                   # default scope, chosen model
```

Worked example — the argument string is `focus on src/agent.py concurrency --with-spec docs/agent.md`:

1. Tokens: `focus on src/agent.py concurrency --with-spec docs/agent.md`
2. `--with-spec` consumes itself + `docs/agent.md` → SPEC = `docs/agent.md`
3. Remaining tokens joined → FOCUS = `focus on src/agent.py concurrency`
4. Invoke: `ask-reviewer.sh --summary --with-spec docs/agent.md -- "focus on src/agent.py concurrency"`

**When the dev-trio layout is up (`/dev-trio:bootstrap`), streaming output is already visible in the bottom-right pane — do not duplicate it in the chat.** With several reviewers that pane follows only the most recent run. Acknowledge that it's running and wait.

## 3 · Surface the verdict after completion

When the completion notice arrives, read the call's output file once. It holds stdout and stderr in the order they were written, then `[exited with code N]`.

The wrapper reports exact paths for this invocation in the last stderr line that starts with `(log:` (a notice can follow it):

```text
(log: .../reviewer-<TS>-<PID>.log, final: .../reviewer-<TS>-<PID>.final.md, result: .../reviewer-<TS>-<PID>.review.json, rc=...)
```

**Fast path.** Use the summary when all of these hold: exactly one line starts with `{"summary_version":1`, it parses as JSON, its `result` is not `null`, and its `paths.result` equals the `result:` path in that `(log:` line. Its `result` is then that `.review.json` as published, so apply every rule below to it instead of reading the file. The path check matters because stderr shares the output file and can print paths the user supplied. In every other case, read the file.

**Otherwise read that exact `.review.json` result.** It is the common parsed result used by the wrapper, manifest and dashboard. Do not independently parse verdicts or count bullets in Markdown. Do not resolve `latest` links after completion: another invocation may already have retargeted them.

- `status: "ok"`, `invocation_rc: 0`, `exit_code: 0`: use `verdict` (`SHIP`, `NEEDS-FIX`, `DISCUSS`) and quote `verdict_line` verbatim. The canonical `TOKEN — reason` and observed `TOKEN. reason` and `TOKEN: reason` forms share the same normalized token.
- `findings.blocker`, `.major`, `.minor`: arrays of real finding bullets; count their entries. `null` means that section is missing, so report its count as **unknown**, not zero. `- None.` / `- none` placeholders (case-insensitive, optional final period) and Korean `- 없음` / `- 없음.` placeholders, including those with trailing whitespace, have already been excluded.
- `status: "parse-failed"`: the reviewer process succeeded but its final response could not be parsed. The wrapper exits **3**. Report `error` and the artifact paths; the manifest verdict remains `null`. With `invocation_rc: 0` the review finished but broke the output format (#125): re-run it once under the **Retry rule** below and report both runs' artifact paths. If the code under review changed in between, that is a new review, not a retry; if the retry fails to parse too, stop and report both. Never read a verdict or counts out of the final.
- An empty marker mixed with finding bullets in the same severity, including repeated headings, is a parse failure. Resolved explanations belong under `## What I checked`. Report the failure rather than interpreting the bullets or clearing counts because the Markdown says `SHIP`.
- Findings use `- ` bullets at column 0; an item indented 1–3 spaces directly under a finding is joined onto that finding. Other list items with text (including empty markers) fail parsing with 1–3-space indentation, `*` / `+` / numbered markers, or a tab separator after `-`. Whitespace-only list items are ignored. Quoted and code examples stay excluded; other prose is not parsed as findings. Report format failures as unknown findings, not zero findings.
- `status: "permission-denied"`: headless agy auto-denied a tool and produced no review. The wrapper exits **3**. Report each entry of `denied` (a target agy recorded as denied, e.g. `command(git rev-parse --show-toplevel)`; agy 1.2.9 ignores `unsandboxed(...)` rules; empty means agy recorded none) and `conversation_ids`, and point to the README section "Resolve a confirmed agy permission denial". A `read_file(<path>)` entry is a path to check (outside the workspace? does it exist?), not a rule to add. Note that if a denied `command(git ...)` target contains backticks (`` ` ``), `$()`, or shell operators (even inside `"..."`), agy's `unquoted_shell_operators` check prevented the `command(git ...)` prefix rule from matching rather than missing the base rule. Do not grant anything yourself, and do not re-run with a broader permission.
- `status: "invocation-failed"`: the reviewer invocation failed. The wrapper preserves its nonzero exit code and records no verdict, even if its output contains a plausible one.

If the result is missing or unreadable, report the verdict and findings as unavailable. The raw `.log` is diagnostic evidence, never a fallback source of a verdict. The `.final.md` stays unchanged: native final capture is used when available; only adapters without it synthesize a final from this invocation's output.

Color the framing — 🟢 SHIP / 🔴 NEEDS-FIX / 🟡 DISCUSS — to match the dashboard. On either failure status, surface the failure instead of the success summary below.

**Surface to user** in chat (≤200 words):
- Verdict line (quoted, with color emoji)
- Findings: `<N> blocker · <M> major · <K> minor`
- Blocker + Major bullets in full (these are actionable; the user needs to see them)
- Skip Minor/Nit unless the user asks — they're noise at this layer
- Log path link

## 4 · Handle `## NEED RESEARCH` blocks

If the final of the same successful invocation contains a `## NEED RESEARCH` section after the verdict, Codex needs Antigravity's help before the review can finalize. Read that final from the summary's `final_text` when §3 took the fast path and `final_text` is not `null`; otherwise read the exact `.final.md` path that invocation reported (`final:` in its `(log:` line). A result read from the file gets this check too. Do this:

1. Surface the questions to the user. Confirm before fetching (research costs latency and tokens).
2. On confirmation, run each question through `ask-researcher.sh` and concatenate the answers into a temp file. Run the loop below as one background Bash call (§2): several research calls in a row can outlast a foreground call. `ask-researcher.sh` prints only the answer on stdout (the `=== RESPONSE ===` markers go to its log file), and exits with the researcher's rc:
   ```bash
   RTS=$(date +%Y%m%d-%H%M%S)
   RFILE="$PWD/.dev-trio/log/${AGENT_TEAM:-default}/research-$RTS.md"
   mkdir -p "$(dirname "$RFILE")"
   RESEARCH_FAILED=0
   {
     echo "# Research for codex review @ $RTS"
     for q in "<question 1>" "<question 2>"; do
       echo; echo "## Q: $q"; echo
       # </dev/null: ask-researcher.sh reads a non-terminal stdin as extra context.
       if ! ask-researcher.sh "$q" </dev/null; then
         RESEARCH_FAILED=1
         echo "(research failed for this question — see the ask-researcher log; do not treat the text above as findings)"
       fi
     done
   } > "$RFILE"
   # The last two lines are what the background call reports back.
   echo "RFILE=$RFILE RESEARCH_FAILED=$RESEARCH_FAILED"
   [ "$RESEARCH_FAILED" -eq 0 ]
   ```
   If `RESEARCH_FAILED=1`, tell the user which question failed before re-reviewing; don't present the failed output to Codex as evidence (drop that section or re-run it).
3. Re-invoke under the **Retry rule** below with `<RFILE>` as the research attachment (merged with any research file the original call had).
4. Use the second verdict as the actionable one. Mention the round-trip to the user (Antigravity → Codex re-review) so they understand why latency was higher.

## 4b · Handle `## NEED CONTEXT` blocks

A `## NEED CONTEXT` section lists repository facts the reviewer could not fetch, as commands. Look for it in the same successful invocation's final, read as in §4. Antigravity cannot answer these; you can.

1. Surface the commands to the user with one line each on why the reviewer needs it.
2. Run only read-only commands yourself: `gh pr view`, `gh pr diff`, `gh pr checks`, `gh issue view`, `gh run view` (including `--log-failed`), `git log`, `git show`. Ask before anything that changes state, including `git fetch`, and never run a command that writes to the remote.
3. Write each command and its output (or its failure, labelled as such) to a new context file for this retry. If the review had `--with-context`, start the new file with a copy of that one. Never edit a file that a finished or still-running review was given.
4. Re-invoke once under the retry rule below. If the second review still asks for the same context, stop and report it; do not loop.

## Retry rule (NEED RESEARCH, NEED CONTEXT, format failure)

A retry re-reviews the **same scope**, with more evidence when the review asked for it:

- Same focus (still after `--`), and every flag the original call had: `--summary`, `--model`, `--with-spec`, `--with-research`, `--with-context`, `--no-memories`.
- Attachments are cumulative. The wrapper takes one file per kind, so a second `--with-research` replaces the first — write the previous content plus the new answers into one new file and pass that.
- Check before every retry whether the PR's head or base commit moved since the first review (`gh pr view` shows different IDs). If it did, that is a new review, not a retry: drop the old context, resolve the PR again, and say so to the user. With several reviewers, stop instead and ask first (**Several reviewers**, item 5).

## 5 · Don't auto-fix

Codex's NEEDS-FIX findings are **suggestions**, not fix orders. After surfacing, **wait for the user** to direct what to address. Don't open Edit calls yourself unless the user explicitly says "fix them all" / "address the blockers" / etc.

## 6 · Track *where* findings land, not just how many

Repeat rounds earn their keep — a second and third round routinely catch regressions the first round's fixes introduced. But watch the distribution. **When a new round lands fresh findings in the same unit (as defined below) the previous round already fixed, that is a signal about whether the code should exist, not about whether it is correct.** It compounds: each fix is written on the assumption that the thing belongs there, so the surface grows.

**The trigger:** two consecutive review → fix cycles on the same change in which each round's *fresh* findings land in the same unit — one function, helper, or class, named by the findings themselves. A fix that only renames the unit keeps its identity; if a fix splits it, follow the part that holds the logic the earlier findings were about. Group by file only when the file is that one unit. Findings repeated unchanged, and a NEED RESEARCH re-review (§4) that has no fix in between, do not count as a round. When the trigger fires, do not dispatch a third round. Answer:

- **Is a tested library already doing this?** Hand-rolled canonicalisation, diffing, parsing, and date handling are the usual suspects.
- **What is the actual gap?** It is almost always *adapting the inputs* — making two things comparable — not reimplementing the algorithm.
- **What would deleting it cost?** If the answer is "a short adapter", that is the replacement to propose.

Individual findings ask whether each piece is correct. The PM has to ask the separate question of whether the unit should exist. Surface it to the user with the finding distribution as evidence ("rounds 1-2 produced N findings, all in `<unit>`"), propose the replacement if there is one, and **wait for the user's direction** (§5) before deleting or rewriting anything.

If the user approves a replacement: deleting code you have already fixed round after round is not waste. The fixes are the evidence that produced the decision, and the minimal reproductions they generated are the regression suite for the replacement — **replay them against the new code** and report which ones changed behaviour deliberately, so a narrowing is declared rather than implied.

## Constraints

- **Do not call `codex` directly.** `ask-reviewer.sh` is the only entry point — it handles role-prompt loading, trust-boundary tag stripping, `codex exec --output-last-message` capture, and RFC 0004 manifest emission (`dev-trio-review` variant).
- **Use this invocation's summary `result`, or the exact `.review.json` path it printed.** The wrapper, manifest and dashboard share this parsed result. Missing/failed results mean the verdict is unavailable; never infer it from raw logs, prompt examples or `latest` artifacts.
- **Only an `ok` result carries a verdict.** Invocation and parse failures retain `null`; a token found in prose or a role-prompt example is not a review result.
- **Do not paste the full Codex output back to chat.** Verdict line + Blocker/Major bullets only. The full text is in the pane and on disk.
