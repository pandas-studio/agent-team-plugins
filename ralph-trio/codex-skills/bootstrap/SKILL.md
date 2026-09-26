---
name: bootstrap
description: Seed PROMPT.md, BACKLOG.md, and fix_plan.md for a Ralph loop in the current workspace without overwriting existing files.
---

# Bootstrap Ralph workspace

Resolve the plugin root two directories above this skill directory. From the intended workspace, copy each missing file from `prompts/`: `PROMPT.md.template` to `PROMPT.md`, `BACKLOG.md.template` to `BACKLOG.md`, and `fix_plan.md.template` to `fix_plan.md`. Never overwrite a file or follow a destination symlink. Report each created or existing file, then ask the user to fill the mission and backlog before a real run. Logs will live in `.ralph-trio/` unless configured otherwise.
