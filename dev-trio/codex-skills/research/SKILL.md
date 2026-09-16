---
name: research
description: Run a dev-trio research CLI from Codex when the task needs external library, API, or specification evidence.
---

# Research from Codex

Resolve the plugin root from this loaded file: two directories above this
skill directory. The shared entry point is [ask-agy.sh](../../bin/ask-agy.sh).
Do not assume the plugin added its bin directory to PATH.

Run from the user's workspace, passing the question as one quoted argument:

```bash
DEV_TRIO_PM_HOST=codex "<plugin-root>/bin/ask-agy.sh" "<question>" </dev/null
```

When there is additional context, pass it through stdin instead of /dev/null.
Preserve the actual working directory and any explicit role model overrides.
The wrapper chooses the researcher and records its actual model in the log.

Capture the invocation's exit code and the log path printed on stderr. On a
nonzero exit report the failure; do not silently retry or use an older log.
On success summarize the evidence with cited URLs and link that run's log.
If this is part of an authorized review workflow, pass the captured research
file to the reviewer. No tmux session is required.
