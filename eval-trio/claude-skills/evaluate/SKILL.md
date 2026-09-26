---
name: evaluate
description: Evaluate a submitted local result against a task and criteria with fixed checks, a Challenger, and an independent Judge.
---

# Eval Trio

Create a version 1 case JSON following `${CLAUDE_PLUGIN_ROOT}/README.md`. Put the task,
criteria, and independent check files beside it. Run
`DEV_TRIO_PM_HOST=claude "${CLAUDE_PLUGIN_ROOT}/bin/eval-trio" run --case <case.json> --output-dir <fresh-private-dir> --allow-execution`.
Use `--checks-only` to skip model reviews and authentication. Check the
authoritative `report.json`, its `status`, `mode`, `reason`, and `exit_code`.
`PASS` requires fixed checks and both model reviews; `HOLD` is never a pass.
Never claim the copied workspaces are an OS sandbox. Submitted code and model
tools can run with the invoker's privileges. Do not modify the submission.
