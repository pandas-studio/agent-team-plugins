# dev-trio

Claude Code orchestrates a 3-vendor dev team: Claude (PM/Coder) + Gemini (Researcher) + Codex (Reviewer). Live 3-pane tmux view; ad-hoc research and review skills; opt-in PM orchestration policy that installs into your workspace's `CLAUDE.md`.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | PM / Coder | Claude Code (this session) |
| Top-right | Researcher dashboard | tails `gemini` output |
| Bottom-right | Reviewer dashboard | tails `codex` output |

## Prerequisites

- `tmux`
- `claude` (Claude Code)
- `gemini` (Gemini CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated
- `jq` (1.6+) — required for RFC 0004 run manifests

Override CLI binaries via `GEMINI_CLI` / `RESEARCHER_CLI` and `CODEX_CLI` / `REVIEWER_CLI` env vars.

## Install

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install dev-trio@pandas-studio
```

Local development:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git
claude --plugin-dir ./agent-team-plugins/dev-trio
```

## Use

1. From your workspace, inside tmux:
   ```bash
   tmux new-session -s mywork
   claude
   ```

2. In the Claude session, set up the 3-pane layout once:
   ```
   /dev-trio:bootstrap
   ```

3. (Recommended on first install) Install the PM orchestration policy into the workspace's `CLAUDE.md`:
   ```
   /dev-trio:install-pm
   ```
   This appends a marked block to `$PWD/CLAUDE.md` between `<!-- BEGIN dev-trio PM policy -->` / `<!-- END dev-trio PM policy -->`. Re-running upgrades in place; safe to run again after plugin updates.

4. Drive normally. The PM policy tells Claude when to dispatch:
   ```
   ask-gemini.sh "What's the recommended way to stream tokens with langchain-anthropic 0.3.x?"
   ask-codex.sh "review the new retry logic in src/agent.py — concurrency safety"
   ```
   Or use the wrapping skills:
   ```
   /dev-trio:research <question>
   /dev-trio:review  [focus] [--with-research <file>] [--with-spec <file>]
   ```

## Skills

| Skill | What it does |
| :--- | :--- |
| `/dev-trio:bootstrap` | One-time per session: splits the current tmux pane into 3 and starts the gemini/codex dashboards. |
| `/dev-trio:research <question>` | One-shot Gemini lookup. Streaming output lands in the top-right pane; chat-side surfaces the lead + cited URLs. |
| `/dev-trio:review [focus] [--with-research <file>] [--with-spec <file>]` | One-shot Codex review (default = git-uncommitted scope). Chat-side surfaces verdict (`SHIP / NEEDS-FIX / DISCUSS`) + Blocker/Major counts. Handles `## NEED RESEARCH` blocks. |
| `/dev-trio:install-pm` | Writes/upgrades the PM orchestration policy in the workspace's `CLAUDE.md` (idempotent, marker-guarded). |

All skills carry `disable-model-invocation: true` — Claude won't trigger them implicitly. You always invoke explicitly via `/`.

## Logs

Per-team log namespace. Each invocation writes to:

```
$PWD/.dev-trio/log/<team>/
├── gemini-<TS>.log         # raw Gemini output + framing
├── codex-<TS>.log          # raw Codex output + framing
├── latest-gemini.log       # symlink to most recent gemini run
├── latest-codex.log        # symlink to most recent codex run
└── <name>-<TS>.manifest.json   # RFC 0004 typed run manifest
```

`<team>` resolution (priority order):

1. `$AGENT_TEAM` env var
2. tmux window option `@team-name` (set by `bootstrap`)
3. tmux session name
4. `default`

Override the log root with `DEV_TRIO_LOG_DIR=/path/to/logs`.

## Live dashboard

Two side panes run a flicker-free dashboard showing **distilled key points only** — the full raw output stays in the Claude (PM) pane and on disk. Each side pane shows:

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

## Layout commands

`/dev-trio:bootstrap` already wires the layout from inside Claude Code. For other entry points, the underlying `team-layout.sh` is on the plugin PATH:

```bash
team-layout.sh                # creates session "dev-trio", attaches
team-layout.sh -n myteam      # custom session/team name
team-layout.sh --here         # split current tmux window in place
team-layout.sh --no-attach    # create session detached
```

The left pane is left as an idle shell — run `claude` (or whatever) yourself.

For users who skip Claude Code and want to spawn the layout from a raw shell via `prefix + R`, add this to `~/.tmux.conf`:

```tmux
# Adjust the path to your dev-trio install dir.
# Local-marketplace install lands under ~/.claude/plugins/dev-trio/ by default,
# but the exact path depends on how you added the marketplace.
bind-key R run-shell "~/.claude/plugins/dev-trio/bin/team-layout.sh --here"
```

Reload tmux: `tmux source-file ~/.tmux.conf`. See `tmux/keybinding.conf.example`.

## Architecture

```
dev-trio/
├── .claude-plugin/plugin.json
├── skills/
│   ├── bootstrap/SKILL.md
│   ├── research/SKILL.md
│   ├── review/SKILL.md
│   └── install-pm/SKILL.md
├── bin/                       # on plugin PATH while active
│   ├── ask-gemini.sh          # Researcher wrapper
│   ├── ask-codex.sh           # Reviewer wrapper
│   ├── dashboard.sh           # live dashboard (gemini|codex)
│   ├── team-layout.sh         # tmux 3-pane splitter
│   └── dev-trio-doctor.sh     # env probe + stub-CLI smoke
├── lib/                       # internal
│   ├── manifest.sh            # RFC 0004 run-manifest helper (vendored)
│   ├── pm.md                  # PM orchestration policy (source of truth)
│   └── roles/
│       ├── researcher.md      # Gemini role prompt
│       └── reviewer.md        # Codex role prompt
└── tmux/keybinding.conf.example
```

## Doctor

A one-shot env probe + stub-CLI smoke is bundled:

```bash
dev-trio-doctor.sh
```

Checks `tmux` / `gemini` / `codex` / `jq` presence and verifies that `ask-gemini.sh` produces a well-formed RFC 0004 manifest under stub CLIs. **Stub smokes are necessary but not sufficient** — verdict / dashboard / parse-affecting changes need a real-CLI dry-run on top.

## Security model

The wrappers use **two layers** of injection defense:

1. **Role-prompt level** — each role file has a `Trust boundary` section telling the agent to ignore directives inside `<user_question>` / `<review_target>` / `<research_context>` tags.
2. **Literal-string level** — the wrapper scripts strip the matching closing tag from untrusted input before embedding.

We **deliberately did not** add JSON/base64 encoding of payloads (which Codex flagged as the "proper" fix). This is a local dev tool, not a production surface receiving adversarial input. The most realistic attack vector is **Gemini's research output flowing into Codex**; if the threat model changes (e.g., Gemini starts pulling untrusted external content as context), upgrade to encoded payloads. Until then, the two layers above are sufficient.

## License

[MIT](../LICENSE).
