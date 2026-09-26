---
name: bootstrap
description: Seed spec.md, BACKLOG.md, and fix_plan.md for a spec-trio loop without overwriting existing files.
---

# Bootstrap spec workspace

Resolve the plugin root two directories above this skill directory. From the intended workspace, copy each missing file from `prompts/`: `spec.md.template` to `spec.md`, `BACKLOG.md.template` to `BACKLOG.md`, and `fix_plan.md.template` to `fix_plan.md`. Never overwrite a file or follow a destination symlink. Report each created or existing file. Tell the user to fill §1–§6 and add backlog tasks with § citations before a real run.
