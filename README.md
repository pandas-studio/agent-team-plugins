# pandas-studio agent-team-plugins

Claude Code plugin marketplace from pandas-studio's YouTube series on multi-CLI agent teams. Each plugin packages a *Claude-as-conductor* pattern: Claude orchestrates one or more companion CLIs (Antigravity, Codex) playing specialised roles, with a tmux multi-pane live view.

`dev-trio` and `debate-conductor` also support **Codex as PM**. The CLI engine
is shared; each host loads its own skills and PM policy. See
[dev-trio Codex usage](./dev-trio/README.md#codex-pm) and
[debate-conductor Codex usage](./debate-conductor/README.md#codex-pm).

## Install the marketplace in Claude Code

```bash
# Inside any Claude Code session
/plugin marketplace add pandas-studio/agent-team-plugins
```

Then install the plugins you want:

```bash
/plugin install dev-trio@pandas-studio
/plugin install debate-conductor@pandas-studio
/plugin install ralph-trio@pandas-studio
/plugin install spec-trio@pandas-studio
/plugin install langgraph-conductor@pandas-studio
```

## Install the marketplace in Codex

```bash
codex plugin marketplace add /absolute/path/to/agent-team-plugins
codex plugin add dev-trio@pandas-studio
codex plugin add debate-conductor@pandas-studio
```

## Plugins

| Name | Roles | Episode | Status |
| :--- | :--- | :--- | :--- |
| [dev-trio](./dev-trio) | Claude or Codex=PM/Coder · configurable research/review CLIs | EP A | shipped |
| [debate-conductor](./debate-conductor) | Claude or Codex=PM · configurable generator/critic CLIs | EP B | shipped |
| [ralph-trio](./ralph-trio) | Claude=Planner/Coder · Antigravity=Researcher · Codex=Reviewer | EP C | shipped |
| [spec-trio](./spec-trio) | Spec-gated planner/coder/reviewer loop | EP D | shipped |
| [langgraph-conductor](./runtime) | Durable planner/researcher/coder/reviewer graph | Guide v1 | preview |

## Shared model configuration

The role-based plugins resolve their companion CLIs through a **shared model registry**. A *model* is a named CLI adapter (how to spawn a CLI and feed it a prompt); a *role* (e.g. `dev-trio.researcher`) is bound to a model. Five models ship built-in — `agy`, `codex`, `codex-no-memories`, `claude`, `claude-write` — and the default bindings match the role tables, so **zero configuration is required**. `claude-write` is `claude` plus `--permission-mode acceptEdits`: headless `claude -p` cannot edit files without it, so only roles meant to write are bound to it. `codex-no-memories` is `codex` plus `-c features.memories=false`, for reviews that should not receive the memory summary from earlier Codex sessions.

To customise, use the `agent-team-models` CLI. It is on PATH whenever either plugin is active; both plugins ship an identical copy and operate on the **same** config file:

```bash
agent-team-models list                                # models + current role bindings
agent-team-models doctor                              # validate config, check binaries on PATH
agent-team-models preset add kimi-code                # install the Kimi Code preset
agent-team-models set-role dev-trio.reviewer kimi-code
agent-team-models add my-llm --command my-cli --arg -p --arg '{prompt}'
agent-team-models remove kimi-code --force --fallback codex
```

Config lives at `$AGENT_TEAM_MODELS_CONFIG`, else `${XDG_CONFIG_HOME:-~/.config}/agent-team-plugins/models.json`. If the file is not valid JSON, the plugins ignore it with a warning (built-in defaults apply) and every command that would change it (`preset add`, `add`, `edit`, `remove`, `set-role`) exits 2 without writing — fix or move the file first; `agent-team-models doctor` shows the problem.

**Roles and their defaults:**

| Role | Default model | Per-role model env override |
| :--- | :--- | :--- |
| `dev-trio.researcher` | `agy` | `DEV_TRIO_RESEARCHER_MODEL` |
| `dev-trio.reviewer` | `codex` | `DEV_TRIO_REVIEWER_MODEL` |
| `debate-conductor.generator` | `agy` | `DEBATE_GENERATOR_MODEL` |
| `debate-conductor.critic` | `codex` from Claude, `claude` from Codex | `DEBATE_CRITIC_MODEL` |
| `langgraph-conductor.planner` | `claude` | `LANGGRAPH_CONDUCTOR_PLANNER_MODEL` |
| `langgraph-conductor.coder` | `claude-write` | `LANGGRAPH_CONDUCTOR_CODER_MODEL` |
| `langgraph-conductor.researcher` | `agy` | `LANGGRAPH_CONDUCTOR_RESEARCHER_MODEL` |
| `langgraph-conductor.reviewer` | `codex` | `LANGGRAPH_CONDUCTOR_REVIEWER_MODEL` |

## Team namespaces

Every plugin scopes its logs and state under a **team name** so parallel tmux
windows don't collide. It resolves as `$AGENT_TEAM` → tmux `@team-name` window
option → tmux session name → `default`, and must match
`[A-Za-z0-9][A-Za-z0-9._-]*` (max 48 chars) because it becomes a path component.

The two sources are treated differently on purpose:

- **`$AGENT_TEAM`** is an identifier you chose deliberately. An unusable value is
  a hard error (exit 2) rather than something silently rewritten under you.
- **tmux window / session names** are *derived* — you never picked them as a path
  component, and names like `my project` or `feat/x` are ordinary. These are
  sanitized to the allowed character set with a warning on stderr.

**Resolution precedence.** Which *model* runs a role: CLI flag (`--model`, `--primary-gen`/`--primary-crit`) → per-role env var → continued debate metadata where applicable → config binding → built-in default. Which *binary* runs a model: legacy per-role `*_CLI` (`RESEARCHER_CLI`, `REVIEWER_CLI`, `GENERATOR_CLI`, `CRITIC_CLI`) → the model's own env override (`AGY_CLI`, `CODEX_CLI`, `CLAUDE_CLI`, `KIMI_CLI`) → its built-in command. Existing env overrides retain this precedence. Debate wrappers for models with `final_args` must forward all arguments, including native final-capture options; see the [debate wrapper contract](debate-conductor/README.md#model-configuration).

A model definition is a CLI adapter: a `command`, an optional `env_command` (env var that overrides the binary), an `args` argv template in which `{prompt}` marks the argument that carries the prompt (a stdin model leaves it out, see below; for any other model the template that runs must have it, or the CLI would run without the prompt, so the registry refuses it, rc 3. The wrappers pass a final file, so a non-empty `final_args` is the template that runs; a direct `registry_run` without a final file runs `args` and is refused there if `args` lacks `{prompt}`), and an optional `final_args` template (with `{final}`, and `{prompt}` on the same terms) for CLIs that can write their last message to a file. Models without `final_args` still produce a compatible `*.final.md` — it is synthesised from the streamed transcript.

`args` is required; it may be `[]` for a stdin CLI that takes no arguments. Each template element reaches the CLI exactly as written, newlines included, so an element holding a NUL byte is refused; `workspace_args` and `log_args`, when present, are checked the same way. `{final}` belongs in `final_args` only, and `{cwd}` / `{cli_log}` in `workspace_args` / `log_args` only, because the bash library and the Python runtime would expand them differently anywhere else. The bash library (`lib/registry.sh`) and the runtime (`registry.py`) apply one rule, and `runtime/tests/test_registry_differential.py` checks that they agree. **Upgrading:** a custom model that has no `args`, or has one of those placeholders in the wrong template, now fails with rc 3 instead of running; `agent-team-models doctor` names it.

**Where the prompt goes.** By default `{prompt}` is one argument. Linux refuses a single argument of 128 KiB or more before the CLI even starts (macOS only caps the total), so the registry refuses such a prompt itself, on every platform, with rc 3 and the byte count; `REGISTRY_ARGV_MAX_BYTES` moves the 131072-byte limit. A model with `"prompt_via": "stdin"` takes the prompt on stdin instead, and its templates hold no `{prompt}`; the built-in `claude`, `claude-write`, `codex` and `codex-no-memories` models work this way (`claude -p`, `codex exec … -`). Add one with `agent-team-models add my-llm --command my-cli --stdin` (args default to `-p`), or switch an existing one with `edit my-llm --stdin --arg …`. `agent-team-models doctor` flags a stdin model that still has `{prompt}` in a template, and an argv model whose running template — `final_args` when non-empty, otherwise `args` — has none; `add` and `edit` refuse to save either. **Upgrading:** a custom argv model without `{prompt}` used to run without its prompt and report success; it now fails with rc 3 (`RegistryError` in the runtime). Run `agent-team-models doctor` after upgrading, and fix a `[FAIL]` model by adding `{prompt}` to its template (`edit <id> --arg …`) or by moving it to stdin (`edit <id> --stdin --arg …`).

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

`dev-trio` and `debate-conductor` use `claude-skills/` and `codex-skills/`,
selected by each host manifest, plus a small Python policy installer. Other
plugins keep `skills/`.

The four legacy plugins remain Bash-first. `langgraph-conductor` adds an optional Python 3.12 runtime pinned with `uv`; it orchestrates the same CLI adapters and does not call model-provider APIs directly. `jq` is required for the Bash [shared model registry](#shared-model-configuration).

## Develop locally

```bash
git clone git@github.com:pandas-studio/agent-team-plugins.git
cd agent-team-plugins
claude --plugin-dir ./dev-trio           # load one plugin
claude --plugin-dir ./debate-conductor
claude --plugin-dir ./ralph-trio
claude --plugin-dir ./spec-trio

codex plugin marketplace add "$(pwd)"
codex plugin add debate-conductor@pandas-studio

cd runtime
uv sync --frozen --python 3.12 --extra dev
uv run pytest
```

`/reload-plugins` picks up edits without restarting Claude Code.

## License

[MIT](./LICENSE).
