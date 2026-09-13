# dev-trio

Supports **Claude Code or Codex as PM**, using the same CLI adapters and run artifacts.

The original Claude host orchestrates a 3-vendor dev team: Claude (PM/Coder) + Antigravity (Researcher) + Codex (Reviewer). Live 3-pane tmux view; ad-hoc research and review skills; opt-in PM orchestration policy that installs into your workspace's `CLAUDE.md`.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | PM / Coder | Claude Code (this session) |
| Top-right | Researcher dashboard | tails `agy` output |
| Bottom-right | Reviewer dashboard | tails `codex` output |

## Codex PM

Codex acts as PM/coder, Antigravity researches, and Claude Code reviews by
default. Existing `DEV_TRIO_*_MODEL` overrides and shared `models.json` role
bindings take precedence. Claude must be installed and authenticated;
subscription, API, and provider selection remain under Claude Code's own
configuration. There is no subscription-only or API-key restriction.

Install from a local checkout containing this support:

```bash
codex plugin marketplace add /absolute/path/to/agent-team-plugins
codex plugin add dev-trio@pandas-studio
```

Start a new Codex session and invoke `$dev-trio:research`, `$dev-trio:review`,
`$dev-trio:bootstrap`, or `$dev-trio:install-pm`. The last skill optionally
installs persistent PM instructions into the current workspace's `AGENTS.md`;
it does not change `CLAUDE.md`. Installation of the plugin alone writes neither
project policy file. Both hosts keep the `dev-trio` namespace.

The scripts can also be called directly **from the workspace being reviewed**:

```bash
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/dev-trio-doctor.sh
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/ask-agy.sh "research question" </dev/null
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/ask-codex.sh "review focus" </dev/null
python3 /absolute/path/to/dev-trio/bin/install-pm.py --host codex
```

`DEV_TRIO_PM_HOST` accepts `claude` (default) or `codex` and applies only to that
invocation; it never rewrites shared role bindings. Codex resolves scripts from
the loaded skill path instead of assuming automatic `bin/` PATH registration.
When piping research context, replace `</dev/null` with that input pipe.

Despite the legacy name, `ask-codex.sh` runs the selected **reviewer**. Existing
`latest-codex.final.md` and RFC 0004 manifests remain compatible with consumers.
The run header and dashboard identify the actual model. `--no-memories` still
requires an explicitly selected Codex reviewer; it is rejected for Claude.

Claude's `auth status --json` must report `loggedIn: true` before a Claude
invocation from the Codex host. In a sandbox that cannot access macOS Keychain,
this check may require the host's normal permission escalation. Failures are
reported before inference; the plugin does not modify credentials or retry
using a different provider. Explicit custom CLI adapters retain their own auth
behavior; a Claude adapter should use the `claude` model ID or `claude` binary
name if it needs the built-in login probe.

The four Codex skills preserve the explicit invocation policy. Persistent PM
routing is opt-in through `install-pm`; otherwise use the skills when requested.
Research/review do not require tmux. In the Codex app, bootstrap creates a
detached tmux layout outside tmux and prints an attach command for a terminal.

## Prerequisites

