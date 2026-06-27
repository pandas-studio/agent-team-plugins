---
description: Install (or upgrade) the ralph-trio Stop-hook into the workspace's .claude/settings.local.json so Claude Code keeps running the ralph-solo loop until the completion marker appears or RALPH_MAX_ITER is reached. Idempotent — merges into existing hooks block, never duplicates the entry.
disable-model-invocation: true
allowed-tools: Read Edit Write Bash(mkdir:*) Bash(jq:*) Bash(test:*)
---

# Install the ralph-trio Stop-hook into `.claude/settings.local.json`

This skill wires `stop-hook.sh` (on PATH from the ralph-trio plugin) as a Claude Code Stop hook in the **current workspace's** `.claude/settings.local.json`. Once installed, every time Claude tries to end its turn the hook fires and either allows the stop (completion marker found, or max-iter reached) or blocks it and re-injects `PROMPT.md` for another iteration.

This is the in-session driver for the **solo** variant only. Trio and debate stay on bash drivers.

## Why this exists

The Stop-hook pattern keeps Claude looping on a single prompt without you driving from outside. Mirrors Huntley's canonical Ralph loop but inside Claude Code: each Stop event re-feeds `PROMPT.md` (and optionally a trimmed `fix_plan.md` excerpt) as `additionalContext` until the agent writes the literal `<promise>COMPLETE</promise>` marker in `fix_plan.md`.

## Prerequisites the user must set BEFORE starting the looped Claude Code session

The hook reads these env vars from the shell that launched `claude`. The skill itself does not set them — installing the hook only wires it up.

```bash
export RALPH_PROMPT=$PWD/PROMPT.md
export RALPH_FIX_PLAN=$PWD/fix_plan.md
export RALPH_MAX_ITER=50
export RALPH_VARIANT=solo
export AGENT_TEAM=ralph-session    # optional
```

The hook fail-safes: if any required env var is missing or the file doesn't exist, it allows the stop with a stderr warning rather than blocking forever.

## Steps

### 1 · Locate the plugin's snippet

The bundled snippet is at `${CLAUDE_PLUGIN_ROOT}/hooks/settings.snippet.json`. Use the **Read tool** on that path. If it fails (env var empty / file missing), surface the error and stop: `ralph-trio plugin install appears broken — hooks/settings.snippet.json missing under $CLAUDE_PLUGIN_ROOT; reinstall via /plugin install ralph-trio@pandas-studio.`

The snippet defines a `Stop` hook entry that calls `stop-hook.sh` (PATH-resolved while the ralph-trio plugin is active).

### 2 · Determine the target file

Target = `$PWD/.claude/settings.local.json`. Cases:

- **Directory missing** → `mkdir -p "$PWD/.claude"`.
- **File missing** → create with the minimal contents:
  ```json
  {
    "hooks": {
      "Stop": [
        {
          "matcher": "*",
          "hooks": [
            { "type": "command", "command": "stop-hook.sh" }
          ]
        }
      ]
    }
  }
  ```
- **File exists** → merge:
  - If `.hooks.Stop` already contains an entry whose `hooks[].command` is `stop-hook.sh`, do nothing (idempotent — already installed).
  - Otherwise, append the matcher block to `.hooks.Stop` (creating the array if absent).

Prefer `jq` for the merge if available — it preserves the rest of the file untouched:

```bash
TMP=$(mktemp)
jq '.hooks //= {} | .hooks.Stop //= [] | .hooks.Stop += [{
       "matcher": "*",
       "hooks": [{ "type": "command", "command": "stop-hook.sh" }]
     }]' "$PWD/.claude/settings.local.json" > "$TMP" && mv "$TMP" "$PWD/.claude/settings.local.json"
```

Before appending, check for an existing entry with the same command and skip the append if found (use `jq` to filter or read the file and grep). Idempotency is the contract.

### 3 · Confirm to the user

After write, tell the user:

> Installed Stop hook into `$PWD/.claude/settings.local.json` → calls `stop-hook.sh` (resolved from PATH via the ralph-trio plugin).
>
> Next steps (you, in a shell, before starting Claude Code):
>
> ```bash
> export RALPH_PROMPT=$PWD/PROMPT.md
> export RALPH_FIX_PLAN=$PWD/fix_plan.md
> export RALPH_MAX_ITER=50
> export RALPH_VARIANT=solo
> claude
> ```
>
> Then give Claude any opening message ("begin"). The hook will keep the loop alive until `<promise>COMPLETE</promise>` appears in `fix_plan.md`, or RALPH_MAX_ITER iterations have run.
>
> To remove the hook: edit `.claude/settings.local.json` and delete the entry whose command is `stop-hook.sh`.

## Constraints

- **Idempotent.** Re-running must not duplicate the entry. Always check for an existing entry with command=`stop-hook.sh` before appending.
- **Do not modify other hooks.** PreToolUse / PostToolUse / UserPromptSubmit / etc. in the same file must be preserved.
- **Workspace-scoped only.** The target is `$PWD/.claude/settings.local.json`, never `~/.claude/settings.json`.
- **Do not export env vars on the user's behalf.** They live in the shell that launches `claude`, not in `settings.local.json`. Instruct the user; don't try to persist them.
