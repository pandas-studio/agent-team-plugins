# debate-conductor

Claude or Codex conducts a Generator vs Critic adversarial debate over N rounds. Three-pane tmux layout: left = PM, middle = Generator transcript live tail, right = Critic transcript live tail.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | Conductor / PM | Claude Code or Codex (this session) |
| Middle | Generator | `agy` |
| Right | Critic | `codex` from Claude PM, `claude` from Codex PM |

## Prerequisites

- `tmux`
- `claude` (Claude Code)
- `agy` (Antigravity CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated
- `jq` (1.6+) — required for the model registry

Models and CLI binaries are configurable — see [Model configuration](#model-configuration). Quick binary overrides still work: `AGY_CLI`, `CODEX_CLI`, `CLAUDE_CLI` (per model), `GENERATOR_CLI` / `CRITIC_CLI` (per role).

## Install

Via the Claude Code marketplace:

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install debate-conductor@pandas-studio
```

### Codex PM

Codex can load the same engine through the repo's Codex marketplace:

```bash
codex plugin marketplace add /absolute/path/to/agent-team-plugins
codex plugin add debate-conductor@pandas-studio
```

Use `$debate-conductor:run`, `$debate-conductor:continue`,
`$debate-conductor:bootstrap`, and `$debate-conductor:install-pm`. The Codex
`install-pm` skill installs persistent routing instructions into `AGENTS.md`;
it does not change `CLAUDE.md`.

In Codex host mode, the default Critic is Claude Code so Codex does not call
itself as the external critic. Explicit model settings still win.

For local development on this plugin:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git

# Claude Code
claude --plugin-dir ./agent-team-plugins/debate-conductor

# Codex
codex plugin marketplace add /absolute/path/to/agent-team-plugins
codex plugin add debate-conductor@pandas-studio
```

## Use

1. From a workspace dir (any project with — or without — a custom `topics/` folder):
   ```bash
   tmux new-session -s debate
   # inside tmux:
   claude
   ```

2. In the Claude session:
   ```
   /debate-conductor:bootstrap
   ```
   This splits the current pane into 3 columns and starts the role-tail viewers.

3. (Recommended on first install) Install the PM orchestration policy into the workspace's `CLAUDE.md`:
   ```
   /debate-conductor:install-pm
   ```
   This appends a marked block to `$PWD/CLAUDE.md` between `<!-- BEGIN debate-conductor PM policy -->` / `<!-- END debate-conductor PM policy -->`. Re-running upgrades in place; safe to run again after plugin updates. The policy is intentionally tight (~20 lines) and only carries the per-turn routing rules: when to dispatch a debate vs answer directly, how to frame the stance, how to report the verdict back.

4. Run a debate:
   ```
   /debate-conductor:run 1
   ```
   Resolves topic 1 from `topics/`, runs the default 3-round debate (Antigravity gen → Codex crit → Antigravity gen), and afterwards Claude reads the round files and surfaces verdict + move-by-move.

5. Follow up in natural language: "round 3 결정타?", "5라운드로 다시 돌려줘", "rotate ON으로 토픽 2", etc.

### Run until converged

Instead of a fixed round count, let the debate decide its own length:

```
debate.sh --until-converged "<topic>"          # cap 6 rounds
debate.sh --until-converged -n 8 "<topic>"     # cap 8 rounds
```

The loop stops as soon as a Critic round emits the canonical `Verdict: STRENGTHEN` line (position is sound); `-n` is the upper bound, defaulting to an even cap of 6 so a non-converging debate still ends on a Critic verdict. The empty round files past the convergence point are cleaned up. The `/debate-conductor:run` skill passes this flag when you ask to debate "합의/수렴할 때까지" / "until they agree".

## Workspace topics

Place topic files at `<workspace>/topics/0N-*.txt`. Each file is a stance-driven prompt the Generator receives. The plugin ships three default examples in its own `topics/` — you can copy them into your workspace as a starting point. The skill checks workspace `topics/` first, falls back to the plugin's bundled examples if absent.

## Model configuration

Generator and Critic resolve through the shared model registry (the [marketplace README](../README.md#shared-model-configuration) covers it in full). Claude host defaults: `agy` (generator), `codex` (critic). Codex host defaults: `agy` (generator), `claude` (critic).

| Role | Default | Pick a different model | Override its binary |
| :--- | :--- | :--- | :--- |
| `debate-conductor.generator` | `agy` | `--primary-gen=<model>`, `DEBATE_GENERATOR_MODEL` env, or `agent-team-models set-role debate-conductor.generator <model>` | `GENERATOR_CLI` · `AGY_CLI` |
| `debate-conductor.critic` | `codex` from Claude, `claude` from Codex | `--primary-crit=<model>`, `DEBATE_CRITIC_MODEL` env, or `agent-team-models set-role debate-conductor.critic <model>` | `CRITIC_CLI` · `CODEX_CLI` · `CLAUDE_CLI` |

`--primary-gen` / `--primary-crit` accept any registered model id (run `agent-team-models list`); generator and critic must differ. With no critic specified, Claude host still defaults to "the other one" (codex unless gen=codex, then agy). Codex host defaults to Claude unless that would duplicate the generator. The legacy `DEBATE_PRIMARY_GEN` env var also keeps working.

For models declaring `final_args`, `GENERATOR_CLI` and `CRITIC_CLI` wrappers
must forward all arguments to the selected CLI (for example, `exec codex "$@"`).
Codex receives `--output-last-message <path>` before the prompt. Wrappers that
assume a fixed prompt position must be updated; a successful CLI exit without
a native final-answer file fails with rc=5 and an explicit capture diagnostic.
There is no fallback to console output.

When a `GENERATOR_CLI` or `CRITIC_CLI` wrapper is used with the `claude` model,
it must handle `auth status --json`; Codex host mode probes that command before
creating or retargeting a debate log.

New debates honor persistent `agent-team-models set-role` bindings. Continued
debates reuse the transcript's saved model pair and any saved rotation unless
this invocation passes `--primary-gen`, `--primary-crit`,
`DEBATE_GENERATOR_MODEL`, `DEBATE_CRITIC_MODEL`, or `DEBATE_PRIMARY_GEN`.
For rotated transcripts, continue also keeps the original model pair because
prior round filenames encode the pair. Start a fresh debate to change model pairs
inside rotation or to change whether rotation is enabled.

```bash
agent-team-models preset add kimi-code
debate.sh --primary-crit=kimi-code "your topic"                # one-off
agent-team-models set-role debate-conductor.critic kimi-code   # persistent
```

## Logs

Round transcripts and per-round model logs land in:

```
$PWD/.debate-conductor/log/<team>/
├── latest-debate -> debate-<TS>
├── latest-debate.json         # committed selection: version, sequence, physical debate directory
├── .latest-debate.lock        # short-lived selection publication lock (not the debate writer lock)
├── debate-<TS>/
│   ├── .lock -> host=… pid=…  # present only while a debate.sh run is writing this debate
│   ├── index.jsonl            # append-only attempt ledger — which rounds completed, and how
│   ├── topic.txt              # original topic — read by /continue
│   ├── context.md             # round-1 context file, if given — reused when round 1 is retried
│   ├── models.json            # model pair, source, and rotation reused by /continue
│   ├── stream-gen.log         # append-only live stream of every generator attempt (retries included)
│   ├── stream-crit.log        # same for the critic; the tail panes follow these
│   ├── round-1-gen.md
│   ├── round-2-crit.md
│   └── round-3-gen.md
├── gen-<TS>.log
└── crit-<TS>.log
```

`<team>` is the tmux window's `@team-name` option (default: `debate-conductor`), so multiple windows in the same workspace produce isolated log streams.

Override the log location with `DEBATE_LOG_DIR=/path/to/logs`.

Role logs and round transcripts contain the answer, not the CLI's diagnostic
console output. Adapters declaring `final_args` (including Codex) publish their
native final answer only after successful completion. The pane shows the
attempt header while it waits. Missing or whitespace-only final answers fail
with rc=5; console text is never used as a fallback. Adapters without
`final_args` continue streaming stdout and must emit answer text only on that
channel. Their stderr is excluded. Role-wrapper capture/logging failures use rc=6 unless
the model itself already failed, in which case its exit code takes precedence.
The existing reserved stream framing byte is still removed from answers.

Raw CLI diagnostics are discarded by default, on both success and failure.
This is an intentional privacy tradeoff: a transient provider error cannot be
recovered afterward unless debugging was enabled for that invocation.
For a debugging invocation, set
`DEBATE_RAW_LOG=1` to keep `gen-<TS>.raw.log` / `crit-<TS>.raw.log` alongside the
ordinary role logs, with permissions 0600. For stdout-only adapters they also
contain a copy of the answer. These files can contain tool output
and unrelated file contents; they never feed the debate panes, verdict parser,
or subsequent prompts. This switch also works with the standalone role
wrappers. Historical logs are not rewritten: continuing an older debate can
still reuse contaminated text already present in its round files.

**Live panes follow per-role streams.** `debate.sh` appends every attempt of a role (a failed attempt, its retry, rounds added by `/continue`) to `stream-<role>.log`, which is never truncated or replaced. Each attempt ends with a record of its exit status, and the pane prints "attempt failed (rc=N)" after a failed one. The header and end record of an attempt carry the same attempt id, so a retry of the same round and model is told apart. A pane started with debate-conductor 0.5.9 or earlier skips these records (no round banners, no "attempt failed" lines). Each pane runs one `tail` on its role's stream from the start, including a pane opened late, displaying each stream in order without replay until another debate is selected. A debate without stream files can still be read through its round transcripts; continuation requires the ledger described below. The round files remain the transcript of record.

**Panes report missed selections.** Starting in 0.5.20, the pane polls `latest-debate.json` about once a second. The snapshot pairs a monotonically increasing team-wide `sequence` with the physical `debate_dir` (`v: 1`). Selecting a different debate advances the sequence; continuing the current debate does not. A single switch stops the old follower before printing "new debate run detected" and follows the selected stream from its beginning. If the sequence advances by D > 1, the pane prints "missed D−1 intermediate debate selections" and follows only the latest selection. This counts selections, including repeat visits, not distinct debate directories. On A → B → A between polls it reports one missed intermediate selection and keeps A's existing follower, offset, and pause state, without replaying A. The same-stream notice briefly suspends output on a best-effort basis; a line already being printed may overlap it. The notice describes switches missed between observations; output already displayed before detection is not retracted.

Restart open panes after upgrading. A new pane starts at the current sequence without reporting historical gaps. Logs with no selection snapshot still use the legacy symlink polling behavior, which cannot detect A → B → A; gap detection starts once the pane has observed a snapshot from the new publisher. Once a snapshot exists it is authoritative for panes: manually retargeting `latest-debate`, or running an older publisher, does not publish a selection. Use the upgraded `debate.sh` (including `--continue-from`) to select a debate. A missing selected directory does not invalidate the snapshot: panes wait for it or another selection, and new debates can still be published. If jq cannot run, panes report that dependency failure and retry polling. Corrupt or unreadable state stops the follower with a repair/restart message, even before its first valid snapshot. Missing or backwards state does so once a snapshot has been observed. These faults never claim an exact missed count.

Publication uses a separate, brief team lock with a five-second wait limit; it does not serialize the debates themselves. Streams and preflight must be ready before publication. The snapshot uses ordinary file permissions (0666 masked by the publisher’s umask). The JSON rename commits the selection; the compatibility symlink is updated just before it. A failed publication prevents model dispatch and rolls the link back. A new, unselected allocation is removed when it contains only its empty streams and ledger; continued debates and directories still selected after a commit or rollback failure are retained. A signal after the commit retains the committed selection. A hard kill can leave `.latest-debate.lock` behind: confirm the owner and all its children have stopped, remove that lock as the error message directs, and retry with the upgraded producer. Do not delete/reset `latest-debate.json` to clear a lock. A stale lock is never reclaimed automatically. A hard kill can also leave `.latest-debate.json.*` temporary snapshots. After confirming the lock owner and all its children have stopped, remove those temporary files during recovery. A failed symlink rollback retains the lock for manual recovery and attempts to remove its own temporary snapshot; a cleanup failure reports the remaining path.

## Skills

| Skill | What it does |
| :--- | :--- |
| `/debate-conductor:bootstrap` | One-time per session: splits the current tmux pane into 3 and starts role tails. |
| `/debate-conductor:run [N] [rounds]` | Resolves topic N, runs `debate.sh`, summarises verdict + moves. |
| `/debate-conductor:continue [extra-rounds]` | Append N more rounds (default 2) to the most recent debate in the same `debate-<TS>/`. Round numbering continues; the saved model pair and rotation are reused unless explicitly overridden; tail panes show every attempt, retries included, from the per-role streams. A debate whose round 1 failed restarts at round 1 with its saved context. |
| `/debate-conductor:install-pm` | Writes/upgrades the PM orchestration policy in the workspace's `CLAUDE.md` from Claude or `AGENTS.md` from Codex (idempotent, marker-guarded). Tells the PM when to dispatch a debate vs answer directly. |

Claude skills have `disable-model-invocation: true`; Codex skill metadata sets
`allow_implicit_invocation: false`. Invoke the skills explicitly.

Example:

```
/debate-conductor:run "여름 vs 겨울" 3   # rounds 1·2·3
/debate-conductor:continue 2             # rounds 4·5 appended to same dir
```

## Architecture

```
debate-conductor/
├── .claude-plugin/plugin.json
├── .codex-plugin/plugin.json
├── claude-skills/
│   ├── bootstrap/SKILL.md
│   ├── run/SKILL.md
│   ├── continue/SKILL.md
│   └── install-pm/SKILL.md
├── codex-skills/
│   ├── bootstrap/SKILL.md
│   ├── run/SKILL.md
│   ├── continue/SKILL.md
│   └── install-pm/SKILL.md
├── bin/                       # on PATH while plugin is active
│   ├── debate.sh              # round orchestrator (skill calls this)
│   ├── agent-team-models.sh   # shared model-registry CLI (vendored)
│   ├── debate-conductor-doctor.sh  # layout probe + --until-converged stub smoke
│   ├── team-3pane.sh          # tmux 3-pane splitter (--here mode)
│   └── tail-role.sh           # live-tail one role's stream (stream-<role>.log)
├── lib/                       # internal — invoked by debate.sh / install-pm
│   ├── ask-generator.sh       # Generator wrapper (any registered model)
│   ├── ask-critic.sh          # Critic wrapper (any registered model)
│   ├── answer.sh              # answer capture, validation, and opt-in diagnostics
│   ├── registry.sh            # shared model registry + runner (vendored)
│   ├── host.sh                # Claude/Codex PM defaults and CLI checks
│   ├── namespace.sh           # shared team namespace resolution
│   ├── index.sh               # attempt-ledger and completion queries
│   ├── debate-result.sh       # per-invocation receipt writer and reader
│   ├── selection.sh           # atomic team selection snapshots and sequence
│   ├── pm.md                  # Claude PM orchestration policy
│   ├── pm-codex.md            # Codex PM orchestration policy
│   └── roles/
│       ├── generator.md       # Generator role prompt
│       └── critic.md          # Critic role prompt
└── topics/                    # default topic examples
```

**A caller gets a receipt, not a symlink.** `latest-debate` is a convenience for viewing a debate and for choosing one to continue — it is team-wide, so it is never proof of what a particular invocation produced: any debate started by anyone else in the same team retargets it. A program that runs `debate.sh` and needs to know what *that run* wrote passes `DEBATE_RECEIPT=/abs/path` (fresh per dispatch, absolute — a relative path is refused with exit 2). On success, and only on success, `debate.sh` writes that path atomically while it still holds the writer lock:

```json
{"schema_version":1,"debate_dir":"/abs/…/debate-20260918-120000",
 "last_round":4,"critic_round":4,"critic_file":"round-4-crit-codex.md"}
```

`last_round` and `critic_round` are the highest **completed** rounds, from the ledger; `critic_file` names that round's transcript, in whichever form the debate used (`round-4-crit.md` or the rotated `round-4-crit-codex.md`). Both critic fields are null together when no critic round has completed. The fields describe the **whole debate**, not one dispatch: a `/continue` that adds a generator round still reports the critic round an earlier dispatch completed. `lib/debate-result.sh` holds the schema, the writer and the reader a caller should use — `debate.sh` validates its own receipt through that reader before publishing it. A caller must still check the exit code: a signal arriving after publication can leave a receipt behind for a run that then failed.

**Every attempt is in the ledger.** `debate-<TS>/index.jsonl` is an append-only record of the debate, one JSON object per line, written only by `debate.sh` under the writer lock. An attempt opens with a `start` record and closes with an `end` record carrying its exit status:

```
{"v":1,"t":"start","id":"4242.1789473600.1","round":1,"role":"gen","model":"agy","file":"round-1-gen.md","ts":"…"}
{"v":1,"t":"end","id":"4242.1789473600.1","round":1,"role":"gen","file":"round-1-gen.md","rc":0,"ts":"…"}
```

`id` is the same attempt id the role stream frames carry, so a row locates its own bytes in `stream-<role>.log` — including the bytes of an attempt that failed and was retried, which the round file no longer holds. A round counts as completed when the ledger holds an `end` record for it with `rc` 0; that is what `/continue` resumes from and what the doctor checks.

Read it the way `debate.sh` does. **Duplicate records are harmless and must stay harmless** — every query is a maximum or an existence test, never a count and never "the last end record". **A `start` with no `end` is an incomplete attempt**, whose round runs again; a run that was killed outright leaves exactly that. **A line that does not parse is skipped, not fatal** (`fromjson? // empty` in jq): a crash mid-append can leave a torn final line, and the next run re-establishes the line boundary before writing so the fragment cannot swallow the record after it. Nothing but `debate.sh` should ever write to this file, and a record claiming a round the debate never ran would move the resume point — the writer lock, not validation, is what keeps that from happening.

**Ledger-only completion (0.5.19).** New runs no longer create `.done` sidecars. Continuation requires a readable ledger and refuses with exit **2** if any legacy sidecar records a completed round/role absent from that ledger. This includes mixed histories with old sidecar-only rounds and newer indexed rounds. The refusal leaves the debate intact: start a fresh debate; there is no migration. Fully indexed debates from the previous release can continue, and their existing sidecars are left untouched. Continuation also refuses with exit **2** if any transcript beyond the next retry round contains output: the ledger cannot certify that history, even if the requested continuation would stop before it. Empty or start-only ledgers can retry an incomplete first round only when later rounds contain no output.

## Design notes

**Context scope per round.** Each round prompt only includes the *immediately preceding* generator+critic pair — not the full transcript. So round 5 sees round 3 (your last draft) and round 4 (critic feedback), but not rounds 1–2. This keeps prompts bounded as round count grows; the trade-off is that early-round consensus or discoveries fade out unless re-stated. `/continue` follows the same rule.

**A round needs a substantive answer.** `ask-generator.sh` and `ask-critic.sh` exit **5** when the CLI exits 0 but its native final-answer file is absent or whitespace-only, or a stdout-only adapter emits nothing except whitespace. They exit **6** for capture/logging failures, including an invalid or unreadable native final file, capture-directory creation failure, or failed `tee`/answer checks. A nonzero CLI exit takes precedence. `debate.sh` stops before marking either failure complete; the ledger retains the failed attempt's status. Native adapters never fall back to console output.

**Stopping a debate.** A signal to the process group (Ctrl-C, a supervisor's `killpg`) reaches every process of the running round, SIGKILL included. INT, TERM or HUP sent to the `debate.sh` PID alone also stops the round at once: `debate.sh` sends TERM to the round's process tree, waits up to about 2 s for it to exit, then records the status (130 / 143 / 129) and dies from the same signal. Signalling the PID is best effort: a process that ignores TERM keeps running, and without `ps` on `PATH` `debate.sh` waits for the round to finish instead. After the round pipeline succeeds, `debate.sh` freezes its attempt status at zero, then writes the ledger end before the diagnostic stream end. Only a successful ledger end makes the round complete for continuation. A trapped signal before status selection records 130 / 143 / 129; after selection it retains the frozen status in both records, while the process still dies from the signal. SIGKILL before a valid successful ledger end leaves an incomplete round that runs again; SIGKILL after that end preserves completion even if the stream end is missing. A failed ledger start stops before the model runs; a failed ledger end stops before another round or success receipt, preserving the transcript. These recording failures exit **1** on the normal path; an existing model failure or signal keeps its own exit status. Diagnostic stream ends remain best effort, and recording failures do not prevent lock cleanup.

**One writer per debate.** A debate directory has exactly one writer at a time. `debate.sh` takes an exclusive lock — `debate-<TS>/.lock`, a symlink whose target names the holding host and pid — before it reads which rounds are complete, and releases it when the run ends, including on Ctrl-C, TERM and HUP. The lock and the name of its holder are published in one atomic step (`ln -s`), so an interrupted run leaves either no lock or an identifiable one. A second run on the same debate (a `/continue` started while another one is going) is refused with exit 2 and a message naming the holder, rather than picking the same next round and overwriting its round files. Two debates started in the *same second* no longer share a directory either: the second one gets `debate-<TS>-1`, and `latest-debate` visibly retargets so the panes show the new debate.

There is no automatic recovery of a lock left behind, deliberately: a dead pid does not prove the writing stopped. A `kill -9` aimed at `debate.sh` alone leaves the round's model CLI, the `sed` filter and the `tee` processes running — still writing the round file and the stream — so reclaiming the debate on the strength of a missing pid would interleave two writers. Clearing such a lock is a manual step: the refusal prints the exact `rm -rf -- .../.lock`, to run once you have confirmed that nothing from that run — `debate.sh` and every process it started — is still writing in that directory.

**Live streaming quality depends on the adapter.** Native final-capture adapters publish only after successful completion. For stdout-only adapters, the stream-control filter removes the reserved RS byte and runs unbuffered (`sed -u` where supported, otherwise `stdbuf -oL sed`, otherwise plain `sed`). `tee` does not buffer, so answers can reach the round file and role stream line by line. A CLI that batches stdout can still delay display.

**Convergence parsing is anchored, not fuzzy.** `--until-converged` only stops on a *standalone canonical* `Verdict: STRENGTHEN` line (the Critic role contract), taking the last such line in the round. A Critic round that errors out and echoes its role prompt contains the placeholders `Verdict: <STRENGTHEN | …>` and `<one of: STRENGTHEN / …>` — neither matches the anchor, so a failed round reads as not-converged and the debate keeps going rather than stopping on garbage. `debate-conductor-doctor.sh` covers all three paths (STRENGTHEN / RECONSIDER / placeholder) with stub CLIs.

## License

[MIT](../LICENSE).
