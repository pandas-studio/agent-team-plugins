# debate-conductor

Claude conducts a Generator vs Critic adversarial debate over N rounds. Three-pane tmux layout: left = Claude (PM), middle = Generator transcript live tail, right = Critic transcript live tail.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | Conductor / PM | Claude Code (this session) |
| Middle | Generator | `gemini` |
| Right | Critic | `codex` |

## Prerequisites

- `tmux`
- `claude` (Claude Code)
- `gemini` (Gemini CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated

The wrappers respect overrides via `GEMINI_CLI`, `CODEX_CLI`, `CLAUDE_CLI` env vars if your binaries are at non-standard paths.

## Install

Via the marketplace:

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install debate-conductor@pandas-studio
```

For local development on this plugin:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git
claude --plugin-dir ./agent-team-plugins/debate-conductor
```

## Use

1. From a workspace dir (any project with — or without — a custom `topics/` folder):
   ```bash
   tmux new-session -s debate
   # inside tmux:
   claude
   ```

2. In the Claude session:
   ```
   /debate-conductor:bootstrap
   ```
   This splits the current pane into 3 columns and starts the role-tail viewers.

3. (Recommended on first install) Install the PM orchestration policy into the workspace's `CLAUDE.md`:
   ```
   /debate-conductor:install-pm
   ```
   This appends a marked block to `$PWD/CLAUDE.md` between `<!-- BEGIN debate-conductor PM policy -->` / `<!-- END debate-conductor PM policy -->`. Re-running upgrades in place; safe to run again after plugin updates. The policy is intentionally tight (~20 lines) and only carries the per-turn routing rules: when to dispatch a debate vs answer directly, how to frame the stance, how to report the verdict back.

4. Run a debate:
   ```
   /debate-conductor:run 1
   ```
   Resolves topic 1 from `topics/`, runs the default 3-round debate (Gemini gen → Codex crit → Gemini gen), and afterwards Claude reads the round files and surfaces verdict + move-by-move.

5. Follow up in natural language: "round 3 결정타?", "5라운드로 다시 돌려줘", "rotate ON으로 토픽 2", etc.

## Workspace topics

Place topic files at `<workspace>/topics/0N-*.txt`. Each file is a stance-driven prompt the Generator receives. The plugin ships three default examples in its own `topics/` — you can copy them into your workspace as a starting point. The skill checks workspace `topics/` first, falls back to the plugin's bundled examples if absent.

## Logs

Round transcripts and per-round model logs land in:

```
$PWD/.debate-conductor/log/<team>/
├── latest-debate -> debate-<TS>
├── debate-<TS>/
│   ├── topic.txt              # original topic — read by /continue
│   ├── round-1-gen.md
│   ├── round-2-crit.md
│   └── round-3-gen.md
├── gen-<TS>.log
└── crit-<TS>.log
```

`<team>` is the tmux window's `@team-name` option (default: `debate-conductor`), so multiple windows in the same workspace produce isolated log streams.

Override the log location with `DEBATE_LOG_DIR=/path/to/logs`.

## Skills

| Skill | What it does |
| :--- | :--- |
| `/debate-conductor:bootstrap` | One-time per session: splits the current tmux pane into 3 and starts role tails. |
| `/debate-conductor:run [N] [rounds]` | Resolves topic N, runs `debate.sh`, summarises verdict + moves. |
| `/debate-conductor:continue [extra-rounds]` | Append N more rounds (default 2) to the most recent debate in the same `debate-<TS>/`. Round numbering continues; tail panes pick up new rounds without retarget. |
| `/debate-conductor:install-pm` | Writes/upgrades the PM orchestration policy in the workspace's `CLAUDE.md` (idempotent, marker-guarded). Tells Claude when to dispatch a debate vs answer directly. |

All skills have `disable-model-invocation: true` — Claude won't trigger them implicitly. You always invoke explicitly via `/`.

Example:

```
/debate-conductor:run "여름 vs 겨울" 3   # rounds 1·2·3
/debate-conductor:continue 2             # rounds 4·5 appended to same dir
```

## Architecture

```
debate-conductor/
├── .claude-plugin/plugin.json
├── skills/
│   ├── bootstrap/SKILL.md
│   ├── run/SKILL.md
│   ├── continue/SKILL.md
│   └── install-pm/SKILL.md
├── bin/                       # on PATH while plugin is active
│   ├── debate.sh              # round orchestrator (skill calls this)
│   ├── team-3pane.sh          # tmux 3-pane splitter (--here mode)
│   └── tail-role.sh           # live-tail one role's round files
├── lib/                       # internal — invoked by debate.sh / install-pm
│   ├── ask-generator.sh       # Generator wrapper (gemini|codex|claude)
│   ├── ask-critic.sh          # Critic wrapper (codex|gemini|claude)
│   ├── pm.md                  # PM orchestration policy (source of truth)
│   └── roles/
│       ├── generator.md       # Generator role prompt
│       └── critic.md          # Critic role prompt
└── topics/                    # default topic examples
```

## Design notes

**Context scope per round.** Each round prompt only includes the *immediately preceding* generator+critic pair — not the full transcript. So round 5 sees round 3 (your last draft) and round 4 (critic feedback), but not rounds 1–2. This keeps prompts bounded as round count grows; the trade-off is that early-round consensus or discoveries fade out unless re-stated. `/continue` follows the same rule.

**Live streaming quality depends on the model CLI.** The pipeline (`stdbuf -oL` on `sed`/`tee`) forces line-buffered stdio so cleaned output flows line-by-line through the viewers. But if the model CLI itself batches its stdout in user-space (some `codex` builds do this), a round may still appear in one chunk rather than streaming. That's outside this plugin's reach.

## License

[MIT](../LICENSE).
