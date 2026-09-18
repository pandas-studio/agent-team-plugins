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

**Live panes follow per-role streams.** `debate.sh` appends every attempt of a role (a failed attempt, its retry, rounds added by `/continue`) to `stream-<role>.log`, which is never truncated or replaced. Each attempt ends with a record of its exit status, and the pane prints "attempt failed (rc=N)" after a failed one. The header and end record of an attempt carry the same attempt id, so a retry of the same round and model is told apart. A pane started with debate-conductor 0.5.9 or earlier skips these records (no round banners, no "attempt failed" lines): restart open panes after upgrading. Each pane runs one `tail` on its role's stream from the start, so it shows the whole debate once, in order, including a pane opened late. A new debate retargets `latest-debate`; the pane stops following the old stream before it prints "new debate run detected". A debate created before streams existed has no stream files: its pane says so, and shows only the rounds added by a later `/continue`. The round files remain the transcript of record.

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
│   ├── registry.sh            # shared model registry + runner (vendored)
│   ├── host.sh                # Claude/Codex PM defaults and CLI checks
│   ├── pm.md                  # Claude PM orchestration policy
│   ├── pm-codex.md            # Codex PM orchestration policy
│   └── roles/
│       ├── generator.md       # Generator role prompt
│       └── critic.md          # Critic role prompt
└── topics/                    # default topic examples
```

**Every attempt is in the ledger.** `debate-<TS>/index.jsonl` is an append-only record of the debate, one JSON object per line, written only by `debate.sh` under the writer lock. An attempt opens with a `start` record and closes with an `end` record carrying its exit status:

```
{"v":1,"t":"start","id":"4242.1789473600.1","round":1,"role":"gen","model":"agy","file":"round-1-gen.md","ts":"…"}
{"v":1,"t":"end","id":"4242.1789473600.1","round":1,"role":"gen","file":"round-1-gen.md","rc":0,"ts":"…"}
```

`id` is the same attempt id the role stream frames carry, so a row locates its own bytes in `stream-<role>.log` — including the bytes of an attempt that failed and was retried, which the round file no longer holds. A round counts as completed when the ledger holds an `end` record for it with `rc` 0; that is what `/continue` resumes from and what the doctor checks.

Read it the way `debate.sh` does. **Duplicate records are harmless and must stay harmless** — every query is a maximum or an existence test, never a count and never "the last end record". **A `start` with no `end` is an incomplete attempt**, whose round runs again; a run that was killed outright leaves exactly that. **A line that does not parse is skipped, not fatal** (`fromjson? // empty` in jq): a crash mid-append can leave a torn final line, and the next run re-establishes the line boundary before writing so the fragment cannot swallow the record after it. Nothing but `debate.sh` should ever write to this file, and a record claiming a round the debate never ran would move the resume point — the writer lock, not validation, is what keeps that from happening.

For one more release `debate.sh` also touches the older `.round-<N>-<role>[-model].done` sidecars, and completion is read as the union of the two, so a debate created before the ledger keeps resuming correctly. The sidecars are derived; nothing reads them that does not also read the ledger.

## Design notes

**Context scope per round.** Each round prompt only includes the *immediately preceding* generator+critic pair — not the full transcript. So round 5 sees round 3 (your last draft) and round 4 (critic feedback), but not rounds 1–2. This keeps prompts bounded as round count grows; the trade-off is that early-round consensus or discoveries fade out unless re-stated. `/continue` follows the same rule.

**A round needs an answer on stdout.** `ask-generator.sh` and `ask-critic.sh` exit **5** when the model CLI exits 0 but writes nothing except whitespace to stdout. For example, `agy -p` soft-denies a tool it cannot prompt for, prints guidance on stderr, and still exits 0. They exit **6** when the answer cannot be checked: the temp file cannot be created (the model is not run), or the model exits 0 but `tee` or the check fails. `debate.sh` stops on either code before recording the round as completed, so the guidance never becomes a draft or a critique. The failed attempt is still in the ledger, with its exit status.

**Stopping a debate.** A signal to the process group (Ctrl-C, a supervisor's `killpg`) reaches every process of the running round, SIGKILL included. INT, TERM or HUP sent to the `debate.sh` PID alone also stops the round at once: `debate.sh` sends TERM to the round's process tree, waits up to about 2 s for it to exit, then records the status (130 / 143 / 129) and dies from the same signal. Signalling the PID is best effort: a process that ignores TERM keeps running, and without `ps` on `PATH` `debate.sh` waits for the round to finish instead. A round ends when `debate.sh` marks it complete, and the `.done` sidecar is written first, before either end record: once it exists the round counts as complete and both end records say `rc=0` whatever happens next. A round interrupted before that point never gets a sidecar, even if its output was complete, so `/continue` runs it again — a trapped INT, TERM or HUP records the attempt with the signal's status (130 / 143 / 129), and a `kill -9` records nothing at all and leaves a `start` with no `end`. A run killed between the sidecar and the ledger write leaves the round complete in the sidecar alone, which is one of the reasons completion is read as the union of the two.

**One writer per debate.** A debate directory has exactly one writer at a time. `debate.sh` takes an exclusive lock — `debate-<TS>/.lock`, a symlink whose target names the holding host and pid — before it reads which rounds are complete, and releases it when the run ends, including on Ctrl-C, TERM and HUP. The lock and the name of its holder are published in one atomic step (`ln -s`), so an interrupted run leaves either no lock or an identifiable one. A second run on the same debate (a `/continue` started while another one is going) is refused with exit 2 and a message naming the holder, rather than picking the same next round and overwriting its round files. Two debates started in the *same second* no longer share a directory either: the second one gets `debate-<TS>-1`, and `latest-debate` visibly retargets so the panes show the new debate.

There is no automatic recovery of a lock left behind, deliberately: a dead pid does not prove the writing stopped. A `kill -9` aimed at `debate.sh` alone leaves the round's model CLI, the `sed` filter and the `tee` processes running — still writing the round file and the stream — so reclaiming the debate on the strength of a missing pid would interleave two writers. Clearing such a lock is a manual step: the refusal prints the exact `rm -rf -- .../.lock`, to run once you have confirmed that nothing from that run — `debate.sh` and every process it started — is still writing in that directory.

**Live streaming quality depends on the model CLI.** The cleaning filter runs unbuffered (`sed -u` where supported, otherwise `stdbuf -oL sed`, otherwise plain `sed`), and `tee` does not buffer, so cleaned output reaches the round file and the role stream line by line. But if the model CLI itself batches its stdout in user-space (some `codex` builds do this), a round may still appear in one chunk rather than streaming. That's outside this plugin's reach.

**Convergence parsing is anchored, not fuzzy.** `--until-converged` only stops on a *standalone canonical* `Verdict: STRENGTHEN` line (the Critic role contract), taking the last such line in the round. A Critic round that errors out and echoes its role prompt contains the placeholders `Verdict: <STRENGTHEN | …>` and `<one of: STRENGTHEN / …>` — neither matches the anchor, so a failed round reads as not-converged and the debate keeps going rather than stopping on garbage. `debate-conductor-doctor.sh` covers all three paths (STRENGTHEN / RECONSIDER / placeholder) with stub CLIs.

## License

[MIT](../LICENSE).
