# AGENTS.md — ralph-trio Codex orchestration policy

Installed by `$ralph-trio:install-pm`. Use bounded Ralph loops for repeatable backlog work. Codex conducts the run; the Bash driver invokes models independently for each stage.

- Bootstrap workspace files with `$ralph-trio:bootstrap`. Fill `PROMPT.md` and `BACKLOG.md` before a real run.
- Always pass `--max-iter` and/or `--max-runtime`, and run a one-iteration `--dry-run` first. For risky changes use `--worktree` and a real test command.
- In Codex host mode, solo worker and trio coder default to `codex-write`; trio planner defaults to `codex-plan`; dev-trio review defaults to Claude and research to Antigravity. `--worker-model`, `--planner-model`, `--coder-model`, `--reviewer-model`, and `--researcher-model` override these defaults. Use `agent-team-models preset add kimi-code` before selecting Kimi.
- Use the bundled driver under `<plugin-root>/bin/`; set `RALPH_TRIO_PM_HOST=codex`. Trio/meta need the installed dev-trio plugin; debate needs debate-conductor. The Claude Stop hook does not apply to Codex.
- Read the exact run summary, manifests, `fix_plan.md`, and review receipts after a run. Treat failed dispatch and unknown review as incomplete; never infer SHIP from a streamed transcript.
- Do not edit backlog completion markers mid-run, launch uncapped loops, or put secrets in prompts sent to companion CLIs.
