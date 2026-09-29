# Research host approval acceptance (#90, #190)

Covers how the Codex research skill (`codex-skills/research/SKILL.md`) handles
agy's host resource needs under a Codex host, and how it reports a successful
run. Three kinds of evidence are kept apart; none of them stands in for another.
The #90 runs used dev-trio 0.8.31 and agy 1.2.12; the #190 additions used
dev-trio 0.8.32 wrappers, agy 1.2.13 and the 0.8.33 research skill.

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

Re-measured for #190 on 2026-09-29 with agy 1.2.13 (codex-cli 0.158.0, the
0.8.32 wrapper at `b3db2e3`), same setup, question "In one sentence, what does
the POSIX cat utility do?":

| Command | Where | Run | Observed |
| --- | --- | --- | --- |
| `DEV_TRIO_PM_HOST=codex ask-researcher.sh "<question>"` | sandboxed | `agy-20260929-182921-48400` | rc 1 in 1.6 s, no answer. The same three log lines as the 1.2.12 run: log redirect and crash reporter `operation not permitted` under `~/.gemini/antigravity-cli`, then `CLI failed to start - listen tcp 127.0.0.1:0: bind: operation not permitted` |
| same | sandboxed, `-c sandbox_workspace_write.network_access=true` | `agy-20260929-182937-49550` | rc 0 in 15 s with an answer (`.run.json` exit 0). `operation not permitted` lines under agy home: 12 `conversations`, 6 `brain`, 2 each `cache`, `mcp`, `jetbox_summaries_proto`, 1 each `log`, `crashes`, `annotations`, `implicit`, `presence`. No `CLI failed to start` line. No pinned `log/cli-dev-trio-research-20260929-182937.log` was created, and conversation `9b7eabec-…` has no `brain/` directory |

With only the home writes blocked, agy's own log went to its stderr, which is
the wrapper's transcript: that `.log` is 39,837 bytes, and all 41 entries of
the user's `permissions.allow` appear in it verbatim (counted, not printed).
Line counts in that transcript, also without printing the lines: 1 with
`command(`, 0 with `read_url(`, 3 with `permissions`.
The unsandboxed #90 run of the jq question (`agy-20260929-160208-99978`) has
a 1,422-byte transcript containing none of them.

**Decision (#190).** Both versions show the same split: without the sandbox's
network grant agy fails at the localhost bind before answering, and with it
the blocked home writes are not fatal. That grant enables the listener and
external access together, so neither is shown to be needed on its own. The
skill and README therefore no longer call the home writes a startup need. They
still list them as required, because without them agy keeps no records, its
log and allow list land in the wrapper's transcript, and a headless denial
cannot be named. The last point is not exercised: no denial was produced in a
sandboxed run. It follows from the code path. `dev_trio_agy_cli_log`
(`lib/host.sh`) cannot create the pinned log, so no `--log-file` is passed, and
`research_agy_denials` (`bin/ask-researcher.sh`) then returns nothing. The
`brain/` transcript that `lib/agy-denial.sh` reads is not written either.

## 3. Codex-session behavior

Each #90 run loaded the installed dev-trio 0.8.31 skill (checked with `cmp`
against `origin/main` at `0b710d6`: `codex-skills/research/SKILL.md`,
`bin/ask-researcher.sh`, `lib/registry.sh` and `lib/agy-denial.sh` are identical) from the same scratch workspace, with
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
| Required resources already permitted (including an existing applicable grant) | Normal execution; no redundant approval request based only on being in Codex. | PASS — session `01a0ebf8-5d8e-7983-9f73-5f463b2d23b9` (`codex exec -s danger-full-access`): one wrapper call with no `sandbox_permissions`, exit 0, run `agy-20260929-160208-99978`; the reply links that run. Judged on execution and approval only; reply content is covered by the reply fidelity row and method below |
| Host restrictions unknown | Agent does not claim readiness from doctor or run research merely as a probe; it follows supplied host policy. | NOT RUN — no clean way to hide the policy Codex supplies to the model |
| Different researcher/custom CLI override | Override is preserved; agy's resource assumptions alone do not trigger escalation. | PASS — `codex exec -s workspace-write` with a stub model from a scratch `AGENT_TEAM_MODELS_CONFIG` and `DEV_TRIO_RESEARCHER_MODEL`; session `01a0ebf9-298c-7942-8432-05b922286a66`: one wrapper call with no `sandbox_permissions`, run `agy-20260929-160310-2150`; the stub's nonce receipt, `.run.json` (`model` = the stub, exit 0) and `.final.md` all match |
| Reply fidelity, custom stub researcher with a one-line final (#190) | The reply quotes the final's line verbatim, takes model, exit code and paths from this run's `.run.json`, and adds no topic content of its own. | 3 of 3 PASS with the 0.8.33 skill (sessions `01a0ecb1-c2af-…`, `01a0ecb2-a64f-…`, `01a0ecb3-63a0-…`). FAIL with the 0.8.31 skill (session `01a0ebf9-298c-…` above). Draft runs, including one that added a labeled `### My explanation` section, are in the method below |

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

### Reply fidelity method (#190)

Unlike the #90 runs above, the #190 runs did not load an installed skill. The
branch skill was not installed, so `$dev-trio:research` would have loaded the
cached one. The prompt instead reproduces the expansion seen in the #90
rollout, in this order:

1. The question: `What does the jq --arg option do?`
2. The #90 stub note: `(The researcher for this session is overridden:
   DEV_TRIO_RESEARCHER_MODEL=stubres from AGENT_TEAM_MODELS_CONFIG, already set
   in the environment. stubres is a local stub CLI that needs no network,
   home-directory writes or localhost listener.)`
3. `<skill>`, `<name>dev-trio:research</name>`, then a `<path>` to the
   worktree's `codex-skills/research/SKILL.md`.
4. That file's text, then `</skill>`.

The stub and the run:

```text
models config: {"version":1,"models":{"stubres":{"command":"<stub.sh>",
                "prompt_via":"stdin","args":["-p"]}},"roles":{}}
