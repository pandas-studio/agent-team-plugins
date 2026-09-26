---
description: Seed the workspace with ralph-trio's three template files — PROMPT.md, BACKLOG.md, fix_plan.md — copied from the plugin's prompts/ dir. Refuses to overwrite existing files. Run once per workspace before invoking ralph-solo.sh / ralph-trio.sh / ralph-debate.sh.
disable-model-invocation: true
allowed-tools: Bash(cp:*) Bash(ls:*) Bash(test:*) Read
---

# Bootstrap a workspace for ralph-trio

This skill copies the three Ralph workspace templates from the plugin into `$PWD`:

- `prompts/PROMPT.md.template`     → `./PROMPT.md`     (mission + completion criteria you'll fill in)
- `prompts/BACKLOG.md.template`    → `./BACKLOG.md`    (task checklist; used by trio + debate)
- `prompts/fix_plan.md.template`   → `./fix_plan.md`   (iteration log + completion marker)

It is **non-destructive**: if any of the three already exists in `$PWD`, this skill leaves it alone and reports which were copied vs which were skipped.

## Steps

### 1 · Confirm `$PWD` is the workspace root

`$CLAUDE_PLUGIN_ROOT` resolves to the plugin install dir. `$PWD` is the workspace. Confirm to the user where the seed will land:

```bash
echo "Workspace: $PWD"
echo "Plugin root: $CLAUDE_PLUGIN_ROOT"
```

If `$PWD` looks wrong (e.g. it's the plugin install dir itself), tell the user to `cd` into their repo first.

### 2 · Copy each template (refuse to overwrite)

For each of the three files, run:

```bash
test -e "$PWD/PROMPT.md"   || cp "$CLAUDE_PLUGIN_ROOT/prompts/PROMPT.md.template"   "$PWD/PROMPT.md"
test -e "$PWD/BACKLOG.md"  || cp "$CLAUDE_PLUGIN_ROOT/prompts/BACKLOG.md.template"  "$PWD/BACKLOG.md"
test -e "$PWD/fix_plan.md" || cp "$CLAUDE_PLUGIN_ROOT/prompts/fix_plan.md.template" "$PWD/fix_plan.md"
```

After each, report whether the file was created or already existed (the `test` short-circuits the `cp`).

### 3 · Tell the user what to do next

Summarize:

> Seeded:
> - `PROMPT.md`    — fill in the Mission + completion criteria sections before running.
> - `BACKLOG.md`   — add task lines (`- [ ] task ...`) for trio / debate.
> - `fix_plan.md`  — left empty; ralph writes here per iteration. Completion marker is `<promise>COMPLETE</promise>`.
>
> Logs land under `$PWD/.ralph-trio/log/<team>/` (override with `RALPH_TRIO_WORKSPACE`). Add `.ralph-trio/` to `.gitignore`.
>
> Variants:
> - **Solo** (no plugin deps): `ralph-solo.sh --max-iter 50`
> - **Trio** (needs dev-trio plugin): `/plugin install dev-trio@pandas-studio` then `ralph-trio.sh --max-iter 20 --backlog BACKLOG.md`
> - **Debate** (needs debate-conductor plugin): `/plugin install debate-conductor@pandas-studio` then `ralph-debate.sh --max-iter 5 --backlog BACKLOG.md`
> - **Meta** (post-run audit, needs dev-trio): `ralph-meta.sh --since-latest-run`
>
> Optional: install the in-session Stop-hook driver (solo only) → `/ralph-trio:install-stop-hook`.
>
> Run `ralph-trio-doctor.sh` any time to verify the environment.

## Constraints

- **Never overwrite.** If a file exists, leave it.
- **Workspace-only.** Do not write anywhere outside `$PWD`.
- **No mid-flight edits to the templates.** Just copy. The user fills them in.
