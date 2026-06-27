# pandas-studio agent-team-plugins

Claude Code plugin marketplace from pandas-studio's YouTube series on multi-CLI agent teams. Each plugin packages a *Claude-as-conductor* pattern: Claude orchestrates one or more companion CLIs (Antigravity, Codex) playing specialised roles, with a tmux multi-pane live view.

## Install the marketplace

```bash
# Inside any Claude Code session
/plugin marketplace add pandas-studio/agent-team-plugins
```

Then install the plugins you want:

```bash
/plugin install dev-trio@pandas-studio
/plugin install debate-conductor@pandas-studio
```

## Plugins

| Name | Roles | Episode | Status |
| :--- | :--- | :--- | :--- |
| [dev-trio](./dev-trio) | Claude=PM/Coder · Antigravity=Researcher · Codex=Reviewer | EP A | shipped |
| [debate-conductor](./debate-conductor) | Claude=PM · Antigravity=Generator · Codex=Critic | EP B | shipped |

More plugins (watch-pair, spec-trio, bisect-bot, ralph-trio) follow the same shape and will land here as their EPs publish.

## Shared model configuration

Both plugins resolve their companion-CLI roles through a **shared model registry**. A *model* is a named CLI adapter (how to spawn a CLI and feed it a prompt); a *role* (e.g. `dev-trio.researcher`) is bound to a model. Three models ship built-in — `agy`, `codex`, `claude` — and the default bindings match the role tables in each plugin, so **zero configuration is required**.

To customise, use the `agent-team-models` CLI. It is on PATH whenever either plugin is active; both plugins ship an identical copy and operate on the **same** config file:

```bash
agent-team-models list                                # models + current role bindings
agent-team-models doctor                              # validate config, check binaries on PATH
agent-team-models preset add kimi-code                # install the Kimi Code preset
agent-team-models set-role dev-trio.reviewer kimi-code
agent-team-models add my-llm --command my-cli --arg -p --arg '{prompt}'
agent-team-models remove kimi-code --force --fallback codex
```

Config lives at `$AGENT_TEAM_MODELS_CONFIG`, else `${XDG_CONFIG_HOME:-~/.config}/agent-team-plugins/models.json`.

**Roles and their defaults:**

| Role | Default model | Per-role model env override |
| :--- | :--- | :--- |
| `dev-trio.researcher` | `agy` | `DEV_TRIO_RESEARCHER_MODEL` |
| `dev-trio.reviewer` | `codex` | `DEV_TRIO_REVIEWER_MODEL` |
| `debate-conductor.generator` | `agy` | `DEBATE_GENERATOR_MODEL` |
| `debate-conductor.critic` | `codex` | `DEBATE_CRITIC_MODEL` |

**Resolution precedence.** Which *model* runs a role: CLI flag (`--model`, `--primary-gen`/`--primary-crit`) → per-role env var → config binding → built-in default. Which *binary* runs a model: legacy per-role `*_CLI` (`RESEARCHER_CLI`, `REVIEWER_CLI`, `GENERATOR_CLI`, `CRITIC_CLI`) → the model's own env override (`AGY_CLI`, `CODEX_CLI`, `CLAUDE_CLI`, `KIMI_CLI`) → its built-in command. All existing env overrides keep working unchanged.

A model definition is a CLI adapter: a `command`, an optional `env_command` (env var that overrides the binary), an `args` argv template containing `{prompt}`, and an optional `final_args` template (with `{prompt}` and `{final}`) for CLIs that can write their last message to a file. Models without `final_args` still produce a compatible `*.final.md` — it is synthesised from the streamed transcript.

### Example: route reviews through Kimi Code

```bash
agent-team-models preset add kimi-code         # model kimi-code: command=kimi, env_command=KIMI_CLI
export KIMI_CLI=/path/to/kimi                   # only if kimi isn't already on PATH as `kimi`
agent-team-models set-role dev-trio.reviewer kimi-code
agent-team-models doctor                        # confirm: reviewer -> kimi-code, binary resolves
```

`jq` (1.6+) is required for the registry.

## Pattern

Every plugin in this marketplace follows broadly the same layout. Skill set varies per pattern (`dev-trio` ships `bootstrap`/`research`/`review`/`install-pm`; `debate-conductor` ships `bootstrap`/`run`/`continue`), but the directory shape is stable:

```
<plugin>/
├── .claude-plugin/plugin.json
├── skills/
│   ├── bootstrap/SKILL.md   # one-time tmux layout setup
│   └── <verb>/SKILL.md      # the orchestration entry points
├── bin/                     # on PATH while plugin is active
│   └── *.sh                 # tmux/bootstrap helpers + user-facing wrappers
├── lib/                     # internal — invoked by the bin/ scripts
│   ├── *.sh                 # engine (or shared helpers like manifest.sh)
│   └── roles/*.md           # role prompts for companion CLIs
└── <topics/|tmux/|...>      # plugin-specific assets (canned topics, keybindings)
```

`bin/` and `lib/` are bash. Roles are markdown. Skills are markdown with YAML frontmatter. No language runtime beyond bash + the third-party CLIs (`claude`, `agy`, `codex`), plus `jq` for the [shared model registry](#shared-model-configuration) and RFC 0004 run manifests.

## Develop locally

```bash
git clone git@github.com:pandas-studio/agent-team-plugins.git
cd agent-team-plugins
claude --plugin-dir ./dev-trio           # load one plugin
claude --plugin-dir ./debate-conductor
```

`/reload-plugins` picks up edits without restarting Claude Code.

## License

[MIT](./LICENSE).
