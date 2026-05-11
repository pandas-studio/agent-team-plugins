---
description: Install (or upgrade) the dev-trio PM orchestration policy into the workspace's CLAUDE.md. Idempotent — appends a marker-guarded block; re-running upgrades in place. Run once per workspace after installing the plugin. The policy tells Claude when to dispatch ask-gemini.sh / ask-codex.sh and how to handle NEED RESEARCH round-trips.
disable-model-invocation: true
allowed-tools: Bash(cat:*) Bash(ls:*) Read Edit Write
---

# Install the dev-trio PM policy into workspace `CLAUDE.md`

This skill copies the plugin-bundled PM orchestration policy (`<plugin-root>/lib/pm.md`) into the **current workspace's** `CLAUDE.md`, between explicit markers so it can be upgraded in place.

## Why this exists

The dev-trio pattern depends on Claude (PM/Coder) seeing the routing policy on **every turn** in this workspace — when to call Gemini, when to call Codex, how to handle a `NEED RESEARCH` block, how to namespace logs per team. That policy lives in `CLAUDE.md` so it's always in context. The plugin ships the source of truth at `lib/pm.md`; this skill installs/upgrades it in your workspace without you having to copy-paste.

The block is guarded by:

```
<!-- BEGIN dev-trio PM policy -->
...
<!-- END dev-trio PM policy -->
```

so re-running the skill replaces the block in place (no duplication). The rest of `CLAUDE.md` is untouched.

## Steps

### 1 · Locate the plugin's `pm.md`

The bundled source of truth is at `<plugin-root>/lib/pm.md`. The plugin root depends on how the user installed it; resolve at runtime by walking up from the skill's location, or by leveraging the on-PATH bin scripts:

```bash
# ask-gemini.sh resolves PLUGIN_ROOT internally; reuse its path to find pm.md.
GEMINI_BIN=$(command -v ask-gemini.sh) || { echo "dev-trio plugin not loaded — /plugin install dev-trio first" >&2; exit 2; }
PLUGIN_ROOT=$(cd "$(dirname "$GEMINI_BIN")/.." && pwd)
PM_SRC="$PLUGIN_ROOT/lib/pm.md"
[ -f "$PM_SRC" ] || { echo "error: pm.md missing at $PM_SRC" >&2; exit 2; }
```

Use `cat` to read its contents.

### 2 · Determine the target `CLAUDE.md`

Target = `$PWD/CLAUDE.md`. Two cases:

- **Does not exist** → create it with just the marker block.
- **Exists** → check for the marker pair `<!-- BEGIN dev-trio PM policy -->` / `<!-- END dev-trio PM policy -->`:
  - **Both markers present** → replace everything between them (use `Edit` with the old block matched verbatim).
  - **Markers absent** → append the marker block to the end of the file (use `Edit` to add after the existing content, or `Write` if the file is small enough to load).

### 3 · Compose the block

The block is exactly:

```
<!-- BEGIN dev-trio PM policy -->
<contents of lib/pm.md, verbatim>
<!-- END dev-trio PM policy -->
```

Do **not** wrap the contents in additional markdown headings — `pm.md` already begins with its own `# CLAUDE.md — dev-trio orchestration policy` heading. Do **not** rewrite the contents — install verbatim so future upgrades (re-runs of this skill against an updated plugin) replace cleanly.

### 4 · Confirm to the user

After write, tell the user:

> Installed dev-trio PM policy into `$PWD/CLAUDE.md` (block: `<!-- BEGIN dev-trio PM policy -->` … `<!-- END dev-trio PM policy -->`). Start a fresh Claude Code session in this workspace to pick it up — `CLAUDE.md` is loaded at session start.
>
> To upgrade after a plugin update, re-run `/dev-trio:install-pm`. The block is replaced in place; the rest of your `CLAUDE.md` is untouched.

If the user is in the same Claude session that installed it, note that the policy won't take effect until they restart — `CLAUDE.md` is loaded once at session start, not re-read mid-session.

## Constraints

- **Idempotent.** Re-running must not duplicate the block. Always look for the marker pair before deciding insert vs replace.
- **Do not modify content outside the markers.** The user may have unrelated `CLAUDE.md` content (project conventions, other plugins' policies); leave it alone.
- **Do not install into a parent dir's `CLAUDE.md`.** The target is `$PWD/CLAUDE.md` (workspace root), regardless of where `git rev-parse --show-toplevel` points or where `pm.md` lives.
- **Do not run if `dev-trio` plugin is not loaded.** The `command -v ask-gemini.sh` check at step 1 is load-bearing — without it you can't resolve the plugin root reliably.
