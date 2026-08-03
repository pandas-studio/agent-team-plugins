---
description: Drive the langgraph-conductor durable runtime — start a bounded planner/researcher/coder/reviewer run against a spec, check its status, and approve or reject the ship interrupt. Use when the user asks to run, resume, inspect, or approve an agent-team graph run.
disable-model-invocation: true
allowed-tools: Bash(uv:*) Bash(agent-team-graph:*) Read
---

# Drive a langgraph-conductor run

The runtime lives in the plugin's `runtime/` directory and is invoked through
`uv`. It never calls a provider API directly — every role goes through the
shared `models.json` registry, same as the bash plugins.

## One-time setup

```bash
cd <plugin-root> && uv sync --frozen --python 3.12
```

## Start a run

Every argument below is required except `--max-attempts`, `--strict-ignored`,
and `--exclude-path`.
`--allow-path` is **repository-root-relative** and repeatable; anything the
coder changes outside it fails the gate.

```bash
uv run agent-team-graph run \
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
uv run agent-team-graph status  --thread-id <id>
uv run agent-team-graph resume  --thread-id <id>              # continue after a crash
uv run agent-team-graph approve --thread-id <id> --decision approve
uv run agent-team-graph approve --thread-id <id> --decision reject
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
- `--exclude-path` is a trusted, repeatable repository-root-relative exemption
  for tool scratch. Excluded content is neither scope-checked nor attested; use
  the narrowest path and verify `excluded_paths_not_attested` before approval.
- `--strict-ignored` may take up to four full snapshots on a successful attempt.
  Exclude only trusted scratch paths; do not exempt coder output.
- `--test-command` is split as argv. Shell operators (`&&`, `|`, `>`) are not
  interpreted — wrap them in a script if you need them.
- Artifacts under `.agent-team/artifacts/<run_id>/` are immutable. If a write
  conflicts, start a new run instead of deleting them.
