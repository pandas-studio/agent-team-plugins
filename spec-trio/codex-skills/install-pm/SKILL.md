---
name: install-pm
description: Install or update the spec-trio Codex PM policy in the current workspace AGENTS.md when requested.
---

# Install the Codex PM policy

Resolve the plugin root two directories above this skill directory. Read `lib/pm-codex.md`, then run `python3 <plugin-root>/bin/install-pm.py --host codex` from the target workspace. The installer updates only the marked spec-trio block in this directory's `AGENTS.md`; it preserves other content and refuses malformed markers or symlinks. Read the result back and tell the user to start a new Codex session for the policy to load.
