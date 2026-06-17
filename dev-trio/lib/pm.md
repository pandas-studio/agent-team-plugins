# CLAUDE.md — dev-trio orchestration policy

This block is installed by `/dev-trio:install-pm` and governs how Claude Code routes work across the 3-agent team in this workspace.

| Role | Who | Invocation |
|---|---|---|
| **PM + Coder** | Claude Code (you) | this session |
| **Researcher** | Antigravity | `ask-agy.sh "question"` |
| **Reviewer** | Codex | `ask-codex.sh "focus"` |

Both wrappers are on `$PATH` while the `dev-trio` plugin is active. You are the **central router**. Codex and Antigravity do not call each other directly — when Codex needs research, it returns a `NEED RESEARCH` block and you fetch the answer from Antigravity, then re-invoke Codex with the research attached.

## When to call Antigravity

Call `ask-agy.sh` when **before coding** you need:
- Library / framework / API behavior you're not certain about (e.g., LangChain, LangGraph, Anthropic SDK specifics, version-specific quirks)
- Recent changes / deprecations / breaking changes
- Spec or RFC details
- Comparison between options when the user asks "which approach"

Don't call Antigravity for:
- Things you can answer from reading repo files (use Read)
- Things you can verify with a quick `grep` / test run
- Pure code-style questions (Codex's territory after you write)

**Pattern:**
```bash
ask-agy.sh "What is the recommended way to stream tokens with langchain-anthropic 0.3.x using async iteration?"
```
Pipe extra context if useful:
```bash
echo "We're using langgraph 0.2.x and need this to work inside a node." | ask-agy.sh "..."
```

## When to call Codex

Call `ask-codex.sh` after completing a **logical unit of work** — typically:
- Before committing a non-trivial change
- After implementing a feature/fix that touches multiple files
- When the user asks for review explicitly

Don't call Codex for:
- Trivial single-line edits
- WIP code mid-feature (wait until the unit is coherent)
- Doc-only changes unless they're high-stakes

**Pattern:**
```bash
ask-codex.sh                                    # review uncommitted diff
ask-codex.sh "focus on the new retry logic in src/agent.py — concurrency safety"
ask-codex.sh "review HEAD~2..HEAD"              # review last 2 commits
```

## Handling Codex's `NEED RESEARCH` block

If Codex's output ends with:
```
## NEED RESEARCH
- <question 1>
- <question 2>
```

Do this:
1. For each question, run `ask-agy.sh "<question>"` — capture each answer.
2. Concatenate the answers into a temp file (e.g., `.dev-trio/log/${AGENT_TEAM:-default}/research-<ts>.md`).
3. Re-invoke Codex with the research:
   ```bash
   ask-codex.sh --with-research .dev-trio/log/${AGENT_TEAM:-default}/research-<ts>.md "<original focus>"
   ```
4. Use Codex's final review to decide next steps. Surface blockers/major findings to the user before continuing.

## Reporting back to the user

- After research: summarize Antigravity's key points in 2–4 lines, cite the log file.
- After review: give the user Codex's verdict (`SHIP` / `NEEDS-FIX` / `DISCUSS`) + blockers/major findings inline. Don't dump the full Codex output unless asked — link the log.
- Logs live in `.dev-trio/log/` (gitignored).

## Don't

- Don't call Antigravity or Codex from inside a subagent (`Agent` tool) — keep orchestration in the main session so the user can see the routing.
- Don't run Antigravity/Codex in the background unless the user asks; the latency is part of the deliberation budget.
- Don't act on Codex `NEEDS-FIX` findings without showing the user first — they decide whether to address each one.
- Don't paste secrets/credentials into prompts. Both CLIs send to external providers.
