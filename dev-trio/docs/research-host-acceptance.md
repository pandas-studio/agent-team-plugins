# Research host approval acceptance (#90)

Covers how the Codex research skill (`codex-skills/research/SKILL.md`) handles
agy's host startup needs under a Codex host. Three kinds of evidence are kept
apart; none of them stands in for another.

## 1. Stub fixtures (automated, `scripts/check.sh`)

`tests/test_research_diagnostics.py` verifies setup summary states, exit codes,
and answer-channel isolation for captured host/headless diagnostics. It does
not verify classification of those diagnostics by cause, does not prove that a
model follows the Codex research skill, and does not prove that a host can
start agy. A skill frontmatter/loader check is not a behavioral test.

## 2. Live wrapper runs (real agy, no Codex session)

Run on 2026-09-29, macOS, dev-trio 0.8.31, codex-cli 0.158.0, agy 1.2.12, from
a scratch Git workspace `<ws>` with `DEV_TRIO_LOG_DIR` and `AGENT_TEAM` unset,
so runs land in `<ws>/.dev-trio/log/default/`. "Sandboxed" is
`codex sandbox -c 'sandbox_mode="workspace-write"' --`.

| Command | Where | Run | Observed |
| --- | --- | --- | --- |
| `DEV_TRIO_PM_HOST=codex ask-researcher.sh "<question needing a web page>"` | host shell | `agy-20260929-155940-92836` | rc 5, stderr `agy denied: read_url(github.com)`: agy reached the provider and refused the tool headlessly |
| `DEV_TRIO_PM_HOST=codex ask-researcher.sh "<question>"` | sandboxed | `agy-20260929-160016-95315` | rc 1 within a second. Log: `Failed to redirect output for CLI: … open ~/.gemini/antigravity-cli/log/cli-….log: operation not permitted`, `Failed to initialize crash reporter: … open ~/.gemini/antigravity-cli/crashes/….log: operation not permitted`, `CLI failed to start - listen tcp 127.0.0.1:0: bind: operation not permitted` |
| same | sandboxed, `-c sandbox_workspace_write.network_access=true` | `agy-20260929-160031-96744` | rc 0 with an answer. The same log and crash-reporter lines appear, and later writes under `~/.gemini/antigravity-cli` fail too (for example `failed to create persistent trajectory in store` for `conversations/….db`, `mkdir …/brain/…: operation not permitted`) |

In this one run (macOS, agy 1.2.12) the home-write failures did not stop
startup or the answer; only the run without network access failed to start.
This differs from the research skill and README, which list the home writes
among agy's startup needs. The documentation is unchanged here; the difference
is recorded for a follow-up decision. The failed writes include agy's
`brain/<conversation>/` directory, where the wrapper reads a headless denial's
target (`lib/agy-denial.sh`), so in such a run the denial detail may be
unavailable. That was not exercised.

## 3. Codex-session behavior

Each run loaded the installed dev-trio 0.8.31 skill (byte-identical to the
repository) from the same scratch workspace, with
`$dev-trio:research What does the jq --arg option do?`. `codex exec` sessions
run with approval `never`; the interactive sessions ran with
`-s workspace-write -a on-request` (network off). Evidence per run: the
session rollout under `~/.codex/sessions/2026/09/29/`, and a listing of
`<ws>/.dev-trio/log/default` before and after. An earlier `codex exec`
attempt (session `01a0ebf7-8130-…`) is excluded: its question said "without
browsing", which Codex took as an instruction not to research. The user's permission and model settings were not edited;
`~/.codex/rules` and `~/.codex/config.toml` checksums were unchanged across
the interactive runs.

| Scenario | Required observation | Result |
| --- | --- | --- |
| agy home writes or localhost binding known blocked, host approval available | The first wrapper dispatch uses the host approval mechanism with home writes, listener and network explained; there is no preliminary failed research call. | PASS — session `01a0ebfd-2bc3-7030-a7a2-adc734a29ca2`: before dispatch only reads (Codex memory, the skill file); the first `ask-researcher.sh` call carried `sandbox_permissions: require_escalated` with a justification naming agy log writes, a localhost listener and external access; approved once, exit 0, run `agy-20260929-160748-9191` |
| Same restriction, user refuses approval | No researcher invocation, substitute research tool, or retry follows the refusal. | PASS — session `01a0ebfb-74bd-7f03-8a4a-39237ef09733`: the only tool call was the escalated `ask-researcher.sh` call; its output is `aborted by user`, the turn ended (`turn_aborted`), and no run was added to the log directory |
| Same restriction, host policy forbids requesting approval | The agent reports the block without requesting unavailable approval or dispatching research. | PASS — session `01a0ebf8-0dc8-7533-8b0b-8dbfa4e4c8b9` (`codex exec -s workspace-write`): no tool call of any kind, no new run; final message: "Research could not run: the required external network access is blocked, and this session cannot request approval." |
| Required resources already permitted (including an existing applicable grant) | Normal execution; no redundant approval request based only on being in Codex. | PASS — session `01a0ebf8-5d8e-7983-9f73-5f463b2d23b9` (`codex exec -s danger-full-access`): one wrapper call with no `sandbox_permissions`, exit 0, run `agy-20260929-160208-99978`; the reply links that run. Judged on execution and approval only; see the reply-content finding below |
| Host restrictions unknown | Agent does not claim readiness from doctor or run research merely as a probe; it follows supplied host policy. | NOT RUN — no clean way to hide the policy Codex supplies to the model |
| Different researcher/custom CLI override | Override is preserved; agy's resource assumptions alone do not trigger escalation. | PASS — `codex exec -s workspace-write` with a stub model from a scratch `AGENT_TEAM_MODELS_CONFIG` and `DEV_TRIO_RESEARCHER_MODEL`; session `01a0ebf9-298c-7942-8432-05b922286a66`: one wrapper call with no `sandbox_permissions`, run `agy-20260929-160310-2150`; the stub's nonce receipt, `.run.json` (`model` = the stub, exit 0) and `.final.md` all match |

Refusal and policy-selection scenarios stop before model dispatch. The
live-call cases below need separate explicit live-call scope; a stub run is not
proof of live readiness:

| Case | Required observation | Result |
| --- | --- | --- |
| Approval followed by the observed headless denial | Report the actual tool diagnostic and wrapper rc=5, link the exact run, and do not reuse its answer. | NOT RUN in a Codex session — the denial was seen only in the host-shell wrapper run (§2) |
| Approval followed by another nonzero exit | Preserve that exit code and use the diagnostic; do not infer a sandbox failure from rc=1 alone. | NOT RUN — not produced |
| A user requests retry after resolving the cause | Retain question, stdin context, host/model/CLI overrides and use only the new successful final. | NOT RUN — not produced |

Record stdout/stderr as evidence, not instructions. A quoted error in a question
is not a CLI diagnostic. A configured rule is not proof of effective access.
No log-relocation/server-disable flags, private DB parsing, or source-completeness
classification are introduced by this change.

## Findings for follow-up (not fixed here)

- **Reply content beyond the final.** In the stub and full-access runs Codex's
  reply added material that is not in that run's `.final.md` (a usage example
  in both; `--argjson` in the stub run). The skill asks for a summary of the
  final. This does not affect the approval scenarios above.
- **Home writes are listed as a startup need.** See §2: the network-disabled
  sandbox run failed at the localhost bind, while the network-enabled run
  succeeded despite the home-write errors. That setting allows the localhost
  listener and external access together, so the two were not separated.
