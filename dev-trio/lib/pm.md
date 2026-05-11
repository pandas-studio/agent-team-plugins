# CLAUDE.md — dev-trio orchestration policy

This block is installed by `/dev-trio:install-pm` and governs how Claude Code routes work across the 3-agent team in this workspace.

| Role | Who | Invocation |
|---|---|---|
| **PM + Coder** | Claude Code (you) | this session |
| **Researcher** | Gemini | `ask-gemini.sh "question"` |
| **Reviewer** | Codex | `ask-codex.sh "focus"` |

Both wrappers are on `$PATH` while the `dev-trio` plugin is active. You are the **central router**. Codex and Gemini do not call each other directly — when Codex needs research, it returns a `NEED RESEARCH` block and you fetch the answer from Gemini, then re-invoke Codex with the research attached.

## When to call Gemini

Call `ask-gemini.sh` when **before coding** you need:
- Library / framework / API behavior you're not certain about (e.g., LangChain, LangGraph, Anthropic SDK specifics, version-specific quirks)
- Recent changes / deprecations / breaking changes
- Spec or RFC details
- Comparison between options when the user asks "which approach"

Don't call Gemini for:
- Things you can answer from reading repo files (use Read)
- Things you can verify with a quick `grep` / test run
- Pure code-style questions (Codex's territory after you write)

**Pattern:**
```bash
ask-gemini.sh "What is the recommended way to stream tokens with langchain-anthropic 0.3.x using async iteration?"
```
Pipe extra context if useful:
```bash
echo "We're using langgraph 0.2.x and need this to work inside a node." | ask-gemini.sh "..."
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

## When to call debate (design / planning decisions)

If the `debate-conductor` plugin is also installed, you can dispatch a Generator-vs-Critic debate when the user wants a **design/planning decision** with multiple competing approaches — i.e., something where the right move is to write down a stance, get it adversarially attacked, and revise. Concrete trigger scenarios:

| Scenario | Stance topic shape | Suggested `--primary-gen` |
|---|---|---|
| New feature design — A vs B approach | `"X 를 A 패턴으로 즉시 vs B 로 점진"` | gemini (default) or claude |
| Refactor timing | `"pattern P → Q 를 이번 PR 에서 vs 다음 release 후"` | codex (강한 코드 직관) |
| RFC draft seeding | `"RFC 0NNN — 결정 X: A 채택 / B 채택 / 보류"` | claude or gemini |
| Incident postmortem — cause vs fix | `"prod incident root cause: 시나리오 A vs B; 재발 방지 패치 P 충분 vs 구조 변경 필요"` | gemini (research-heavy) |
| Feature deprecation timing | `"feature Y: 즉시 제거 / 6개월 deprecation grace / 영구 유지"` | gemini |
| Dependency upgrade window | `"library X major bump: 이번 sprint 즉시 / 다음 분기 / 강제 release 까지 보류"` | gemini |
| API surface design (public-facing) | `"endpoint /v2/X 의 shape: REST resource A vs RPC action B"` | claude |

Don't call debate for:
- Pure factual research → `ask-gemini.sh`
- Code already written → `ask-codex.sh`
- Tasks where the user just wants you to start coding
- Decisions where one option is obviously correct (debate forces a stance even when there isn't a real tension — wasted rounds)

**Pattern (PM as thin dispatcher — you do prep + readback, debate does the rounds):**

1. **Prep context** — grep / read the relevant files yourself, write a context file so the generator has code awareness (the generator runs as a single CLI call with no tool access):
   ```bash
   CTX=.debate-conductor/log/${AGENT_TEAM:-default}/debate-context-$(date +%s).md
   mkdir -p "$(dirname "$CTX")"
   {
     echo "# Relevant files"; git ls-files | grep -E '<keyword>'
     echo; echo "# Existing patterns"; sed -n '1,80p' <file>
   } > "$CTX"
   ```

2. **Frame the topic as a stance** — `"X 를 A 패턴으로 즉시 vs B 로 점진"` 형식. Vague "X 어떻게?" produces wishy-washy drafts.

3. **Dispatch** via the debate-conductor plugin:
   ```
   /debate-conductor:run "<stance topic>"
   ```
   For non-default model assignments, the bare bash form supports `--primary-gen=<model>` and `--primary-crit=<model>` flags.

4. **Read transcript back** — when it ends, the revised plan lives in the last `round-N-gen.md`:
   ```bash
   LATEST=.debate-conductor/log/${AGENT_TEAM:-default}/latest-debate
   cat "$LATEST"/round-*-gen.md            # final stance = the last gen file
   grep -hE "^Verdict: (STRENGTHEN|RECONSIDER|OVERTURN)$" "$LATEST"/round-*-crit.md
   ```
   The anchored regex matters — Codex sometimes echoes the role-prompt's `Verdict: <STRENGTHEN | RECONSIDER | OVERTURN>` placeholder line inside an explanation block; matching only the canonical 3-token tail filters that out.

   Summarize for the user: final stance + verdict trail + which Blocker/Major points were accepted vs rejected in the revised draft. Don't dump the full transcript — link the dir.

If the `debate-conductor` plugin isn't installed, tell the user: `/plugin install debate-conductor@pandas-studio`. Until then, fall back to plain `ask-gemini.sh` + `ask-codex.sh` round-tripping.

## Handling Codex's `NEED RESEARCH` block

If Codex's output ends with:
```
## NEED RESEARCH
- <question 1>
- <question 2>
```

Do this:
1. For each question, run `ask-gemini.sh "<question>"` — capture each answer.
2. Concatenate the answers into a temp file (e.g., `.dev-trio/log/${AGENT_TEAM:-default}/research-<ts>.md`).
3. Re-invoke Codex with the research:
   ```bash
   ask-codex.sh --with-research .dev-trio/log/${AGENT_TEAM:-default}/research-<ts>.md "<original focus>"
   ```
4. Use Codex's final review to decide next steps. Surface blockers/major findings to the user before continuing.

## Reporting back to the user

- After research: summarize Gemini's key points in 2–4 lines, cite the log file.
- After review: give the user Codex's verdict (`SHIP` / `NEEDS-FIX` / `DISCUSS`) + blockers/major findings inline. Don't dump the full Codex output unless asked — link the log.
- Logs live in `.dev-trio/log/` (gitignored).

## Team isolation (per-window log namespace)

Multiple team windows can run side-by-side without crossing streams. Each wrapper invocation writes into `.dev-trio/log/<TEAM>/...`, where `<TEAM>` is resolved in this priority:

1. `$AGENT_TEAM` env var (highest — for one-off overrides)
2. tmux window option `@team-name` (set by `/dev-trio:bootstrap` / `team-layout.sh`)
3. tmux session name (default for raw tmux sessions)
4. `default` (when not running inside tmux)

Files inside `.dev-trio/log/<TEAM>/`:
- `gemini-<TS>.log`, `codex-<TS>.log` — per-run output
- `latest-gemini.log`, `latest-codex.log` — symlinks to most recent run (used by the dashboard)

Override log root with `DEV_TRIO_LOG_DIR=/abs/path`.

To set or change a window's team manually:
```bash
tmux set-option -w '@team-name' 'my-team'
tmux rename-window 'my-team'      # cosmetic, but keeps things consistent
```

Then restart that window's dashboards (Ctrl-C then re-run `dashboard.sh gemini|codex`) to pick up the new team.

## Spawning the team layout

Three ways to set up the 3-pane layout (Claude main + Gemini/Codex dashboards):

**(1) Slash command** (inside Claude Code, already running in tmux):
```
/dev-trio:bootstrap
```

**(2) Standalone — new tmux session** (from shell):
```bash
team-layout.sh                # creates session "dev-trio", attaches
team-layout.sh -n myteam      # custom session/team name
team-layout.sh --here         # split current tmux window in place
team-layout.sh --no-attach    # create session detached
```

The left pane is left as an idle shell — run `claude` (or whatever) yourself.

**(3) tmux keybinding — `prefix + R` inside any window**

See `tmux/keybinding.conf.example` in the plugin install dir for the snippet to add to `~/.tmux.conf`.

## Monitoring (live dashboard in side panes)

Two side panes run a flicker-free dashboard showing **distilled key points only** — the full raw output stays in this Claude (PM) pane and on disk. Each side pane shows:

- **Gemini**: query, status, *answer lead* (first paragraph), sources cited count
- **Codex**: focus, status, **verdict box** (color-coded), findings counts, **Blocker/Major text** (when present)

```bash
dashboard.sh gemini   # in one side pane
dashboard.sh codex    # in another side pane
```

Color legend (codex verdict):
- 🟢 **SHIP** — green bar
- 🔴 **NEEDS-FIX** — red bar
- 🟡 **DISCUSS** — yellow bar

**Controls** (inside dashboard pane):
- `l` — open the full log in `less` (`q` to return)
- `space` — pause auto-refresh (so you can use `Ctrl-b [` to scroll), space again to resume
- `q` — quit
- `Ctrl-C` — also quits

The wrappers append `=== END (rc=N) ===` to each log when the run finishes; that's how the dashboard distinguishes ⏳ running... from ✓ done / ✗ failed. Rendering only happens when content actually changes (cksum-based skip), and uses cursor-home + per-line erase instead of a full screen clear, so there's no visible flicker.

**Raw fallback** (when the dashboard misbehaves or you want unfiltered output):
```bash
tail -F .dev-trio/log/${AGENT_TEAM:-default}/latest-gemini.log
tail -F .dev-trio/log/${AGENT_TEAM:-default}/latest-codex.log
```

The wrapper scripts print both the dashboard command and the raw `tail -F` hint to stderr when they start.

## Don't

- Don't call Gemini or Codex from inside a subagent (`Agent` tool) — keep orchestration in the main session so the user can see the routing.
- Don't run Gemini/Codex in the background unless the user asks; the latency is part of the deliberation budget.
- Don't act on Codex `NEEDS-FIX` findings without showing the user first — they decide whether to address each one.
- Don't paste secrets/credentials into prompts. Both CLIs send to external providers.

## Security model (accepted tradeoffs)

The wrappers use **two layers** of injection defense:
1. **Role-prompt level** — each role file has a `Trust boundary` section telling the agent to ignore directives inside `<user_question>` / `<review_target>` / `<research_context>` tags.
2. **Literal-string level** — the wrapper scripts strip the matching closing tag from untrusted input before embedding.

We **deliberately did not** add JSON/base64 encoding of payloads (which Codex flagged as the "proper" fix). This is a local dev tool, not a production surface receiving adversarial input. The most realistic attack vector is **Gemini's research output flowing into Codex**; if the threat model changes (e.g., Gemini starts pulling untrusted external content as context), upgrade to encoded payloads. Until then, the two layers above are sufficient.
