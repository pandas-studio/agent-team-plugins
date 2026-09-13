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

```bash
uv sync --project "${CLAUDE_PLUGIN_ROOT}" --frozen --python 3.12
```

## Start a run

Every argument below is required except `--max-attempts`, `--strict-ignored`,
and `--exclude-path`.
`--allow-path` is **repository-root-relative** and repeatable; anything the
coder changes outside it fails the gate.

```bash
uv run --project "${CLAUDE_PLUGIN_ROOT}" agent-team-graph run \
  --project-id demo --workspace . --spec SPEC.md \
  --task "implement the first vertical slice" \
  --test-command "pytest -q" \
  --allow-path src --allow-path tests \
  --exclude-path .reviewer-cache
```

The command prints a JSON view containing the `thread_id`. Keep it — every
other subcommand takes it.

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
- `--exclude-path` is a trusted, repeatable repository-root-relative exemption
  for tool scratch. Excluded content (tracked or untracked) is neither
  scope-checked nor attested; use
  the narrowest path and verify `excluded_paths_not_attested` before approval.
- `--strict-ignored` may take up to four full snapshots on a successful attempt.
  Exclude only trusted scratch paths; do not exempt coder output.
- `--test-command` is split as argv. Shell operators (`&&`, `|`, `>`) are not
  interpreted — wrap them in a script if you need them.
- Artifacts under `.agent-team/artifacts/<run_id>/` are immutable. If a write
  conflicts, start a new run instead of deleting them.
