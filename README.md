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
```

## Plugins

| Name | Roles | Episode | Status |
| :--- | :--- | :--- | :--- |
| [debate-conductor](./debate-conductor) | Claude=PM · Gemini=Generator · Codex=Critic | EP B | shipped |

More plugins (watch-pair, spec-trio, bisect-bot, ralph-trio) follow the same shape and will land here as their EPs publish.

## Pattern

Every plugin in this marketplace follows the same layout:

```
<plugin>/
├── .claude-plugin/plugin.json
├── skills/
│   ├── bootstrap/SKILL.md   # one-time tmux layout setup
│   └── run/SKILL.md         # the orchestration entry point
├── bin/                     # on PATH while plugin is active
│   └── *.sh                 # tmux/bootstrap helpers
├── lib/                     # internal — invoked by the run skill
│   ├── *.sh                 # engine
│   └── roles/*.md           # role prompts for companion CLIs
└── topics/                  # default examples; workspace can override
```

`bin/` and `lib/` are bash. Roles are markdown. Skills are markdown with YAML frontmatter. No language runtime beyond bash + the third-party CLIs (`claude`, `gemini`, `codex`).

## Develop locally

```bash
git clone git@github.com:pandas-studio/agent-team-plugins.git
cd agent-team-plugins
claude --plugin-dir ./debate-conductor   # load one plugin
```

`/reload-plugins` picks up edits without restarting Claude Code.

## License

[MIT](./LICENSE).
