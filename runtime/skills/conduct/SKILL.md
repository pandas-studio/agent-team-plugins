---
description: Drive the langgraph-conductor durable runtime — start a bounded planner/researcher/coder/reviewer run against a spec, check its status, and approve or reject the ship interrupt. Use when the user asks to run, resume, inspect, or approve an agent-team graph run.
disable-model-invocation: true
allowed-tools: Bash(uv:*) Bash(agent-team-graph:*) Read
---

# Drive a langgraph-conductor run

The runtime is this plugin's own root (`${CLAUDE_PLUGIN_ROOT}`), a `uv` project
invoked with `uv run --project`. It never calls a provider API directly — every
role goes through the shared `models.json` registry, same as the bash plugins.

Run every command below **from the user's project directory**, not from the
plugin root: `--workspace .` and the default `--state-dir .agent-team` are
resolved against the current directory, so `status`/`resume`/`approve` must
run from the same directory as `run`. A bare `uv run agent-team-graph` there
fails with "Failed to spawn" — `--project` is what points `uv` at the runtime.

## One-time setup

Requires `uv`. The environment lives in the plugin install directory, so re-run
this after a plugin update. Finish (approve or reject) any run parked at
approval before updating: a newer version may compute the change digest
differently, and the parked run then stops as `needs-human` — start a new run.
Also let every running invocation from an older version exit first: the
one-process-per-thread lock (exit 7) only holds between versions that take it,
and 0.1.3 and earlier do not.

```bash
uv sync --project "${CLAUDE_PLUGIN_ROOT}" --frozen --python 3.12
```

## Start a run

Every argument below is required except `--max-attempts`, `--strict-ignored`,
and `--exclude-path`.
`--allow-path` is **repository-root-relative** and repeatable; anything the
coder changes outside it fails the gate.

Start from a clean tree. A change that is already present outside `--allow-path`
(including an uncommitted `SPEC.md`) would fail every attempt, so the run is
refused before any role runs (`needs-human`, see `05-preexisting-changes.json`):
commit the spec or keep it outside the repository. Changes already present inside
`--allow-path` are kept, listed as `preexisting_changes` in `00-context.json`, and
attested together with the coder's.

```bash
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph run \
  --project-id demo --workspace . --spec SPEC.md \
  --task "implement the first vertical slice" \
  --test-command "pytest -q" \
  --allow-path src --allow-path tests \
  --exclude-path .reviewer-cache
```

The command prints a JSON view containing the `thread_id`. Keep it — every
other subcommand takes it. `run --thread-id` with an id that already exists is
refused (exit 2); continue that thread with `resume` or `approve` instead.

## Inspect, resume, approve

```bash
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph status  --thread-id <id>
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph resume  --thread-id <id>   # continue after a crash
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph approve --thread-id <id> --decision approve
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph approve --thread-id <id> --decision reject
```

## Exit codes

Branch on these rather than parsing the JSON:

| code | meaning |
| ---- | ------- |
| 0 | approved — the run reached `publish` and wrote an approval receipt |
| 3 | still open — parked at the ship-approval interrupt, needs `approve` |
| 4 | stopped without approval (`rejected` or `needs-human`) |
| 5 | unknown `--thread-id` |
| 6 | incomplete — stopped before reaching approval (a crash or an interrupted process); `resume` continues from the last checkpoint |
| 7 | busy — another process is running this thread; try again when it exits |

Role and test-command timeouts do not crash a run: a coder timeout is a failed
attempt (retried while attempts remain), a planner or researcher timeout stops as
`needs-human`, and a reviewer timeout stops as `needs-human` without a verdict.

## Boundaries to preserve

- The approval receipt is **local only**: it records what was approved and
  never pushes, merges, or force-updates anything. Do not treat exit 0 as
  permission to push.
- The approval payload includes `reviewed_change_sha256`. On resume the runtime
  recomputes the current change identity and blocks approval if any attested
  tracked or untracked content changed while the graph was interrupted.
- `--allow-path` / `--exclude-path` spellings are canonicalized (`./src`,
  `src//x` → `src`, `src/x`). Absolute paths, `..`, and anything that resolves to
  the repository root are refused, and so is a `--state-dir` at the repository
  root. A changed file whose name is not valid UTF-8 fails the gate (it cannot
  be attested).
- A git clean/process filter (for example git-lfs) on any tracked path fails
  every gate and blocks approval: filters run before git compares files, so an
  edit could be invisible to the scope check and the digest. Use a workspace
  without such filters.
- **Trust boundary: the coder must not be able to write `.git`.** The gate and
  the digest ask git what changed, and git answers from its own config, index
  and refs. The runtime refuses the known ways that state hides content
  (clean/process filters, assume-unchanged/skip-worktree entries, replacement
  refs, a moved `core.worktree`), but a role with write access to `.git` is
  outside what an approval receipt can prove. Run the coder sandboxed without
  write access to `.git`.
- `--exclude-path` is a trusted, repeatable repository-root-relative exemption
  for tool scratch. Excluded content (tracked or untracked) is neither
  scope-checked nor attested; use
  the narrowest path and verify `excluded_paths_not_attested` before approval.
- `--strict-ignored` may take up to five full snapshots on a successful attempt
  (start, gate, pre-review, post-review, publish). It also refuses to start when
  ignored files already exist outside `--allow-path`, so a `.venv` or
  `node_modules` in the repository needs `--exclude-path` or a clean workspace.
  Exclude only trusted scratch paths; do not exempt coder output.
- `--test-command` is split as argv. Shell operators (`&&`, `|`, `>`) are not
  interpreted — wrap them in a script if you need them.
- Roles and the test command run non-interactively: stdin is `/dev/null` (0.1.3
  passed the CLI's own stdin through), and each runs in its own process group,
  which a timeout or a signalled CLI (Ctrl-C, SIGTERM, SIGHUP) kills as a whole.
  A signalled CLI then dies of that signal; `status` afterwards reports
  `incomplete` (exit 6) and `resume` continues the run. A command
  that prompts or reads stdin sees EOF; feed it input from a file in a wrapper
  script instead.
- Artifacts under `.agent-team/artifacts/<run_id>/` are immutable and published
  whole (never partially written). If a write conflicts, start a new run instead
  of deleting them.
- **Trust boundary: roles must not write the state directory** (`--state-dir`,
  default `.agent-team`, excluded from attestation). A role that can write it can
  rewrite the checkpoint database, so it is trusted like `.git`. The store refuses a
  symlink at an artifact's own name, but not one planted higher up. When the coder
  is not sandboxed, put `--state-dir` outside the repository.
