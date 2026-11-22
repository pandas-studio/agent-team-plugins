---
name: review
description: One-shot Codex review. Default scope = uncommitted working-tree changes. Optional --with-research <file>, --with-spec <file> and --with-context <file> for context injection. Streaming output lands in the bottom-right dashboard pane; chat-side surfaces the verdict (SHIP/NEEDS-FIX/DISCUSS) + Blocker/Major counts and handles NEED RESEARCH and NEED CONTEXT blocks.
disable-model-invocation: true
allowed-tools: Bash(ask-reviewer.sh:*) Bash(ask-researcher.sh:*) Bash(agent-team-models:*) Bash(gh pr view:*) Bash(gh pr diff:*) Bash(gh pr checks:*) Bash(gh issue view:*) Bash(gh run view:*) Bash(git:*) Bash(cat:*) Bash(ls:*) Bash(date:*) Bash(mkdir:*) Bash(echo:*) Bash(sed:*) Read
argument-hint: "[focus] [-m|--model <id>[,<id>...]] [--with-research <file>] [--with-spec <file>] [--with-context <file>] [--no-memories] [-- <focus>]"
---

# Review (Codex, one-shot)

You are the **PM**. Codex is the reviewer (bottom-right pane). You dispatch one review, surface the verdict, and route a `NEED RESEARCH` block through Antigravity and a `NEED CONTEXT` block through your own read-only `gh`/`git` commands.

## Arguments

<arguments>
$ARGUMENTS
</arguments>

Everything between the tags is the argument string the user typed, verbatim. It may be empty.

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

1. Tokenise the argument string on whitespace, walk left-to-right.
2. If a token is `--with-research`, the next token is `<research-file>`; consume both.
3. If a token is `--with-spec`, the next token is `<spec-file>`; consume both.
   Likewise `--with-context` and `<context-file>`.
4. If a token is `--model` or `-m`, the next token is its value: one model id, or a comma list of ids (`agy,codex`). Consume both. Then, while the token that follows is exactly a registered model id, consume it as one more reviewer (`-m agy codex` names two). Only this run of ids ends at the first token that is not a registered id; that token is handled by these steps like any other, so a later `-m` is still an option. `-m`/`--model` may appear more than once. Keep the ids in first-seen order, each once. With one id, dispatch it as `--model <id>`; with several, follow **Several reviewers** below. Dispatch nothing, and tell the user the model id goes in its own token and that focus text containing `-m` belongs after `--`, when: there is no next token; the next token is `--` or is shaped like an option (`-m --with-spec spec.md`); a token is an attached form (`-m=agy`, `--model=agy`); or a comma list has an empty element (`agy,,codex`, `agy,`).
5. If a token is `--no-memories`, pass it through as its own argv slot; consume only it.
6. If a token is `--`, stop: it and nothing after it is an option, so every later token goes to the focus (`--model agy -- --help` reviews the focus `--help`; `-- --model codex` reviews the focus `--model codex`). A focus that mentions `-m`, such as `git commit -m`, must come after `--`, or step 4 reads it as a model option.
7. Every remaining token belongs to the focus; join them with a single space into one FOCUS string.
8. If FOCUS is empty, omit it entirely (the wrapper falls back to the default working-tree scope). Otherwise put the options first and pass the focus last as `-- "$FOCUS"`, so a focus that starts with a dash is never read as an option.
9. If FOCUS names a pull request (`pr 55`, `PR #55`, or a PR URL), resolve it before dispatch — see **PR reviews** below. Never send a bare PR reference as the focus: the reviewer may run without network access, and then cannot tell which commits the PR contains (measured: Codex under `workspace-write` failed `gh pr view` and returned `DISCUSS` with zero findings).

### PR reviews

You have network access; the reviewer may not. Fetch the PR's identity yourself and hand over a concrete range:

