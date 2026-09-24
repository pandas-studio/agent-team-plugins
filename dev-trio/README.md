# dev-trio

Supports **Claude Code or Codex as PM**, using the same CLI adapters and run artifacts.

The original Claude host orchestrates a 3-vendor dev team: Claude (PM/Coder) + Antigravity (Researcher) + Codex (Reviewer). Live 3-pane tmux view; ad-hoc research and review skills; opt-in PM orchestration policy that installs into your workspace's `CLAUDE.md`.

Default model assignment:

| Pane | Role | CLI |
| :--- | :--- | :--- |
| Left | PM / Coder | Claude Code (this session) |
| Top-right | Researcher dashboard | tails `agy` output |
| Bottom-right | Reviewer dashboard | tails `codex` output |

## Codex PM

Codex acts as PM/coder, Antigravity researches, and Claude Code reviews by
default. Existing `DEV_TRIO_*_MODEL` overrides and shared `models.json` role
bindings take precedence. Claude must be installed and authenticated;
subscription, API, and provider selection remain under Claude Code's own
configuration. There is no subscription-only or API-key restriction.

Install from a local checkout containing this support:

```bash
codex plugin marketplace add /absolute/path/to/agent-team-plugins
codex plugin add dev-trio@pandas-studio
```

Start a new Codex session and invoke `$dev-trio:research`, `$dev-trio:review`,
`$dev-trio:bootstrap`, or `$dev-trio:install-pm`. The last skill optionally
installs persistent PM instructions into the current workspace's `AGENTS.md`;
it does not change `CLAUDE.md`. Installation of the plugin alone writes neither
project policy file. Both hosts keep the `dev-trio` namespace.

The scripts can also be called directly **from the workspace being reviewed**:

```bash
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/dev-trio-doctor.sh
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/dev-trio-doctor.sh --research
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/ask-researcher.sh "research question" </dev/null
DEV_TRIO_PM_HOST=codex /absolute/path/to/dev-trio/bin/ask-reviewer.sh "review focus" </dev/null
python3 /absolute/path/to/dev-trio/bin/install-pm.py --host codex
```

`DEV_TRIO_PM_HOST` accepts `claude` (default) or `codex` and applies only to that
invocation; it never rewrites shared role bindings. Codex resolves scripts from
the loaded skill path instead of assuming automatic `bin/` PATH registration.
When piping research context, replace `</dev/null` with that input pipe.

`ask-reviewer.sh` runs whichever model the **reviewer** role resolves to; the
filename names the role, not the CLI. Log and receipt names keep their legacy
spelling (`codex-*.log`, `latest-codex.final.md`), and RFC 0004 manifests remain
compatible with consumers. The run header and dashboard identify the actual
model. `--no-memories` still requires an explicitly selected Codex reviewer; it
is rejected for Claude.

Claude's `auth status --json` must report `loggedIn: true` before a Claude
invocation from the Codex host. In a sandbox that cannot access macOS Keychain,
this check may require the host's normal permission escalation. Failures are
reported before inference; the plugin does not modify credentials or retry
using a different provider. Explicit custom CLI adapters retain their own auth
behavior; a Claude adapter should use the `claude` model ID or `claude` binary
name if it needs the built-in login probe.

The four Codex skills preserve the explicit invocation policy. Persistent PM
routing is opt-in through `install-pm`; otherwise use the skills when requested.
Research/review do not require tmux. In the Codex app, bootstrap creates a
detached tmux layout outside tmux and prints an attach command for a terminal.

## Prerequisites

- `tmux` for optional dashboards (research/review work without it)
- `claude` (Claude Code)
- `agy` (Antigravity CLI) authenticated
- `codex` (OpenAI Codex CLI) authenticated
- Python 3.9+ for the policy installer and development tests
- `jq` (1.6+) — required for the model registry and RFC 0004 run manifests

