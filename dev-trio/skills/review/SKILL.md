---
description: One-shot Codex review. Default scope = uncommitted working-tree changes. Optional --with-research <file> and --with-spec <file> for context injection. Streaming output lands in the bottom-right dashboard pane; chat-side surfaces the verdict (SHIP/NEEDS-FIX/DISCUSS) + Blocker/Major counts and handles NEED RESEARCH blocks.
disable-model-invocation: true
allowed-tools: Bash(ask-codex.sh:*) Bash(ask-agy.sh:*) Bash(git:*) Bash(cat:*) Bash(ls:*) Bash(date:*) Bash(mkdir:*) Bash(echo:*) Bash(sed:*) Read
argument-hint: [focus] [--with-research <file>] [--with-spec <file>]
---

# Review (Codex, one-shot)

You are the **PM**. Codex is the reviewer (bottom-right pane). You dispatch one review, surface the verdict, and route any `NEED RESEARCH` block back through Antigravity.

## 1 · Parse `$ARGUMENTS` and build the dispatch command

`$ARGUMENTS` is a single string that may interleave three pieces in any order:

- **Optional `--with-research <file>`** — research context from a previous Antigravity call (typically `latest-agy.log` or a curated `research-<TS>.md`).
- **Optional `--with-spec <file>`** — spec/contract the changes are expected to satisfy.
- **Optional free-form focus** — review scope, possibly multi-word. Examples:
  - `focus on the new retry logic in src/agent.py — concurrency safety`
  - `review HEAD~2..HEAD`
  - `review only the changes to src/auth/`

**You must parse `$ARGUMENTS` yourself and assemble the bash command with explicit shell quoting.** Do NOT write `ask-codex.sh $ARGUMENTS` — unquoted expansion word-splits the focus across multiple shell args, and `ask-codex.sh` rejects extra positionals with rc=2.

Algorithm:

1. Tokenise `$ARGUMENTS` on whitespace, walk left-to-right.
2. If a token is `--with-research`, the next token is `<research-file>`; consume both.
3. If a token is `--with-spec`, the next token is `<spec-file>`; consume both.
4. Every remaining token belongs to the focus; join them with a single space into one FOCUS string.
5. If `$ARGUMENTS` is empty, omit the focus entirely (the wrapper falls back to the default working-tree scope).

## 2 · Dispatch

Single Bash call (blocking, ~30–120 s depending on diff size). `ask-codex.sh` is on the plugin's `bin/` PATH while the plugin is active. **Wrap FOCUS in double quotes** so it stays a single positional argument; the `--with-*` flag pairs go through as their own argv slots.

Concrete shapes (these are what you actually invoke):

```bash
ask-codex.sh                                              # $ARGUMENTS empty → default scope
ask-codex.sh "focus on src/agent.py concurrency"          # focus only
ask-codex.sh --with-research notes.md "concurrency focus" # flag before focus
ask-codex.sh "focus on auth flow" --with-spec docs/auth.md  # flag after focus
ask-codex.sh --with-spec docs/rfcs/0004.md --with-research notes.md "review against the spec"
```

Worked example — if `$ARGUMENTS = "focus on src/agent.py concurrency --with-spec docs/agent.md"`:

1. Tokens: `focus on src/agent.py concurrency --with-spec docs/agent.md`
2. `--with-spec` consumes itself + `docs/agent.md` → SPEC = `docs/agent.md`
3. Remaining tokens joined → FOCUS = `focus on src/agent.py concurrency`
4. Invoke: `ask-codex.sh --with-spec docs/agent.md "focus on src/agent.py concurrency"`

**Streaming output is already visible in the bottom-right pane — do not duplicate it in the chat.** Acknowledge that it's running and wait.

## 3 · Surface the verdict after completion

The wrapper writes two artifacts per run:

```
$PWD/.dev-trio/log/<team>/codex-<TS>.final.md   ← Codex's final structured review (authoritative)
$PWD/.dev-trio/log/<team>/latest-codex.final.md → symlink to the above
$PWD/.dev-trio/log/<team>/codex-<TS>.log        ← full streamed transcript
$PWD/.dev-trio/log/<team>/latest-codex.log      → symlink to the above
```

