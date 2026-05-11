---
description: One-shot Gemini research call. Use when before coding you need library/API behavior, recent changes, spec details, or option comparisons. Streaming output lands in the top-right dashboard pane; chat-side surfaces the lead paragraph + cited URL count.
disable-model-invocation: true
allowed-tools: Bash(ask-gemini.sh:*) Bash(cat:*) Bash(ls:*) Read
argument-hint: <research question>
---

# Research (Gemini, one-shot)

You are the **PM**. Gemini is the researcher (top-right pane). You dispatch one call, then surface the lead.

## 1 · Resolve the question

`$ARGUMENTS` is the research question, free-form.

- **Empty** → ask the user what to research. Do not proceed without a question.
- **Non-empty** → pass `$ARGUMENTS` verbatim to `ask-gemini.sh` as a single argument. Do not paraphrase or "improve" it.

## 2 · Dispatch

Single Bash call (blocking, ~10–60 s depending on the query). `ask-gemini.sh` is on the plugin's `bin/` PATH while the plugin is active — call it bare (no absolute path).

```bash
ask-gemini.sh "<the user's question, verbatim>"
```

To pipe extra context (e.g., your own grep results):

```bash
echo "<context bullets>" | ask-gemini.sh "<question>"
```

**Streaming output is already visible in the top-right pane — do not duplicate it in the chat.** Just acknowledge that it's running and wait.

## 3 · Surface the lead after completion

The wrapper writes:

```
$PWD/.dev-trio/log/<team>/gemini-<TS>.log
$PWD/.dev-trio/log/<team>/latest-gemini.log   → symlink
```

Use `cat` or `Read` on `latest-gemini.log`. Then surface, in chat:

- **Lead paragraph** — the first non-empty paragraph of Gemini's `=== RESPONSE ===` section. One short block, verbatim.
- **Sources cited** — count of `https?://` URLs in the response; list up to 3.
- **Log path** — link the absolute path so the user can scroll the full output if needed.

Keep the chat-side summary under ~150 words. The full output is in the pane and on disk; don't paste it back.

## 4 · Hand off if applicable

If the user's broader intent was code-then-review, suggest the natural next step:

> Want me to feed this into a Codex review? `/dev-trio:review --with-research <log-path> "<focus>"`

But don't dispatch automatically — let the user confirm.

## Constraints

- **Do not call `gemini` directly.** `ask-gemini.sh` is the only entry point — it handles role-prompt loading, trust-boundary tag stripping, and RFC 0004 manifest emission.
- **Do not paste the full Gemini response back to chat.** The user has it in the pane and on disk; surface only the lead + cite count.
- **Do not silently retry on a non-zero rc.** Surface the failure to the user (the wrapper logs `rc=N` in its `=== END ===` line); ask before re-running.
