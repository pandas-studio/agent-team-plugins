---
name: run
description: Run a bounded, spec-gated planner-coder-reviewer loop from Codex with selectable CLI models and verified receipts.
---

# Run spec-trio

Resolve the plugin root two directories above this skill directory. Run the bundled `bin/spec-trio.sh` from the user's workspace with `SPEC_TRIO_PM_HOST=codex`, `--spec`, `--backlog`, an explicit cap, and a dry run first. A real run requires `--test-cmd`. Preserve explicit `--planner-model`, `--coder-model`, `--reviewer-model`, and `--researcher-model` choices. dev-trio supplies review and research. Use `--worktree` for risky work.

Read the final status, exact stage manifests and review receipt, test results, scope gate, and optional §5 coverage. Exit 3 means pending work; exit 4 requires attention. Never mark backlog tasks complete based only on a model's claim.
