# debate-conductor

Claude conducts a Generator vs Critic adversarial debate over N rounds. Three-pane tmux layout: left = Claude (PM), middle = Generator transcript live tail, right = Critic transcript live tail.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | Conductor / PM | Claude Code (this session) |
| Middle | Generator | `agy` |
| Right | Critic | `codex` |

## Prerequisites

- `tmux`
- `claude` (Claude Code)
- `agy` (Antigravity CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated
- `jq` (1.6+) — required for the model registry

Models and CLI binaries are configurable — see [Model configuration](#model-configuration). Quick binary overrides still work: `AGY_CLI`, `CODEX_CLI`, `CLAUDE_CLI` (per model), `GENERATOR_CLI` / `CRITIC_CLI` (per role).

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
   Resolves topic 1 from `topics/`, runs the default 3-round debate (Antigravity gen → Codex crit → Antigravity gen), and afterwards Claude reads the round files and surfaces verdict + move-by-move.

5. Follow up in natural language: "round 3 결정타?", "5라운드로 다시 돌려줘", "rotate ON으로 토픽 2", etc.

### Run until converged

Instead of a fixed round count, let the debate decide its own length:

```
debate.sh --until-converged "<topic>"          # cap 6 rounds
debate.sh --until-converged -n 8 "<topic>"     # cap 8 rounds
```

The loop stops as soon as a Critic round emits the canonical `Verdict: STRENGTHEN` line (position is sound); `-n` is the upper bound, defaulting to an even cap of 6 so a non-converging debate still ends on a Critic verdict. The empty round files past the convergence point are cleaned up. The `/debate-conductor:run` skill passes this flag when you ask to debate "합의/수렴할 때까지" / "until they agree".

## Workspace topics

Place topic files at `<workspace>/topics/0N-*.txt`. Each file is a stance-driven prompt the Generator receives. The plugin ships three default examples in its own `topics/` — you can copy them into your workspace as a starting point. The skill checks workspace `topics/` first, falls back to the plugin's bundled examples if absent.

## Model configuration

Generator and Critic resolve through the shared model registry (the [marketplace README](../README.md#shared-model-configuration) covers it in full). Defaults: `agy` (generator), `codex` (critic).

| Role | Default | Pick a different model | Override its binary |
| :--- | :--- | :--- | :--- |
| `debate-conductor.generator` | `agy` | `--primary-gen=<model>`, `DEBATE_GENERATOR_MODEL` env, or `agent-team-models set-role debate-conductor.generator <model>` | `GENERATOR_CLI` · `AGY_CLI` |
| `debate-conductor.critic` | `codex` | `--primary-crit=<model>`, `DEBATE_CRITIC_MODEL` env, or `agent-team-models set-role debate-conductor.critic <model>` | `CRITIC_CLI` · `CODEX_CLI` |

`--primary-gen` / `--primary-crit` accept any registered model id (run `agent-team-models list`); generator and critic must differ. With no critic specified, it still defaults to "the other one" (codex unless gen=codex, then agy). The legacy `DEBATE_PRIMARY_GEN` env var also keeps working.

```bash
agent-team-models preset add kimi-code
debate.sh --primary-crit=kimi-code "your topic"                # one-off
agent-team-models set-role debate-conductor.critic kimi-code   # persistent
```

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
│   ├── agent-team-models.sh   # shared model-registry CLI (vendored)
│   ├── debate-conductor-doctor.sh  # layout probe + --until-converged stub smoke
│   ├── team-3pane.sh          # tmux 3-pane splitter (--here mode)
│   └── tail-role.sh           # live-tail one role's round files
├── lib/                       # internal — invoked by debate.sh / install-pm
│   ├── ask-generator.sh       # Generator wrapper (any registered model)
│   ├── ask-critic.sh          # Critic wrapper (any registered model)
│   ├── registry.sh            # shared model registry + runner (vendored)
│   ├── pm.md                  # PM orchestration policy (source of truth)
│   └── roles/
│       ├── generator.md       # Generator role prompt
│       └── critic.md          # Critic role prompt
└── topics/                    # default topic examples
```

## Design notes

**Context scope per round.** Each round prompt only includes the *immediately preceding* generator+critic pair — not the full transcript. So round 5 sees round 3 (your last draft) and round 4 (critic feedback), but not rounds 1–2. This keeps prompts bounded as round count grows; the trade-off is that early-round consensus or discoveries fade out unless re-stated. `/continue` follows the same rule.

**Live streaming quality depends on the model CLI.** The pipeline (`stdbuf -oL` on `sed`/`tee`) forces line-buffered stdio so cleaned output flows line-by-line through the viewers. But if the model CLI itself batches its stdout in user-space (some `codex` builds do this), a round may still appear in one chunk rather than streaming. That's outside this plugin's reach.

**Convergence parsing is anchored, not fuzzy.** `--until-converged` only stops on a *standalone canonical* `Verdict: STRENGTHEN` line (the Critic role contract), taking the last such line in the round. A Critic round that errors out and echoes its role prompt contains the placeholders `Verdict: <STRENGTHEN | …>` and `<one of: STRENGTHEN / …>` — neither matches the anchor, so a failed round reads as not-converged and the debate keeps going rather than stopping on garbage. `debate-conductor-doctor.sh` covers all three paths (STRENGTHEN / RECONSIDER / placeholder) with stub CLIs.

## License

[MIT](../LICENSE).
