---
name: install-pm
description: Install or update the debate-conductor Antigravity PM policy in the current workspace GEMINI.md when requested.
---

# Install Antigravity PM Policy

Use this skill when the user requests persistent debate-conductor orchestration.
Resolve the plugin root two directories above this skill directory. Read the
bundled [Antigravity policy](../../lib/pm-agy.md), then run from the target
workspace:

```bash
python3 "<plugin-root>/bin/install-pm.py" --host agy
```

The installer targets only the current directory's `GEMINI.md`. It preserves
content outside the debate-conductor marker pair, updates an existing complete
block, and refuses incomplete/duplicate/reversed markers or a symlink target.
Do not repair those cases by replacing the whole file.

Read the resulting block back and report the actual path. Use a new Antigravity
session to verify persistent project instructions. Do not store a versioned
plugin-cache path in GEMINI.md or change `CLAUDE.md` / `AGENTS.md`, global model bindings,
authentication, plugin installations, commits, pushes, or merges as part of this
step.
