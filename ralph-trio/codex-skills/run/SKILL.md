---
name: run
description: Run a bounded solo, trio, or debate Ralph loop from Codex with selectable CLI models and inspect its receipts.
---

# Run a Ralph loop

Resolve the plugin root two directories above this skill directory. Choose `bin/ralph-solo.sh`, `bin/ralph-trio.sh`, or `bin/ralph-debate.sh` from the user's requested variant. Run from the user's workspace with `RALPH_TRIO_PM_HOST=codex`, an explicit iteration or runtime cap, and a dry run before real execution. Preserve user supplied model options; for solo use `--worker-model`, for trio use `--planner-model`, `--coder-model`, `--reviewer-model`, and `--researcher-model`. Debate uses its existing generator and critic configuration through debate-conductor.

Trio and meta require dev-trio; debate requires debate-conductor. For debate use `--generator-model` and `--critic-model` when the user selects models. Use `--worktree` and a test command for risky changes. After execution read the summary and exact stage manifests and review receipts. Report completion, pending work, tests, and failures without treating an unparsed review or a model claim as SHIP. Do not run the Claude Stop hook in Codex.
