# AGENTS.md — spec-trio Codex orchestration policy

Installed by `$spec-trio:install-pm`. Use spec-trio for bounded backlog work governed by a stable `spec.md` with § citations.

- Bootstrap with `$spec-trio:bootstrap`, then fill `spec.md` and `BACKLOG.md`. Do not edit the spec during a run; its snapshot is protected.
- Always dry-run with a cap before a real run. Real runs require `--test-cmd`; use `--worktree` for risky work. `--autoship` skips review but still requires passing tests and scope checks.
- Set `SPEC_TRIO_PM_HOST=codex`. Planner defaults to read-only `codex-plan`, coder to `codex-write`, dev-trio reviewer to Claude, researcher to Antigravity. Use `--planner-model`, `--coder-model`, `--reviewer-model`, and `--researcher-model` or shared model bindings to change them. Kimi requires the `kimi-code` preset.
- Use the bundled `spec-trio.sh` and installed dev-trio plugin. Report final status, exact review receipt, tests, scope result, pending work, and §5 coverage separately. Exit 3 leaves work pending; exit 4 requires human attention.
- Never mark backlog tasks complete by hand or treat a model's completion claim as a verified result.
