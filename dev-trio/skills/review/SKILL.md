---
description: One-shot Codex review. Default scope = uncommitted working-tree changes. Optional --with-research <file> and --with-spec <file> for context injection. Streaming output lands in the bottom-right dashboard pane; chat-side surfaces the verdict (SHIP/NEEDS-FIX/DISCUSS) + Blocker/Major counts and handles NEED RESEARCH blocks.
disable-model-invocation: true
allowed-tools: Bash(ask-codex.sh:*) Bash(ask-agy.sh:*) Bash(git:*) Bash(cat:*) Bash(ls:*) Bash(date:*) Bash(mkdir:*) Bash(echo:*) Bash(sed:*) Read
argument-hint: [focus] [--with-research <file>] [--with-spec <file>] [--no-memories]
---

# Review (Codex, one-shot)

You are the **PM**. Codex is the reviewer (bottom-right pane). You dispatch one review, surface the verdict, and route any `NEED RESEARCH` block back through Antigravity.

## 1 · Parse `$ARGUMENTS` and build the dispatch command

`$ARGUMENTS` is a single string that may interleave four pieces in any order:

- **Optional `--with-research <file>`** — research context from a previous Antigravity call (typically `latest-agy.log` or a curated `research-<TS>.md`).
- **Optional `--with-spec <file>`** — spec/contract the changes are expected to satisfy.
- **Optional `--no-memories`** — bare flag; Codex runs without its memory summary from earlier sessions.
- **Optional free-form focus** — review scope, possibly multi-word. Examples:
  - `focus on the new retry logic in src/agent.py — concurrency safety`
  - `review HEAD~2..HEAD`
  - `review only the changes to src/auth/`

**You must parse `$ARGUMENTS` yourself and assemble the bash command with explicit shell quoting.** Do NOT write `ask-codex.sh $ARGUMENTS` — unquoted expansion word-splits the focus across multiple shell args, and `ask-codex.sh` rejects extra positionals with rc=2.

Algorithm:

1. Tokenise `$ARGUMENTS` on whitespace, walk left-to-right.
2. If a token is `--with-research`, the next token is `<research-file>`; consume both.
3. If a token is `--with-spec`, the next token is `<spec-file>`; consume both.
4. If a token is `--no-memories`, pass it through as its own argv slot; consume only it.
5. Every remaining token belongs to the focus; join them with a single space into one FOCUS string.
6. If `$ARGUMENTS` is empty, omit the focus entirely (the wrapper falls back to the default working-tree scope).

## 2 · Dispatch

Single Bash call (blocking, ~30–120 s depending on diff size). `ask-codex.sh` is on the plugin's `bin/` PATH while the plugin is active. **Wrap FOCUS in double quotes** so it stays a single positional argument; the `--with-*` flag pairs go through as their own argv slots.

Concrete shapes (these are what you actually invoke):

```bash
ask-codex.sh                                              # $ARGUMENTS empty → default scope
ask-codex.sh "focus on src/agent.py concurrency"          # focus only
ask-codex.sh --with-research notes.md "concurrency focus" # flag before focus
ask-codex.sh "focus on auth flow" --with-spec docs/auth.md  # flag after focus
ask-codex.sh --with-spec docs/rfcs/0004.md --with-research notes.md "review against the spec"
ask-codex.sh --no-memories "fresh-eyes pass over the branch"   # no Codex memory summary
```

Worked example — if `$ARGUMENTS = "focus on src/agent.py concurrency --with-spec docs/agent.md"`:

1. Tokens: `focus on src/agent.py concurrency --with-spec docs/agent.md`
2. `--with-spec` consumes itself + `docs/agent.md` → SPEC = `docs/agent.md`
3. Remaining tokens joined → FOCUS = `focus on src/agent.py concurrency`
4. Invoke: `ask-codex.sh --with-spec docs/agent.md "focus on src/agent.py concurrency"`

**Streaming output is already visible in the bottom-right pane — do not duplicate it in the chat.** Acknowledge that it's running and wait.

## 3 · Surface the verdict after completion

The wrapper reports exact paths for this invocation in its final stderr line:

```text
(log: .../codex-<TS>-<PID>.log, final: .../codex-<TS>-<PID>.final.md, result: .../codex-<TS>-<PID>.review.json, rc=...)
```

**Read that exact `.review.json` result.** It is the common parsed result used by the wrapper, manifest and dashboard. Do not independently parse verdicts or count bullets in Markdown. Do not resolve `latest` links after completion: another invocation may already have retargeted them.

- `status: "ok"`, `invocation_rc: 0`, `exit_code: 0`: use `verdict` (`SHIP`, `NEEDS-FIX`, `DISCUSS`) and quote `verdict_line` verbatim. The canonical `TOKEN — reason` and observed `TOKEN. reason` forms share the same normalized token.
- `findings.blocker`, `.major`, `.minor`: arrays of real finding bullets; count their entries. `null` means that section is missing, so report its count as **unknown**, not zero. Exact `- None.` / `- none` placeholders (case-insensitive, optional final period) and exact Korean `- 없음` / `- 없음.` placeholders have already been excluded.
- `status: "parse-failed"`: the reviewer process succeeded but its final response could not be parsed. The wrapper exits **3**. Report `error` and the artifact paths; the manifest verdict remains `null`.
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
2. On confirmation, run each question through `ask-agy.sh` and concatenate the answers into a temp file. `ask-agy.sh` prints only the answer on stdout (the `=== RESPONSE ===` markers go to its log file), and exits with the researcher's rc:
   ```bash
   RTS=$(date +%Y%m%d-%H%M%S)
   RFILE="$PWD/.dev-trio/log/${AGENT_TEAM:-default}/research-$RTS.md"
   mkdir -p "$(dirname "$RFILE")"
   RESEARCH_FAILED=0
   {
     echo "# Research for codex review @ $RTS"
     for q in "<question 1>" "<question 2>"; do
       echo; echo "## Q: $q"; echo
       # </dev/null: ask-agy.sh reads a non-terminal stdin as extra context.
       if ! ask-agy.sh "$q" </dev/null; then
         RESEARCH_FAILED=1
         echo "(research failed for this question — see the ask-agy log; do not treat the text above as findings)"
       fi
     done
   } > "$RFILE"
   ```
   If `RESEARCH_FAILED=1`, tell the user which question failed before re-reviewing; don't present the failed output to Codex as evidence (drop that section or re-run it).
3. Re-invoke `ask-codex.sh --with-research <RFILE>` with the **same focus** as the original call, plus `--no-memories` if the original call had it.
4. Use the second verdict as the actionable one. Mention the round-trip to the user (Antigravity → Codex re-review) so they understand why latency was higher.

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

- **Do not call `codex` directly.** `ask-codex.sh` is the only entry point — it handles role-prompt loading, trust-boundary tag stripping, `codex exec --output-last-message` capture, and RFC 0004 manifest emission (`dev-trio-review` variant).
- **Use the exact `.review.json` result path printed by this invocation.** The wrapper, manifest and dashboard share this parsed result. Missing/failed results mean the verdict is unavailable; never infer it from raw logs, prompt examples or `latest` artifacts.
- **Only an `ok` result carries a verdict.** Invocation and parse failures retain `null`; a token found in prose or a role-prompt example is not a review result.
- **Do not paste the full Codex output back to chat.** Verdict line + Blocker/Major bullets only. The full text is in the pane and on disk.