```bash
CFILE="$PWD/.dev-trio/log/${AGENT_TEAM:-default}/context-$(date +%Y%m%d-%H%M%S).md"
(umask 077; mkdir -p ".dev-trio/log/${AGENT_TEAM:-default}")
gh pr view 55 --json number,url,title,baseRefName,baseRefOid,headRefName,headRefOid > "$CFILE"
git cat-file -e <headRefOid>^{commit} && git cat-file -e <baseRefOid>^{commit}
git merge-base <baseRefOid> <headRefOid>
```

If either commit is missing locally, tell the user which one and ask before fetching (`git fetch <remote> pull/55/head` for the head — it works for fork PRs — and the base branch from the base repository's remote, which is not necessarily `origin`). Do not fetch without asking. Then dispatch with a range focus:

```bash
ask-reviewer.sh --with-context "$CFILE" -- "review <merge-base>..<headRefOid> (PR #55)"
```

### Several reviewers

The wrapper runs one model per call. When step 4 yields more than one id, you dispatch one call per id.

| Argument string | Reviewers | Focus |
| :--- | :--- | :--- |
| `-m agy codex` | agy, codex | (default scope) |
| `pr 12 -m agy codex` | agy, codex | `pr 12` |
| `-m agy pr 12 -m codex` | agy, codex | `pr 12` |
| `-m agy,codex claude -- codex is slow` | agy, codex, claude | `codex is slow` |
| `-m agy too` | agy | `too` |

A focus that begins with a word that is also a model id goes after `--`.

1. **Validate before the first dispatch.** Whenever a token follows a model value, or more than one id was named, run `agent-team-models list` once: the registered ids are the first column under `Models:` (built-ins such as `codex-no-memories` included). An id given as a `-m` value or inside a comma list that is not registered is an error — dispatch nothing and tell the user. A token after a model value that is not registered is not an error; it is focus. If the command itself fails (exit 3 means the models config is malformed), dispatch nothing and report it.
2. **Dispatch one call per reviewer, in parallel** — one background Bash call each (§2) — with the same focus, the same flags and the same attachment files, differing only in `--model <id>`. For a pull request, resolve it once (**PR reviews** above) and hand the same context file and the same range to every reviewer.
3. **`--no-memories` with several reviewers** goes only on the calls whose id is exactly `codex` or `codex-no-memories`; the wrapper refuses it for any other model. Say in your report which calls carried it. With one reviewer, or with no `-m` at all, pass it through unchanged and let the wrapper decide.
4. **One reviewer failing does not cancel the others.** A usage or setup failure (exit 2), a declined permission prompt or a failed invocation makes that reviewer "no verdict"; let the rest finish and report every reviewer.
5. **Report side by side.** §3 applies to each result: one verdict line and one findings count per reviewer, then every Blocker and Major bullet labelled with its reviewer. Do not merge or de-duplicate findings across reviewers. A `NEED RESEARCH` or `NEED CONTEXT` retry (§4, §4b) re-runs only the reviewer that asked.
6. For §6, the reviewers dispatched together against one revision are **one round**.

## 2 · Dispatch

One Bash call per review. `ask-reviewer.sh` is on the plugin's `bin/` PATH while the plugin is active. **Wrap FOCUS in double quotes** so it stays a single positional argument; the `--with-*` flag pairs go through as their own argv slots.

A review takes minutes, not seconds: over 319 measured Codex reviews the median was about 3 minutes and one in ten took more than 11; an agy reviewer is slower. That is past the Bash tool's default timeout (2 minutes) and sometimes past its cap (10 minutes). **Run the call with `run_in_background: true`** and wait for its completion notice. Do not poll it, and do not edit the files under review while it runs.

Concrete shapes (these are what you actually invoke):

```bash
ask-reviewer.sh                                                 # empty argument string → default scope
ask-reviewer.sh -- "focus on src/agent.py concurrency"          # focus only
ask-reviewer.sh --with-research notes.md -- "concurrency focus" # flag written before the focus
ask-reviewer.sh --with-spec docs/auth.md -- "focus on auth flow"  # flag written after the focus
ask-reviewer.sh --with-spec docs/rfcs/0004.md --with-research notes.md -- "review against the spec"
ask-reviewer.sh --no-memories -- "fresh-eyes pass over the branch"   # no Codex memory summary
ask-reviewer.sh --model agy -- "second opinion on the parser"   # a different reviewer for this call
ask-reviewer.sh --model codex                                   # default scope, chosen model
```

Worked example — the argument string is `focus on src/agent.py concurrency --with-spec docs/agent.md`:

1. Tokens: `focus on src/agent.py concurrency --with-spec docs/agent.md`
2. `--with-spec` consumes itself + `docs/agent.md` → SPEC = `docs/agent.md`
3. Remaining tokens joined → FOCUS = `focus on src/agent.py concurrency`
4. Invoke: `ask-reviewer.sh --with-spec docs/agent.md -- "focus on src/agent.py concurrency"`

**Streaming output is already visible in the bottom-right pane — do not duplicate it in the chat.** Acknowledge that it's running and wait.

## 3 · Surface the verdict after completion

The wrapper reports exact paths for this invocation in its final stderr line:

```text
(log: .../reviewer-<TS>-<PID>.log, final: .../reviewer-<TS>-<PID>.final.md, result: .../reviewer-<TS>-<PID>.review.json, rc=...)
```

**Read that exact `.review.json` result.** It is the common parsed result used by the wrapper, manifest and dashboard. Do not independently parse verdicts or count bullets in Markdown. Do not resolve `latest` links after completion: another invocation may already have retargeted them.

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

If the exact `.final.md` path reported by the same successful invocation contains a `## NEED RESEARCH` section after the verdict, Codex needs Antigravity's help before the review can finalize. Do this:

1. Surface the questions to the user. Confirm before fetching (research costs latency and tokens).
2. On confirmation, run each question through `ask-researcher.sh` and concatenate the answers into a temp file. `ask-researcher.sh` prints only the answer on stdout (the `=== RESPONSE ===` markers go to its log file), and exits with the researcher's rc:
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
   ```
   If `RESEARCH_FAILED=1`, tell the user which question failed before re-reviewing; don't present the failed output to Codex as evidence (drop that section or re-run it).
3. Re-invoke under the **Retry rule** below with `<RFILE>` as the research attachment (merged with any research file the original call had).
4. Use the second verdict as the actionable one. Mention the round-trip to the user (Antigravity → Codex re-review) so they understand why latency was higher.

## 4b · Handle `## NEED CONTEXT` blocks

A `## NEED CONTEXT` section lists repository facts the reviewer could not fetch, as commands. Antigravity cannot answer these; you can.

1. Surface the commands to the user with one line each on why the reviewer needs it.
2. Run only read-only commands yourself: `gh pr view`, `gh pr diff`, `gh pr checks`, `gh issue view`, `gh run view` (including `--log-failed`), `git log`, `git show`. Ask before anything that changes state, including `git fetch`, and never run a command that writes to the remote.
3. Append each command and its output (or its failure, labelled as such) to the context file — the existing one if the review had `--with-context`, a new one otherwise.
4. Re-invoke once under the retry rule below. If the second review still asks for the same context, stop and report it; do not loop.

## Retry rule (NEED RESEARCH, NEED CONTEXT, format failure)

A retry re-reviews the **same scope**, with more evidence when the review asked for it:

- Same focus (still after `--`), and every flag the original call had: `--model`, `--with-spec`, `--with-research`, `--with-context`, `--no-memories`.
- Attachments are cumulative. The wrapper takes one file per kind, so a second `--with-research` replaces the first — write the previous content plus the new answers into one file and pass that.
- If the PR's head or base commit moved since the first review (`gh pr view` shows different IDs), that is a new review, not a retry: drop the old context, resolve the PR again, and say so to the user.

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
- **Use the exact `.review.json` result path printed by this invocation.** The wrapper, manifest and dashboard share this parsed result. Missing/failed results mean the verdict is unavailable; never infer it from raw logs, prompt examples or `latest` artifacts.
- **Only an `ok` result carries a verdict.** Invocation and parse failures retain `null`; a token found in prose or a role-prompt example is not a review result.
- **Do not paste the full Codex output back to chat.** Verdict line + Blocker/Major bullets only. The full text is in the pane and on disk.