stub.sh:       writes nonce, argv, $DEV_TRIO_RESEARCHER_MODEL and stdin size to
               <ws>/stub-receipt.txt, then prints
               "STUB ANSWER <nonce>: jq --arg binds a named string variable."
command:       env -u DEV_TRIO_LOG_DIR -u AGENT_TEAM \
                 AGENT_TEAM_MODELS_CONFIG=<models config> \
                 DEV_TRIO_RESEARCHER_MODEL=stubres \
                 codex exec -s workspace-write --json -o <last.md> - < <prompt>
```

The #190 runs all used the nonce `n190-1790674254`; the 0.8.31 baseline
session `01a0ebf9-298c` used `n90-1790665360`. Each run's skill text is
identified by the SHA-256 of the worktree file when the run started. The 0.8.33
text is `e65f0da38dbd4866a0ae30c042b7eea362e1279e0d25e77e99704c280f9748f1`. In
every run the only wrapper call had no `sandbox_permissions`, and the receipt
nonce and the `.run.json` model (`stubres`, exit 0) match.

A script read the last assistant message from each rollout and checked it
against that run's `.run.json` and `.final.md`:

1. The final's line appears verbatim.
2. `.model`, `.completion.exit_code`, `.final_path` and `.log_path` appear, and
   the reply says there are zero sources.
3. It lowercases the reply and removes the final's line and the two paths. It
   then removes these whole words: `lead paragraph`, `sources cited`,
   `exit code`, `researcher`, `stubres`, `final answer`, `final`, `model`,
   `urls`, `url`, `log`, `run`. Last, it turns digits and punctuation into
   spaces and prints what remains. The reply must have no fenced block, and the
   remainder no `jq`, `arg`, `argjson`, `string`, `variable` or `bind` word. A
   person then reads the remainder, because a paraphrase can avoid every
   listed word.

| Session | Skill text | Run | Verbatim | Metadata | Fence | Listed words in the remainder |
| --- | --- | --- | --- | --- | --- | --- |
| `01a0ebf9-298c` | 0.8.31 | `agy-20260929-160310-2150` | no | yes | yes | `jq`, `arg`, `argjson`, `string`, `variable` |
| `01a0ec80-d06c` | draft 1 (`a9e5f7a8…`) | `agy-20260929-183120-53275` | yes | yes | no | none |
| `01a0eca3-0ab0` | draft 2 (`27310288…`) | `agy-20260929-190844-45645` | yes | yes | no | none |
| `01a0eca7-19a8` | draft 3 (`7ff790f2…`) | `agy-20260929-191309-54041` | yes | yes | no | `jq`, `arg`, `string`, `variable` |
| `01a0eca8-3792` | draft 4 (`567393d6…`) | `agy-20260929-191417-58727` | yes | yes | yes | `jq`, `arg`, `argjson`, `string` |
| `01a0eca8-b666` | draft 4 | `agy-20260929-191451-60865` | yes | yes | no | none |
| `01a0eca9-7ce7` | draft 4 | `agy-20260929-191546-63954` | yes | yes | no | none |
| `01a0ecb1-c2af` | 0.8.33 (`e65f0da3…`) | `agy-20260929-192454-87930` | yes | yes | no | none |
| `01a0ecb2-a64f` | 0.8.33 | `agy-20260929-192545-90602` | yes | yes | no | none |
| `01a0ecb3-63a0` | 0.8.33 | `agy-20260929-192631-93865` | yes | yes | no | none |

Drafts 1 to 4 differ from 0.8.33 only in review fixes to the startup and
recovery wording, and in the sentence that opens the report. Draft 4 already
had the final report wording. 0.8.33 adds only the measured agy versions to the
startup paragraph. The draft 3 reply
opened with an unlabeled one-line paraphrase of the final. That is the
restatement the skill forbids, so the opening sentence was tightened to put
nothing about the research before the lead paragraph. The first draft 4 run
quoted the final and then added a jq example and `--argjson` under
`### My explanation`. The skill allows that as the PM's own analysis under its
own heading. The check does not know about that section, so it counts the
section's words as topic content.

The check script's zero-sources pattern first missed the form
`Sources cited: 0` used in the draft 2 reply. It was widened to accept that
form, and every row was checked again with the widened pattern. No other
change was made to the script after seeing a reply.

In the passing runs the remainder is only Codex's own memory-citation block
(`oai-mem-citation`, which cites a `MEMORY.md` note), with no topic content.
This shows the skill's wording steers a one-line final. It does not show the
behavior on a long real final, and only the person reading the remainder would
catch a new kind of addition.

## Follow-ups from #90 (resolved in #190)

- **Reply content beyond the final.** In the #90 stub and full-access runs,
  Codex's reply added material that is not in that run's `.final.md`, such as
  a usage example and `--argjson`. The skill now uses the Claude research
  skill's report contract. It quotes the lead paragraph verbatim, counts the
  cited URLs and takes the run metadata from `.run.json`. The PM's own analysis
  goes under a separate heading. The reply fidelity row in §3 records the
  runs: 3 of 3 passed with the final text. Of 3 runs with the same report
  wording in draft 4, 2 passed and 1 added its own content under that separate
  heading.
- **Home writes are listed as a startup need.** Re-measured with agy 1.2.13 in
  §2. The home writes are now described as needed for agy's records, the
  transcript's privacy and denial naming, not for startup. The approval rows
  above are unchanged: all three resources are still requested together.