- `tmux` for optional dashboards (research/review work without it)
- `claude` (Claude Code)
- `agy` (Antigravity CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated
- Python 3.9+ for the policy installer and development tests
- `jq` (1.6+) — required for the model registry and RFC 0004 run manifests

Models and CLI binaries are configurable — see [Model configuration](#model-configuration). Quick binary overrides still work: `AGY_CLI` / `RESEARCHER_CLI` (researcher), `CODEX_CLI` / `REVIEWER_CLI` (reviewer).

## Model configuration

The Researcher and Reviewer roles resolve through the shared model registry (the [marketplace README](../README.md#shared-model-configuration) covers it in full). Defaults are `agy` (researcher) and `codex` (reviewer) — no setup needed.

| Role | Default | Pick a different model | Override its binary |
| :--- | :--- | :--- | :--- |
| `dev-trio.researcher` | `agy` | `DEV_TRIO_RESEARCHER_MODEL` env, or `agent-team-models set-role dev-trio.researcher <model>` | `RESEARCHER_CLI` (any model) · `AGY_CLI` (the `agy` model) |
| `dev-trio.reviewer` | Claude PM: `codex`; Codex PM: `claude` | `DEV_TRIO_REVIEWER_MODEL` env, or `agent-team-models set-role dev-trio.reviewer <model>` | `REVIEWER_CLI` (any model) · `CODEX_CLI` (the `codex` model) |

```bash
agent-team-models preset add kimi-code
agent-team-models set-role dev-trio.reviewer kimi-code   # reviews now run through Kimi Code
agent-team-models doctor                                  # verify binding + binary
```

The reviewer's final structured review is written to `<TS>.final.md` natively when the model supports it (codex's `--output-last-message`), and otherwise synthesised from the streamed transcript — so `/dev-trio:review` verdict parsing works regardless of which model fills the role.

**Reviewing without Codex memories.** With Codex's memories feature enabled in `~/.codex/config.toml`, `codex exec` adds the memory summary from earlier Codex sessions to the review prompt. Pass `--no-memories` (`ask-codex.sh --no-memories "focus"` or `/dev-trio:review --no-memories ...`) to run the built-in `codex-no-memories` model instead, which adds `-c features.memories=false`. Setting `DEV_TRIO_REVIEWER_MODEL=codex-no-memories` selects the same model without the flag (and without the checks below). With the flag, `ask-codex.sh` exits with rc=2 before starting any CLI when the reviewer role resolves to a model other than `codex` / `codex-no-memories`, or when the models config defines its own `codex-no-memories`.

## Install in Claude Code

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
   ask-agy.sh "What's the recommended way to stream tokens with langchain-anthropic 0.3.x?"
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
| `/dev-trio:bootstrap` | One-time per session: splits the current tmux pane into 3 and starts the agy/codex dashboards. |
| `/dev-trio:research <question>` | One-shot Antigravity lookup. Streaming output lands in the top-right pane; chat-side surfaces the lead + cited URLs. |
| `/dev-trio:review [focus] [--with-research <file>] [--with-spec <file>]` | One-shot Codex review (default = git-uncommitted scope). Chat-side surfaces verdict (`SHIP / NEEDS-FIX / DISCUSS`) + Blocker/Major counts. Handles `## NEED RESEARCH` blocks. |
| `/dev-trio:install-pm` | Writes/upgrades the PM orchestration policy in the workspace's `CLAUDE.md` (idempotent, marker-guarded). |

Claude skills carry `disable-model-invocation: true`; Codex skills use
`policy.allow_implicit_invocation: false` in `agents/openai.yaml`. Invoke the
host-specific skills explicitly. Custom manifest paths avoid loading both
variants through the default `skills/` discovery path.

## Logs

Per-team log namespace. Each invocation writes to:

```
$PWD/.dev-trio/log/<team>/
├── agy-<TS>.log            # raw Antigravity output + framing
├── codex-<TS>.log          # raw Codex output + framing
├── latest-agy.log          # symlink to most recent agy run
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

- **Antigravity**: query, status, *answer lead* (first paragraph), sources cited count
- **Codex**: focus, status, **verdict box** (color-coded), findings counts, **Blocker/Major text** (when present)

```bash
dashboard.sh agy      # in one side pane
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
tail -F .dev-trio/log/${AGENT_TEAM:-default}/latest-agy.log
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
├── .claude-plugin/plugin.json  # skills: ./claude-skills/
├── .codex-plugin/plugin.json   # skills: ./codex-skills/
├── codex-skills/              # bootstrap/research/review/install-pm
├── claude-skills/
│   ├── bootstrap/SKILL.md
│   ├── research/SKILL.md
│   ├── review/SKILL.md
│   └── install-pm/SKILL.md
├── bin/                       # on plugin PATH while active
│   ├── ask-agy.sh             # Researcher wrapper
│   ├── ask-codex.sh           # Reviewer wrapper
│   ├── agent-team-models.sh   # shared model-registry CLI (vendored)
│   ├── dashboard.sh           # live dashboard (agy|codex)
│   ├── team-layout.sh         # tmux 3-pane splitter
│   └── dev-trio-doctor.sh     # env probe + stub-CLI smoke
├── lib/                       # internal
│   ├── manifest.sh            # RFC 0004 run-manifest helper (vendored)
│   ├── registry.sh            # shared model registry + runner (vendored)
│   ├── host.sh                # host defaults and CLI/login checks
│   ├── pm.md                  # Claude PM policy
│   ├── pm-codex.md            # Codex PM policy
│   └── roles/
│       ├── researcher.md      # Antigravity role prompt
│       └── reviewer.md        # Codex role prompt
└── tmux/keybinding.conf.example
```

## Doctor

A one-shot env probe + stub-CLI smoke is bundled:

```bash
dev-trio-doctor.sh
```

Checks required helpers and resolved role binaries, probes Claude login for the Codex host, treats tmux as optional, verifies that `ask-agy.sh` produces a well-formed RFC 0004 manifest under stub CLIs, and exercises the `agent-team-models` registry CLI (list / preset / set-role / doctor / remove against an isolated config). **Stub smokes are necessary but not sufficient** — verdict / dashboard / parse-affecting changes need a real-CLI dry-run on top.

## Development checks

```bash
bash scripts/check.sh
python3 tests/check_dev_trio_loaders.py   # requires local claude + codex, no inference
```

Run these from the repository root. The native discovery test copies the plugin
into a temporary path containing spaces, installs it in a disposable
`CODEX_HOME`, and checks both hosts expose exactly their own four skills. It
leaves user plugin installations unchanged. CI uses recording CLI stubs for
role precedence, authentication, argv/context handoff, failures, and policy
updates. Live model calls are a separate acceptance check.

Both manifests explicitly select their host skill directory; there is no root
`skills/` directory. The Codex scaffold validator assumes that fixed directory,
so it rejects the custom `skills` path even though the native loader supports
it. Validate Codex skill metadata separately and use the native discovery test
for the actual package paths. A temporary view normalized to `skills/` can also
be used with the scaffold validator for its remaining metadata checks.

## Security model

The wrappers use **two layers** of injection defense:

1. **Role-prompt level** — each role file has a `Trust boundary` section telling the agent to ignore directives inside `<user_question>` / `<review_target>` / `<research_context>` tags.
2. **Literal-string level** — the wrapper scripts strip the matching closing tag from untrusted input before embedding.

We **deliberately did not** add JSON/base64 encoding of payloads (which Codex flagged as the "proper" fix). This is a local dev tool, not a production surface receiving adversarial input. The most realistic attack vector is **Antigravity's research output flowing into Codex**; if the threat model changes (e.g., Antigravity starts pulling untrusted external content as context), upgrade to encoded payloads. Until then, the two layers above are sufficient.

## License

[MIT](../LICENSE).
