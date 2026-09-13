---
name: install-pm
description: Install or update the debate-conductor Codex PM policy in the current workspace AGENTS.md when requested.
---

# Install Codex PM Policy

Use this skill when the user requests persistent debate-conductor orchestration.
Resolve the plugin root two directories above this skill directory. Read the
bundled [Codex policy](../../lib/pm-codex.md), then run from the target
workspace:

```bash
python3 "<plugin-root>/bin/install-pm.py" --host codex
```

The installer targets only the current directory's `AGENTS.md`. It preserves
content outside the debate-conductor marker pair, updates an existing complete
block, and refuses incomplete/duplicate/reversed markers or a symlink target.
Do not repair those cases by replacing the whole file.

Read the resulting block back and report the actual path. Use a new Codex
session to verify persistent project instructions. Do not store a versioned
plugin-cache path in AGENTS.md or change `CLAUDE.md`, global model bindings,
authentication, plugin installations, commits, pushes, or merges as part of this
step.
