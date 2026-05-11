# pandas-studio agent-team-plugins

Claude Code plugin marketplace from pandas-studio's YouTube series on multi-CLI agent teams. Each plugin packages a *Claude-as-conductor* pattern: Claude orchestrates one or more companion CLIs (Gemini, Codex) playing specialised roles, with a tmux multi-pane live view.

## Install the marketplace

```bash
# Inside any Claude Code session
/plugin marketplace add pandas-studio/agent-team-plugins
```

Then install the plugins you want:

```bash
/plugin install debate-conductor@pandas-studio
/plugin install dev-trio@pandas-studio
```

## Plugins

| Name | Roles | Episode | Status |
| :--- | :--- | :--- | :--- |
| [debate-conductor](./debate-conductor) | Claude=PM · Gemini=Generator · Codex=Critic | EP B | shipped |
| [dev-trio](./dev-trio) | Claude=PM/Coder · Gemini=Researcher · Codex=Reviewer | EP A | shipped |

More plugins (watch-pair, spec-trio, bisect-bot, ralph-trio) follow the same shape and will land here as their EPs publish.

## Pattern

Every plugin in this marketplace follows broadly the same layout. Skill set varies per pattern (`debate-conductor` ships `bootstrap`/`run`/`continue`; `dev-trio` ships `bootstrap`/`research`/`review`/`install-pm`), but the directory shape is stable:

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

`bin/` and `lib/` are bash. Roles are markdown. Skills are markdown with YAML frontmatter. No language runtime beyond bash + the third-party CLIs (`claude`, `gemini`, `codex`), plus `jq` for plugins that emit RFC 0004 run manifests.

## Develop locally

```bash
git clone git@github.com:pandas-studio/agent-team-plugins.git
cd agent-team-plugins
claude --plugin-dir ./debate-conductor   # load one plugin
claude --plugin-dir ./dev-trio
```

`/reload-plugins` picks up edits without restarting Claude Code.

## License

[MIT](./LICENSE).