Models and CLI binaries are configurable — see [Model configuration](#model-configuration). Quick binary overrides still work: `AGY_CLI` / `RESEARCHER_CLI` (researcher), `CODEX_CLI` / `REVIEWER_CLI` (reviewer).

Before the first research call, run `dev-trio-doctor.sh --research` from the
workspace (Codex users: use the absolute plugin path and host variable shown
above). This checks setup without authentication or model calls. Headless
research also requires permission for the tools used by the particular
question; installation and authentication alone do not prove that access.
See [Research troubleshooting](#research-troubleshooting).

## Model configuration

The Researcher and Reviewer roles resolve through the shared model registry (the [marketplace README](../README.md#shared-model-configuration) covers it in full). Defaults are `agy` (researcher) and `codex` (reviewer); Codex PM defaults the reviewer to Claude. No model binding configuration is needed for these defaults. Each CLI still needs its own installation, authentication and applicable headless tool permissions.

**Workspace-aware models (agy).** Headless agy is not told which directory it was started for, so left alone it guesses with `cd <repo> && git …` or `lsof -p $$ || pwd`, which no simple `command(...)` allow-rule matches. The built-in `agy` model therefore defines `workspace_args` (`--add-dir {cwd}`) and `log_args` (`--log-file {cli_log}`), and both wrappers, for any model that defines `workspace_args`:
- pass the repository root (`git rev-parse --show-toplevel`, else the working directory) as `--add-dir`;
- add an `# Execution environment` section to the prompt naming the root and the working directory, and asking for one simple read-only command per tool call — no `cd`, `&&`, `||`, `;`, pipes or redirections;
- pin agy's own per-run log to `<agy home>/log/cli-dev-trio-<review|research>-<TS>.log`, where agy keeps its other logs (it accumulates the same way). The wrapper creates that file itself (mode 0600, never an existing file) and passes it only if that worked: agy given a log path it cannot create writes its whole log, including your allow list, to stderr. The wrappers read the conversation id from it and never copy it.

`<agy home>` is `$DEV_TRIO_AGY_HOME`, default `~/.gemini/antigravity-cli`. A models-config entry that redefines `agy` without these fields turns all of this off; any model that defines `workspace_args` is treated as agy-compatible and gets the same note and diagnosis (the diagnosis only fires on agy's own no-output notice). The registry applies the fields only when a caller passes `REGISTRY_WORKSPACE` / `REGISTRY_CLI_LOG`; debate-conductor does not.

**Prompts on stdin (claude, codex).** The built-in `claude`, `claude-write`, `codex` and `codex-no-memories` models take the prompt on stdin (`"prompt_via": "stdin"`): `claude -p` and `codex exec … -` get no prompt argument. Linux refuses a single argument of 128 KiB or more, which a spec plus research context reaches. agy still takes the prompt as its last argument, so a researcher or reviewer prompt that large fails early with rc 3 and a message naming the size; see the [marketplace README](../README.md#shared-model-configuration).

If `REVIEWER_CLI`, `RESEARCHER_CLI` or `CODEX_CLI` / `CLAUDE_CLI` points at your own wrapper, it must now pass its stdin on to the CLI. `exec codex "$@"` already does. A wrapper that read the prompt from its last argument (`"${@: -1}"`, `$2`) gets `-` or nothing there and has to read stdin instead.

| Role | Default | Pick a different model | Override its binary |
| :--- | :--- | :--- | :--- |
| `dev-trio.researcher` | `agy` | `DEV_TRIO_RESEARCHER_MODEL` env, or `agent-team-models set-role dev-trio.researcher <model>` | `RESEARCHER_CLI` (any model) · `AGY_CLI` (the `agy` model) |
| `dev-trio.reviewer` | Claude PM: `codex`; Codex PM: `claude` | `DEV_TRIO_REVIEWER_MODEL` env, or `agent-team-models set-role dev-trio.reviewer <model>` | `REVIEWER_CLI` (any model) · `CODEX_CLI` (the `codex` model) |

```bash
agent-team-models preset add kimi-code
agent-team-models set-role dev-trio.reviewer kimi-code   # reviews now run through Kimi Code
agent-team-models doctor                                  # verify binding + binary
```

The reviewer's final structured review is written to `<TS>.final.md` natively when the model supports it (codex's `--output-last-message`), and otherwise synthesised from the streamed transcript — so `/dev-trio:review` verdict parsing works regardless of which model fills the role.

**Review results.** Each invocation writes an atomic `codex-<TS>-<PID>.review.json` beside its unchanged `.final.md` and raw `.log`. The wrapper prints all three exact paths. The dashboard and review skill consume this result; the standalone manifest stores its normalized verdict and a hashed `review-result` input reference. Use the reported paths for automation: `latest` links can move during another invocation.

The result contains `schema_version: 1`, `profile`, `status`, `invocation_rc`, `exit_code`, `error`, `verdict`, `verdict_line`, and `findings` (`blocker`, `major`, `minor` arrays). Missing findings sections are `null` (unknown); empty sections are empty arrays. A successful review accepts one unfenced `## Verdict` immediately followed by `TOKEN — reason` or `TOKEN. reason`, with `TOKEN` in `SHIP`, `NEEDS-FIX`, `DISCUSS`. Duplicate headings, unclosed/unsupported code fences, missing/empty native finals, and unknown verdicts fail parsing. Raw logs and earlier runs never supply a fallback verdict.

A parsed review exits **0**, including `NEEDS-FIX` or `DISCUSS`; inspect `verdict` to decide the next action. A parse failure after a successful invocation exits **3** (`status: "parse-failed"`). An invocation failure preserves its original nonzero exit code (`status: "invocation-failed"`). A headless agy run that auto-denied a tool and produced no review also exits **3**, with `status: "permission-denied"`, the targets agy recorded as denied in `denied` (`<kind>(<target>)`, e.g. `command(git rev-parse --show-toplevel)`, the shape of the rule it would take; agy 1.2.9 ignores `unsandboxed(...)` rules, see step 3 below; empty when agy recorded none) and agy's `conversation_ids`; see [Resolve a confirmed agy permission denial](#resolve-a-confirmed-agy-permission-denial). All failure statuses leave `verdict: null`. `error` explains the failure. The reviewer requests `- None.` for empty sections in every language; the parser also accepts `- none` (case-insensitive, optional period) and Korean `- 없음` / `- 없음.`, allowing trailing whitespace on these markers. Other short bullets remain findings, with their text and whitespace preserved.

An empty marker and finding bullets in the same severity are contradictory, in either order and even across repeated headings. This fails parsing with an error naming the severity; the verdict and all finding arrays become `null`, and the dashboard reports the failure without counts. Put resolved-finding explanations and positive evidence under `## What I checked`, outside the Findings sections. The final Markdown is preserved unchanged. A `SHIP` verdict alone never clears finding arrays.

The structured findings format uses `- ` bullets at column 0. List items with text, including `None.` empty markers, fail parsing if indented 1–3 spaces or written with `*`, `+`, numbered markers (`1.` / `1)`), or a tab instead of the space after `-`. This avoids silently dropping findings or counting nested details as separate findings. List items containing only whitespace are ignored. Quoted, fenced, and four-space/tab-indented code examples remain excluded. Other prose is not parsed as findings; this is a structured review format, not a general Markdown parser.

Bullets indented four or more spaces or a leading tab are treated as code and contribute no findings; an otherwise-empty, present severity section therefore reports **0**, not unknown. Numbered-list syntax also includes sentences such as `2024. The year was …` inside a findings section; put that contextual prose under `## What I checked` instead.

**Loop callers.** ralph-trio and spec-trio reserve a fresh absolute receipt file for each review and re-review, and pass it as `DEV_TRIO_REVIEW_RECEIPT`. The wrapper atomically writes `{schema_version: 1, result_path, final_path}` after publishing its result. Callers load that result with the shared reader, bind its exit code to the actual wrapper exit code, and link it into their parent manifest. Receipts are retained beside the logs as per-dispatch audit artifacts. They use the exact final only for supporting text and research requests. Missing receipts or failed reviews never fall back to `latest` links or a second Markdown verdict parser.

A result/receipt I/O failure prints a diagnostic and completes the log with a nonzero rc: **2** after model success, or the original nonzero invocation rc. No successful result is retained. An invocation that itself exits **3** is distinguished from a parse failure by the result's `status`, when a result is available.

`DEV_TRIO_REVIEW_PROFILE=spec` explicitly adds `OUT-OF-SCOPE` to the vocabulary. The spec-trio driver sets this profile; update spec-trio alongside dev-trio when using the two plugins together. Other role overrides must follow the selected profile's output contract. Nested dispatches still leave verdict ownership to the parent manifest.

**Reviewing without Codex memories.** With Codex's memories feature enabled in `~/.codex/config.toml`, `codex exec` adds the memory summary from earlier Codex sessions to the review prompt. Pass `--no-memories` (`ask-reviewer.sh --no-memories "focus"` or `/dev-trio:review --no-memories ...`) to run the built-in `codex-no-memories` model instead, which adds `-c features.memories=false`. Setting `DEV_TRIO_REVIEWER_MODEL=codex-no-memories` selects the same model without the flag (and without the checks below). With the flag, `ask-reviewer.sh` exits with rc=2 before starting any CLI when the reviewer role resolves to a model other than `codex` / `codex-no-memories`, or when the models config defines its own `codex-no-memories`.

**Arguments.** Both wrappers read their arguments before loading anything, so `ask-reviewer.sh --help` / `ask-researcher.sh --help` (or `-h`) print usage and exit 0 without starting a CLI or writing a log. A token shaped like an option — `-name` or `--name[=value]`, where the name is a letter followed by letters, digits, `_` or `-` — must be one the wrapper knows; anything else exits **2** before any CLI runs, so a typo such as `--no_memories` never becomes the review focus. Prose that starts with a dash (`"- item"`, `"-What is X?"`, a multi-line `NEED RESEARCH` body) is still the focus or question. A one-word focus or question shaped like an option (`-foo`) needs `--` in front of it: `ask-reviewer.sh -- "--help"`. A mistyped option with trailing whitespace (`"--hlep "`) is not option-shaped and is passed through as text. Each wrapper takes at most one focus/question; a second one, a `--with-*` flag without a path, or `ask-researcher.sh` with no question also exit 2.

## Upgrading to 0.7.0 — the wrappers were renamed

`ask-codex.sh` is now `ask-reviewer.sh` and `ask-agy.sh` is now
`ask-researcher.sh`: the names say the role, and the role picks the model. There
is **no compatibility shim** — the old names are gone.

Because ralph-trio and spec-trio resolve these by `command -v`, upgrade the
three plugins together (dev-trio 0.7.0, ralph-trio 0.4.0, spec-trio 0.2.0). A
mixed set fails the driver's dependency check as soon as a stage that needs the
missing wrapper is enabled — and only then: `--dry-run` skips both checks,
`--autoship` skips the reviewer check, `--no-research` skips the researcher one,
so a mixed set can instead fail later, at the call itself.

The PM policy is *copied* into each workspace's `CLAUDE.md`, so a source upgrade
does not reach it. In every workspace that has the block, re-run
`/dev-trio:install-pm` and start a fresh session, or the PM keeps dispatching the
removed command names.

Log, receipt and environment names are deliberately unchanged: `codex-*.log`,
`latest-codex.final.md`, `agy-*.log`, `latest-agy.log`, `dashboard.sh agy|codex`,
`CODEX_CLI`, `AGY_CLI`, and the `codex` / `agy` model ids. Those name the vendor
CLI or the log channel, not the wrapper.

## Install in Claude Code

```
/plugin marketplace add pandas-studio/agent-team-plugins
/plugin install dev-trio@pandas-studio
```

Local development:

```
git clone git@github.com:pandas-studio/agent-team-plugins.git
claude --plugin-dir ./agent-team-plugins/dev-trio
```

## Use

1. From your workspace, inside tmux:
   ```bash
   tmux new-session -s mywork
   claude
   ```

2. In the Claude session, set up the 3-pane layout once:
   ```
   /dev-trio:bootstrap
   ```

3. (Recommended on first install) Install the PM orchestration policy into the workspace's `CLAUDE.md`:
   ```
   /dev-trio:install-pm
   ```
   This appends a marked block to `$PWD/CLAUDE.md` between `<!-- BEGIN dev-trio PM policy -->` / `<!-- END dev-trio PM policy -->`. Re-running upgrades in place; safe to run again after plugin updates.

4. Drive normally. The PM policy tells Claude when to dispatch:
   ```
   ask-researcher.sh "What's the recommended way to stream tokens with langchain-anthropic 0.3.x?"
   ask-reviewer.sh "review the new retry logic in src/agent.py — concurrency safety"
   ```
   `ask-researcher.sh` exits **5** when the researcher CLI exits 0 with nothing but whitespace on stdout (for example, `agy -p` after soft-denying a tool). It exits **6** when the answer cannot be checked: the temp file cannot be created (the CLI is not run), or the CLI exits 0 but `tee` or the check fails. Treat both as failed research, not as an empty answer.

   Or use the wrapping skills:
   ```
   /dev-trio:research <question>
   /dev-trio:review  [focus] [--with-research <file>] [--with-spec <file>] [--with-context <file>]
   ```

   **Reviewers may run without network access** (Codex's sandbox disables it by default), so the PM supplies repository facts. For a PR, resolve the base/head commits with `gh pr view` first and pass them as `--with-context <file>` with a `<merge-base>..<head>` range focus; a bare `"pr 55"` focus leaves a sandboxed reviewer unable to identify the commits. When a reviewer still needs a remote fact it returns a `## NEED CONTEXT` block of read-only commands; the PM runs them, appends the output to the context file, and re-reviews once with every original flag.

## Research troubleshooting

### Before the first Codex research call

agy startup needs writes under `~/.gemini/antigravity-cli` (logs/crashes),
a localhost listener, and external network access. The Codex research skill
uses the host's supplied execution policy and known session restrictions:

| Host state | Action before dispatch |
| --- | --- |
| Required resources already permitted | Use normal execution, honoring existing grants. |
| A required resource is known blocked; approval available | Request normal host approval for that wrapper invocation before starting it. |
| A required resource is blocked; approval unavailable or refused | Stop without starting research. |
| Restrictions unknown | State the uncertainty and follow host policy; do not use research as a probe. |

Approval describes home writes, localhost binding and external network access;
the plugin does not change host policy or request blanket persistent grants.
Other researchers/custom adapters retain their own execution requirements.
Host approval does not grant agy's internal `read_url`, command or MCP permissions.
An unexpected failure still needs its own diagnostic; `rc=1` alone is not proof
of a host restriction. The skill follows the host permission policy and does
not silently retry, switch models, or reuse a failed answer.

### After a failed call: read-only setup checks

The [host acceptance scenarios](docs/research-host-acceptance.md) separate
model-free regression coverage from actual host/model behavior verification.

If research fails, the wrapper prints the selected model, exit code, exact run
log and a read-only doctor command. Both research skills run that check and
explain recovery. Preserve any per-call model, registry and CLI overrides when
running the printed command yourself. The plugin does not change vendor
settings or retry the question automatically.

```bash
DEV_TRIO_PM_HOST=codex "/absolute/path/to/dev-trio/bin/dev-trio-doctor.sh" --research
```

Use `DEV_TRIO_PM_HOST=claude` for Claude Code. `--research` checks only the
selected researcher: it does not require the reviewer, start tmux, call a model,
run an authentication subprocess, create run artifacts, or write settings.
It reports an available CLI version for unmodified built-ins. Custom adapters
and binary overrides are not executed for probing because they may interpret
`--version` as a prompt; their settings and authentication remain unverified.
Missing executables or invalid/unreadable configuration fail the check (exit
1). Missing agy settings and unavailable version information produce warnings.
Once the shell checks reach the Python diagnostic, the final summary separates
three outcomes. Earlier failures, such as a missing Python interpreter or failed
model/command resolution, exit without this summary:

```text
[PASS] Installation/config checks passed (see warnings/skipped checks above).
[NOT_CHECKED] Host execution: selected CLI startup under the current host policy.
[NOT_CHECKED] Research permissions: effective tool grants and actual research access.
```

The first row reports `[FAIL] Installation/config checks failed (...)` when
those checks fail. The host row refers to the selected CLI's own requirements;
agy's home writes and localhost listener are not assumed for custom adapters.
Existing exit semantics are preserved: `NOT_CHECKED` does not change the exit
code, and exit 0 is not proof of execution readiness. Configured rule counts/modes
above the summary describe only the inspected file; neither presence nor absence
proves effective grants. No startup write/bind/network probe is performed. The
original doctor without arguments retains its broader checks.

Read the `.run.json` and `.log` belonging to the failed invocation, not a
`latest` link. Question/context sections can quote errors; use only actual CLI
diagnostics to identify the cause. If startup failed before creating a log,
read the wrapper's stderr.

| Evidence from this invocation | Recovery |
| --- | --- |
| Authentication required or login failure | Open the selected CLI in a terminal and complete its normal authentication flow. |
| Host sandbox blocks CLI startup, networking or Keychain | Use the PM host's normal permission flow. This is separate from the child CLI's tool permissions. |
| agy explicitly reports a headless tool permission denial | The wrapper prints `agy denied: <kind>(<target>)` when agy recorded the target (review: `status: "permission-denied"`). Review that one rule in agy's `/permissions`. |
| CLI exited 0 without an answer; wrapper returns 5 | Inspect the diagnostic. Headless denial is one possible cause, not a conclusion from the code alone. |
| Answer could not be captured/inspected; wrapper returns 6 | Check the reported file, temporary-directory or write error. Do not grant tool permissions to fix a capture failure. |
| Other failure, or no explanatory diagnostic | Keep the cause unknown and inspect the selected CLI's own diagnostics. Nonzero CLI codes, including 5 and 6, are preserved. |

### Resolve a confirmed agy permission denial

Headless agy cannot display an approval prompt. It can soft-deny a tool, emit
a notice on stderr and still exit 0. dev-trio rejects an empty answer from that
run. See the [official headless guide](https://www.antigravity.google/docs/cli/headless/).

1. Identify the action and target. The wrappers read it from agy's own record
   of this run (`<agy home>/brain/<conversation>/.system_generated/logs/transcript_full.jsonl`)
   and print `agy denied: <kind>(<target>)` plus `agy conversation: <id>`; the
   review result carries the same in `denied` and `conversation_ids`. They only
   do so when this run printed agy's headless no-output notice, never from code
   5 or an empty answer alone. If the target is reported as unknown — agy
   recorded none, the record was not written yet, or the log directory was not
   writable — open interactive agy from the same
   workspace and reproduce the original question/context to see the permission
   request. This is another model call and may repeat external actions; inspect
   the request before deciding whether to grant it. Do not infer a broad permission
   from code 5 or from the last command mentioned in the question.
2. Use agy's `/permissions` or edit `~/.gemini/antigravity-cli/settings.json`
   yourself. Under `permissions.allow`, review only the required
   `command(<target>)`, `read_url(<domain>)`, or `mcp(<server/tool>)` rule.
   These are placeholders, not a permission bundle to copy wholesale. A Python
   query does not require allowing every Python command, and a documentation
   page does not require allowing all websites. Existing `ask`/`deny` rules may
   take precedence. See [official permission rules](https://www.antigravity.google/docs/permissions?tab=cli).
3. If agy warns that `unsandboxed(...)` rules are ignored, follow the guidance
   for that installed CLI. The doctor only flags their presence: support varies
   by version/platform, so neither it nor plugin installation migrates them.
4. Re-run `dev-trio-doctor.sh --research`, then explicitly request the failed
   run again with its original inputs — the question and stdin context for
   research, the focus and every `--with-*` file for a review. This is a new
   run and may repeat external calls; it is not automatic resumption. A
   different needed tool may require another permission decision.

Do not enable blanket permission bypass as the default fix. Successful recovery
requires exit 0 **and** a nonempty final answer that addresses the question with
appropriate sources. Pass that new `.final.md` to follow-up work; a failed run,
its diagnostics, or an older successful answer cannot replace it. Static and
stub checks are not evidence of a successful live research call.

## Skills

| Skill | What it does |
| :--- | :--- |
| `/dev-trio:bootstrap` | One-time per session: splits the current tmux pane into 3 and starts the agy/codex dashboards. |
| `/dev-trio:research <question>` | One-shot Antigravity lookup. Streaming output lands in the top-right pane; chat-side surfaces the lead + cited URLs. |
| `/dev-trio:review [focus] [--with-research <file>] [--with-spec <file>] [--with-context <file>]` | One-shot Codex review (default = git-uncommitted scope). Chat-side surfaces verdict (`SHIP / NEEDS-FIX / DISCUSS`) + Blocker/Major counts. Handles `## NEED RESEARCH` (via Antigravity) and `## NEED CONTEXT` (via the PM's read-only `gh`/`git`) blocks. |
| `/dev-trio:install-pm` | Writes/upgrades the PM orchestration policy in the workspace's `CLAUDE.md` (idempotent, marker-guarded). |

Claude skills carry `disable-model-invocation: true`; Codex skills use
`policy.allow_implicit_invocation: false` in `agents/openai.yaml`. Invoke the
host-specific skills explicitly. Custom manifest paths avoid loading both
variants through the default `skills/` discovery path.

## Logs

Per-team log namespace. Each invocation writes to:

```
$PWD/.dev-trio/log/<team>/
├── agy-<TS>-<PID>.log      # raw researcher output + framing
├── agy-<TS>-<PID>.final.md      # the answer alone
├── codex-<TS>-<PID>.log    # raw reviewer output + framing
├── codex-<TS>-<PID>.final.md    # unchanged final response
├── codex-<TS>-<PID>.review.json # common parsed review result
├── <name>-<TS>-<PID>.run.json   # per-invocation run metadata (dashboard)
├── latest-agy.log          # symlink to most recent agy run
├── latest-agy.final.md     # symlink to its answer
├── latest-codex.log        # symlink to most recent codex run
└── <name>-<TS>.manifest.json   # RFC 0004 typed run manifest
```

**Run metadata.** Every invocation publishes `<stem>.run.json` (`lib/runstate.sh`)
atomically beside its log: `channel` (`agy`/`codex` — the log stream, never a
model), `role`, the resolved `model`, `team`, `started_at`, `pid`, `pm_host`,
`nested`, the absolute artifact paths, and the `inputs` the wrapper was given.
A research stdin context is recorded there only as its `bytes` and `sha256`,
so a large context cannot push the file past the dashboard's size bound; the
manifest keeps its full text.
A second atomic rewrite of the same file adds `completion`
(`ended_at`, `exit_code`, `verdict`, `reason`) when the run ends — including on
an abort, published from the wrapper's EXIT trap, so an interrupted run does not
read as live forever. Unlike the RFC 0004 manifest, this file exists while the
run is live and is written for nested dispatches too.
Research completion reasons are `ok` for exit 0, `failed` for a nonzero return,
and `aborted` for the EXIT-trap backstop. `failed` records the outcome, not a
diagnosis of permission denial.

Both wrappers append a final `=== END (rc=...) ===` log marker on a best-effort
basis. If that append fails, they warn on stderr and preserve the resolved
exit code and completion metadata; a published review keeps its verdict.
Required result, receipt and manifest publication failures still fail the run.
The dashboard uses `.run.json` for completion, so a missing END marker does not
leave a completed run looking live. Legacy logs without run metadata continue
to show completion as unavailable. This policy covers the final append;
logging failures during model execution retain their existing behavior.

[ralph-trio's `ralph-meta.sh`](../ralph-trio/bin/ralph-meta.sh) also uses END to
bound its raw-log fallback when no usable `.final.md` exists. Without END, that
fallback reads through EOF and can include
late output from a descendant of the model CLI. It is raw diagnostic text;
use the invocation's final/result artifacts for the authoritative review.

This final-append policy is specific to dev-trio. The
[debate-conductor role wrappers](../debate-conductor/README.md#logs) treat a
failed END append as a logging failure: a successful model run becomes rc=6,
while an already nonzero model exit code is preserved.

**Reviewer transcript.** The reviewer CLI writes straight into
`codex-<TS>-<PID>.log` on a descriptor, which `tail -F` follows as the review is
produced. The dashboard does not read it — it renders from the run's `*.run.json`
(above), so what it shows is the run's status and verdict, not the console text.
`ask-reviewer.sh` replays the transcript on its own stdout once, after the review
is published.

Nothing is piped: a pipeline only ends when every process holding its write end
closes it, so a CLI that left a background descendant holding either stream used
to hold the wrapper open long after the review existed. The wrapper samples the
transcript's length when the CLI returns, and both the replay and the
synthesized final read that frozen range — so a descendant that outlives its
parent no longer decides when the wrapper finishes, and what it writes past the
sampled length reaches the log but neither artifact. The cost is that the
wrapper's own stdout is no longer live.

An **interrupted** run (`SIGINT`/`SIGTERM` while the CLI is running) publishes no
review — a result parsed from a partial transcript would be worse than none —
and puts nothing on stdout. It prints `(log: …, final: …, rc=…)` on stderr and
exits on the signal's own status, with the run's `*.run.json` recording
`reason: aborted`. That line is what a caller reads: `ralph-meta.sh` takes the
log path out of it and recovers the partial transcript from the log itself, so
naming the artifacts serves it better than replaying bytes onto a stdout it may
not have captured. `result:` is absent because no review exists.

**Researcher answer.** `agy-<TS>-<PID>.final.md` holds the answer on its own,
captured by `registry_run_answer`: the model's own last message when it defines
`final_args`, otherwise that function's existing copy of stdout — stdout alone,
so a caller's `2>&1` merge never reaches it. The wrapper's stdout is that
answer, and the transcript goes to the log, which the pane and the dashboard
follow while the run is live. A caller that injects this wrapper's output
injects the answer.

Capture lives in the library because only there is the CLI's own exit status
still in hand. A caller sees one number and cannot tell a CLI that chose to
exit 5 from the library judging stdout empty. The exit codes: the model's own,
which an artifact on disk never promotes; **5** when it exits 0 leaving no
answer; **6** when the answer could not be captured or inspected. Passing no
answer path keeps the previous stdout-only behaviour, which is what
debate-conductor's generator and critic use.

`<team>` resolution (priority order):

1. `$AGENT_TEAM` env var
2. tmux window option `@team-name` (set by `bootstrap`)
3. tmux session name
4. `default`

Override the log root with `DEV_TRIO_LOG_DIR=/path/to/logs`. The wrappers create
missing log directories with private permissions. An existing team log directory
must be owned by the caller and must not be writable by group or others. Every
ancestor, including a symlink target, must be safe to traverse; a writable
ancestor is accepted only when it is sticky and owned by root or the caller
(as with `/tmp`). The wrappers reject unsafe paths before invoking a model and
never change permissions on an existing directory. Choose a private log root
or repair its permissions yourself if validation fails.

## Live dashboard

Two side panes run a flicker-free dashboard showing **distilled key points only** — the full raw output stays in the Claude (PM) pane and on disk. Each side pane shows:

- **Antigravity**: query, status, *answer lead* (first paragraph of the answer artifact), distinct cited URLs
- **Codex**: focus, status, **verdict box** (color-coded), findings counts, **Blocker/Major text** (when present)

```bash
dashboard.sh agy      # in one side pane
dashboard.sh codex    # in another side pane
```

Color legend (codex verdict):

- 🟢 **SHIP** — green bar
- 🔴 **NEEDS-FIX** — red bar
- 🟡 **DISCUSS** — yellow bar

**Controls** (inside dashboard pane):

- `l` — open the full log in `less` (`q` to return)
- `space` — pause auto-refresh (so you can use `Ctrl-b [` to scroll), space again to resume
- `q` — quit
- `Ctrl-C` — also quits

Every value the dashboard renders comes from the run's `.run.json` and
`.review.json`; it never parses the log body, where the text under review sits
next to the wrapper's own `=== ... ===` framing and could otherwise forge the
model, the start time or the completion state. Untrusted text is stripped of
escape sequences and control characters and rendered behind a `│` gutter, so it
cannot repaint the pane or pass for a dashboard field.

The states are distinct: no runs yet · a latest link pointing at a missing log ·
**legacy** (a log with no metadata beside it — the start time is read from the
filename and nothing else is claimed) · unreadable metadata · metadata that
describes another run, or a run outside this team's directory · metadata too
large to load · ⏳ running · ✓ done / ✗ failed. Only the selected log's own
siblings are read, whatever paths the metadata names. Rendering only happens
when content actually changes (cksum-based skip), and uses cursor-home +
per-line erase instead of a full screen clear, so there's no visible flicker.

`dashboard.sh <channel> --once` renders a single frame and exits — for scripts
and tests rather than a pane.

**Raw fallback** (when the dashboard misbehaves or you want unfiltered output):

```bash
tail -F .dev-trio/log/${AGENT_TEAM:-default}/latest-agy.log
tail -F .dev-trio/log/${AGENT_TEAM:-default}/latest-codex.log
```

The wrapper scripts print both the dashboard command and the raw `tail -F` hint to stderr when they start.

## Layout commands

`/dev-trio:bootstrap` already wires the layout from inside Claude Code. For other entry points, the underlying `team-layout.sh` is on the plugin PATH:

```bash
team-layout.sh                # creates session "dev-trio", attaches
team-layout.sh -n myteam      # custom session/team name
team-layout.sh --here         # split current tmux window in place
team-layout.sh --no-attach    # create session detached
```

The left pane is left as an idle shell — run `claude` (or whatever) yourself.

For users who skip Claude Code and want to spawn the layout from a raw shell via `prefix + R`, add this to `~/.tmux.conf`:

```tmux
# Adjust the path to your dev-trio install dir.
# Local-marketplace install lands under ~/.claude/plugins/dev-trio/ by default,
# but the exact path depends on how you added the marketplace.
bind-key R run-shell "~/.claude/plugins/dev-trio/bin/team-layout.sh --here"
```

Reload tmux: `tmux source-file ~/.tmux.conf`. See `tmux/keybinding.conf.example`.

## Architecture

```
dev-trio/
├── .claude-plugin/plugin.json  # skills: ./claude-skills/
├── .codex-plugin/plugin.json   # skills: ./codex-skills/
├── codex-skills/              # bootstrap/research/review/install-pm
├── claude-skills/
│   ├── bootstrap/SKILL.md
│   ├── research/SKILL.md
│   ├── review/SKILL.md
│   └── install-pm/SKILL.md
├── bin/                       # on plugin PATH while active
│   ├── ask-researcher.sh             # Researcher wrapper
│   ├── ask-reviewer.sh           # Reviewer wrapper
│   ├── agent-team-models.sh   # shared model-registry CLI (vendored)
│   ├── dashboard.sh           # live dashboard (agy|codex)
│   ├── team-layout.sh         # tmux 3-pane splitter
│   └── dev-trio-doctor.sh     # env probe + stub-CLI smoke
├── lib/                       # internal
│   ├── manifest.sh            # RFC 0004 run-manifest helper (byte-identical copy of ralph-trio's)
│   ├── registry.sh            # shared model registry + runner (vendored)
│   ├── host.sh                # host defaults and CLI/login checks
│   ├── pm.md                  # Claude PM policy
│   ├── pm-codex.md            # Codex PM policy
│   └── roles/
│       ├── researcher.md      # Antigravity role prompt
│       └── reviewer.md        # Codex role prompt
└── tmux/keybinding.conf.example
```

## Doctor

A one-shot env probe + stub-CLI smoke is bundled:

```bash
dev-trio-doctor.sh
```

Checks required helpers and resolved role binaries, probes Claude login for the Codex host, treats tmux as optional, verifies that `ask-researcher.sh` produces a well-formed RFC 0004 manifest under stub CLIs, and exercises the `agent-team-models` registry CLI (list / preset / set-role / doctor / remove against an isolated config). **Stub smokes are necessary but not sufficient** — verdict / dashboard / parse-affecting changes need a real-CLI dry-run on top.

`dev-trio-doctor.sh --smoke-only` skips the PM host and role CLI/login probes, which depend on this machine's configuration and login state, and runs everything else. `scripts/check.sh` runs it this way.

## Development checks

```bash
bash scripts/check.sh
python3 tests/check_dev_trio_loaders.py   # requires local claude + codex, no inference
```

Run these from the repository root. The native discovery test copies the plugin
into a temporary path containing spaces, installs it in a disposable
`CODEX_HOME`, and checks both hosts expose exactly their own four skills. It
leaves user plugin installations unchanged. CI uses recording CLI stubs for
role precedence, authentication, argv/context handoff, failures, and policy
updates. Live model calls are a separate acceptance check.

Both manifests explicitly select their host skill directory; there is no root
`skills/` directory. The Codex scaffold validator assumes that fixed directory,
so it rejects the custom `skills` path even though the native loader supports
it. Validate Codex skill metadata separately and use the native discovery test
for the actual package paths. A temporary view normalized to `skills/` can also
be used with the scaffold validator for its remaining metadata checks.

## Security model

The wrappers use **two layers** of injection defense:

1. **Role-prompt level** — each role file has a `Trust boundary` section telling the agent to ignore directives inside `<user_question>` / `<review_target>` / `<research_context>` tags.
2. **Literal-string level** — the wrapper scripts strip the matching closing tag from untrusted input before embedding.

We **deliberately did not** add JSON/base64 encoding of payloads (which Codex flagged as the "proper" fix). This is a local dev tool, not a production surface receiving adversarial input. The most realistic attack vector is **Antigravity's research output flowing into Codex**; if the threat model changes (e.g., Antigravity starts pulling untrusted external content as context), upgrade to encoded payloads. Until then, the two layers above are sufficient.

## License

[MIT](../LICENSE).