**Parse the verdict and findings from `latest-codex.final.md`, not the streamed log.** That file is `codex exec --output-last-message` output — Codex's last assistant message captured verbatim, so it always contains the complete `## Verdict` / `## Findings` block. The streamed `.log` is the full transcript and a fallback only: depending on the execution path its tail can duplicate or drop the closing block (the original failure mode this skill hit), which is exactly why verdict extraction moved off it.

**Verdict line** — Codex emits a canonical 3-token verdict per the role spec (`## Verdict`, then `<SHIP|NEEDS-FIX|DISCUSS> — reason` on the next line). Anchor on the canonical-token line:

```bash
grep -A 1 '^## Verdict$' .dev-trio/log/<team>/latest-codex.final.md \
  | grep -hE '^(SHIP|NEEDS-FIX|DISCUSS)( |—|$)' | tail -1
```

If `latest-codex.final.md` is empty or missing — Codex died before emitting its review; the wrapper prints a `final-message file is empty` warning to stderr in that case — fall back to the `=== RESPONSE ===` section of `latest-codex.log` and say so when you surface the result.

Quote the verdict line verbatim. Color the framing — 🟢 SHIP / 🔴 NEEDS-FIX / 🟡 DISCUSS — matches what the dashboard renders.

**Findings counts** — from the same `latest-codex.final.md`, count `^- ` bullets under each `### Blocker` / `### Major` / `### Minor` heading, skipping `- none` placeholders.

**Surface to user** in chat (≤200 words):
- Verdict line (quoted, with color emoji)
- Findings: `<N> blocker · <M> major · <K> minor`
- Blocker + Major bullets in full (these are actionable; the user needs to see them)
- Skip Minor/Nit unless the user asks — they're noise at this layer
- Log path link

## 4 · Handle `## NEED RESEARCH` blocks

If `latest-codex.final.md` contains a `## NEED RESEARCH` section after the verdict, Codex needs Antigravity's help before the review can finalize. Do this:

1. Surface the questions to the user. Confirm before fetching (research costs latency and tokens).
2. On confirmation, run each question through `ask-agy.sh` and concatenate the answers into a temp file:
   ```bash
   RTS=$(date +%Y%m%d-%H%M%S)
   RFILE="$PWD/.dev-trio/log/${AGENT_TEAM:-default}/research-$RTS.md"
   mkdir -p "$(dirname "$RFILE")"
   {
     echo "# Research for codex review @ $RTS"
     for q in "<question 1>" "<question 2>"; do
       echo; echo "## Q: $q"; echo
       ask-agy.sh "$q" | sed -n '/^=== RESPONSE ===/,/^=== END /p' | sed '1d;$d'
     done
   } > "$RFILE"
   ```
3. Re-invoke `ask-codex.sh --with-research <RFILE>` with the **same focus** as the original call.
4. Use the second verdict as the actionable one. Mention the round-trip to the user (Antigravity → Codex re-review) so they understand why latency was higher.

## 5 · Don't auto-fix

Codex's NEEDS-FIX findings are **suggestions**, not fix orders. After surfacing, **wait for the user** to direct what to address. Don't open Edit calls yourself unless the user explicitly says "fix them all" / "address the blockers" / etc.

## Constraints

- **Do not call `codex` directly.** `ask-codex.sh` is the only entry point — it handles role-prompt loading, trust-boundary tag stripping, `codex exec --output-last-message` capture, and RFC 0004 manifest emission (`dev-trio-review` variant).
- **Parse from `latest-codex.final.md`, not the streamed `.log`.** The `.final.md` is `--output-last-message` output (Codex's final message verbatim); the streamed `.log` can duplicate or truncate the closing block. Fall back to the `.log` only when the `.final.md` is empty/missing, and flag the degraded path when you do.
- **Verdict extraction must anchor on the canonical token regex** above. Codex echoes the role-prompt's `<one of: SHIP / NEEDS-FIX / DISCUSS>` placeholder when the run errors before emitting `tokens used` — un-anchored matchers will surface the placeholder as a real verdict.
- **Do not paste the full Codex output back to chat.** Verdict line + Blocker/Major bullets only. The full text is in the pane and on disk.
