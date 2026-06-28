---
description: Seed the workspace with spec-trio's three template files — spec.md, BACKLOG.md, fix_plan.md — copied from the plugin's prompts/ dir. Refuses to overwrite existing files. Run once per workspace before invoking spec-trio.sh.
disable-model-invocation: true
allowed-tools: Bash(cp:*) Bash(ls:*) Bash(test:*) Read
---

# Bootstrap a workspace for spec-trio

This skill copies the three spec-trio workspace templates from the plugin into `$PWD`:

- `prompts/spec.md.template`     → `./spec.md`     (§1–§6 contract you'll fill in — Goals, Interfaces, Behavior, Constraints, Test criteria, Non-goals)
- `prompts/BACKLOG.md.template`  → `./BACKLOG.md`  (task list with §-citation examples)
- `prompts/fix_plan.md.template` → `./fix_plan.md` (iteration log + completion marker)

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
test -e "$PWD/spec.md"     || cp "$CLAUDE_PLUGIN_ROOT/prompts/spec.md.template"     "$PWD/spec.md"
test -e "$PWD/BACKLOG.md"  || cp "$CLAUDE_PLUGIN_ROOT/prompts/BACKLOG.md.template"  "$PWD/BACKLOG.md"
test -e "$PWD/fix_plan.md" || cp "$CLAUDE_PLUGIN_ROOT/prompts/fix_plan.md.template" "$PWD/fix_plan.md"
```

After each, report whether the file was created or already existed (the `test` short-circuits the `cp`).

### 3 · Tell the user what to do next

Summarize:

> Seeded:
> - `spec.md`      — fill in §1 Goals, §2 Interfaces, §3 Behavior, §4 Constraints, §5 Test criteria, §6 Non-goals **before** running. Keep the numbered headings stable — §-IDs become long-lived citation handles.
> - `BACKLOG.md`   — replace the example tasks with real ones, each citing a `§N` / `§N.M` from `spec.md`. If a task can't be expressed within the spec, amend the spec rather than the task.
> - `fix_plan.md`  — left empty; spec-trio writes here per iteration. Completion marker is `<promise>COMPLETE</promise>`.
>
> Logs land under `$PWD/.spec-trio/log/<team>/` (override with `SPEC_TRIO_WORKSPACE`). Add `.spec-trio/` to `.gitignore`.
>
> Required companion plugin (for the reviewer + researcher stages):
>
> ```
> /plugin install dev-trio@pandas-studio
> ```
>
> Then run:
>
> ```
> spec-trio.sh --spec spec.md --backlog BACKLOG.md --max-iter 10
> ```
>
> Add `--coverage-check` to classify each `### §5.N` against the commits the run produced. Run `spec-trio-doctor.sh` any time to verify the environment.

## Constraints

- **Never overwrite.** If a file exists, leave it.
- **Workspace-only.** Do not write anywhere outside `$PWD`.
- **No mid-flight edits to the templates.** Just copy. The user fills them in.
