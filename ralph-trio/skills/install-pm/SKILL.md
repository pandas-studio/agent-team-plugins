---
description: Install (or upgrade) the ralph-trio PM orchestration policy into the workspace's CLAUDE.md. Idempotent — appends a marker-guarded block; re-running upgrades in place. Run once per workspace after installing the plugin. The policy tells Claude when to launch a Ralph loop (solo / trio / debate / meta), how to cap and dry-run it, and how to read results back.
disable-model-invocation: true
allowed-tools: Read Edit Write
---

# Install the ralph-trio PM policy into workspace `CLAUDE.md`

This skill copies the plugin-bundled PM orchestration policy (`<plugin-root>/lib/pm.md`) into the **current workspace's** `CLAUDE.md`, between explicit markers so it can be upgraded in place.

## Why this exists

ralph-trio loops run **headless** — but Claude is the one who decides *when* to launch one, *which variant*, and *with what caps*, and who reads the results back. That routing policy lives in `CLAUDE.md` so it's in context on **every turn** of the workspace. The plugin ships the source of truth at `lib/pm.md`; this skill installs/upgrades it without you copy-pasting.

The block is guarded by:

```
<!-- BEGIN ralph-trio PM policy -->
...
<!-- END ralph-trio PM policy -->
```

so re-running the skill replaces the block in place (no duplication). The rest of `CLAUDE.md` is untouched.

## Steps

### 1 · Locate the plugin's `pm.md`

The bundled source of truth is at `${CLAUDE_PLUGIN_ROOT}/lib/pm.md`. Claude Code substitutes `CLAUDE_PLUGIN_ROOT` to the plugin's install directory at skill-execution time, so this path is the same regardless of how the marketplace was added (HTTPS, local clone, custom dir).

Use the **Read tool** on `${CLAUDE_PLUGIN_ROOT}/lib/pm.md` to load its contents. No shell lookup is needed — the Read tool resolves the env var in the path.

If the Read fails (file not found / env var empty), surface this error to the user verbatim and stop: `ralph-trio plugin install appears broken — lib/pm.md missing under $CLAUDE_PLUGIN_ROOT; reinstall via /plugin install ralph-trio@pandas-studio.`

### 2 · Determine the target `CLAUDE.md`

Target = `$PWD/CLAUDE.md`. Two cases:

- **Does not exist** → create it with just the marker block.
- **Exists** → check for the marker pair `<!-- BEGIN ralph-trio PM policy -->` / `<!-- END ralph-trio PM policy -->`:
  - **Both markers present** → replace everything between them (use `Edit` with the old block matched verbatim).
  - **Markers absent** → append the marker block to the end of the file (use `Edit` to add after the existing content, or `Write` if the file is small enough to load).

### 3 · Compose the block

The block is exactly:

```
<!-- BEGIN ralph-trio PM policy -->
<contents of lib/pm.md, verbatim>
<!-- END ralph-trio PM policy -->
```

Do **not** wrap the contents in additional markdown headings — `pm.md` already begins with its own `# CLAUDE.md — ralph-trio orchestration policy` heading. Do **not** rewrite the contents — install verbatim so future upgrades (re-runs of this skill against an updated plugin) replace cleanly.

### 4 · Confirm to the user

After write, tell the user:

> Installed ralph-trio PM policy into `$PWD/CLAUDE.md` (block: `<!-- BEGIN ralph-trio PM policy -->` … `<!-- END ralph-trio PM policy -->`). Start a fresh Claude Code session in this workspace to pick it up — `CLAUDE.md` is loaded at session start.
>
> To upgrade after a plugin update, re-run `/ralph-trio:install-pm`. The block is replaced in place; the rest of your `CLAUDE.md` is untouched.

If the user is in the same Claude session that installed it, note that the policy won't take effect until they restart — `CLAUDE.md` is loaded once at session start, not re-read mid-session.

## Constraints

- **Idempotent.** Re-running must not duplicate the block. Always look for the marker pair before deciding insert vs replace.
- **Do not modify content outside the markers.** The user may have unrelated `CLAUDE.md` content (project conventions, other plugins' policies — e.g. dev-trio's own block); leave it alone.
- **Do not install into a parent dir's `CLAUDE.md`.** The target is `$PWD/CLAUDE.md` (workspace root), regardless of where `git rev-parse --show-toplevel` points or where `pm.md` lives.
- **Do not run if `ralph-trio` plugin is not loaded.** The `command -v ralph-solo.sh` check at step 1 is load-bearing — without it you can't resolve the plugin root reliably.
