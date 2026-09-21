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

Start with a clean worktree. Commit SPEC.md first or keep it outside the repository.
Tracked/untracked pre-existing changes are reported before any model call; strict ignored
mode also checks ignored files. Do not automatically exempt existing user files.
The default is **2 total attempts (1 retry)**, with at most **5 total attempts**.
Role timeouts, nonzero exits and empty answers consume an attempt. Successful plan/research
outputs are reused. This does not bound retries or billing inside a model CLI.

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
| 2 | invalid input, invalid transition, or a busy thread |
| 3 | an actual ship-approval interrupt exists, needs `approve` |
| 4 | neither approved nor awaiting approval, including crashed `running` checkpoints |
| 5 | unknown `--thread-id` |

The JSON `awaiting_approval` reflects the saved interrupt, not just `status=running`.
Inspect `next` and `errors` for a stopped execution. SIGINT/SIGTERM return 130/143 after cleanup.

## Reuse and recovery

Only terminal threads can start another run. A new run resets intermediate fields and
artifact/usage/error lists while retaining old checkpoints and files. Pending approval
requires `approve`; `resume` returns code 3 without discarding that interrupt.
Mutating commands lock one thread at a time; `status` and rejecting an approval work even
with a broken model registry.
Pre-existing workspace changes take precedence over model-configuration errors and return 4.
On a clean workspace, model-configuration errors return 2 before checkpoint updates.

The runtime reserves each attempt before its external calls. Call start/completion records
prevent silent repetition after a crash. Explicit resume grants replay only to the run, attempt
and role pending in its starting checkpoint, with matching output hashes and workspace digest.
Existing receipts for a fresh run or any later call are rejected. An incomplete call or changed workspace stops for human
recovery; inspect the files and any surviving processes, then start a new run. SIGKILL and
processes escaping into a separate session cannot be cleaned up reliably.
On non-strict gate replay, a previously published gate artifact keeps its original informational
ignored-path listing while all attested fields are revalidated. Strict mode rejects ignored-file drift.
Legacy approval/terminal checkpoints remain supported. A legacy checkpoint interrupted in
an external-call node has no receipt: resume returns 4 with recovery guidance and preserves it.
Never infer that adding a new graph node will run it before an already saved pending node.
Python callers must supply an operator-validated canonical `artifact_root` (resolve trusted
OS aliases such as macOS `/tmp` first), own the thread lock and use `resume_graph(graph, config)`
for recovery. Ordinary `graph.invoke` does not authorize receipt replay; replay authority is
invocation context and is never checkpointed.

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
- **Trust boundary: the coder must not be able to write the state-dir either.** Checkpoints
  and call receipts control recovery and approval and are excluded from scope checks/digests.
  Put state outside the coder's writable workspace and deny sandbox write access to it.
  Moving the path alone does not restrict an unsandboxed CLI running as the same user.
  The default `.agent-team` also requires protection; the runtime does not create a sandbox.
- `--exclude-path` is a trusted, repeatable repository-root-relative exemption
  for tool scratch. Excluded content (tracked or untracked) is neither
  scope-checked nor attested; use
  the narrowest path and verify `excluded_paths_not_attested` before approval.
- `--strict-ignored` reads ignored files during preflight, call completion and gate/review/approval
  snapshots, including recovery validation. Exclude only trusted scratch paths; do not exempt coder output.
- `--test-command` is split as argv. Shell operators (`&&`, `|`, `>`) are not
  interpreted — wrap them in a script if you need them.
- Artifacts under `.agent-team/artifacts/<run_id>/` are immutable. If a write
  conflicts, start a new run instead of deleting them.
