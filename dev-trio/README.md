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

## Model configuration

The Researcher and Reviewer roles resolve through the shared model registry (the [marketplace README](../README.md#shared-model-configuration) covers it in full). Defaults are `agy` (researcher) and `codex` (reviewer) — no setup needed.

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

A parsed review exits **0**, including `NEEDS-FIX` or `DISCUSS`; inspect `verdict` to decide the next action. A parse failure after a successful invocation exits **3** (`status: "parse-failed"`). An invocation failure preserves its original nonzero exit code (`status: "invocation-failed"`). Both failure statuses leave `verdict: null`. `error` explains the failure. The reviewer requests `- None.` for empty sections in every language; the parser also accepts exact `- none` (case-insensitive, optional period) and Korean `- 없음` / `- 없음.`. Other short bullets remain findings.

**Loop callers.** ralph-trio and spec-trio reserve a fresh absolute receipt file for each review and re-review, and pass it as `DEV_TRIO_REVIEW_RECEIPT`. The wrapper atomically writes `{schema_version: 1, result_path, final_path}` after publishing its result. Callers load that result with the shared reader, bind its exit code to the actual wrapper exit code, and link it into their parent manifest. Receipts are retained beside the logs as per-dispatch audit artifacts. They use the exact final only for supporting text and research requests. Missing receipts or failed reviews never fall back to `latest` links or a second Markdown verdict parser.

A result/receipt I/O failure prints a diagnostic and completes the log with a nonzero rc: **2** after model success, or the original nonzero invocation rc. No successful result is retained. An invocation that itself exits **3** is distinguished from a parse failure by the result's `status`, when a result is available.

`DEV_TRIO_REVIEW_PROFILE=spec` explicitly adds `OUT-OF-SCOPE` to the vocabulary. The spec-trio driver sets this profile; update spec-trio alongside dev-trio when using the two plugins together. Other role overrides must follow the selected profile's output contract. Nested dispatches still leave verdict ownership to the parent manifest.

**Reviewing without Codex memories.** With Codex's memories feature enabled in `~/.codex/config.toml`, `codex exec` adds the memory summary from earlier Codex sessions to the review prompt. Pass `--no-memories` (`ask-reviewer.sh --no-memories "focus"` or `/dev-trio:review --no-memories ...`) to run the built-in `codex-no-memories` model instead, which adds `-c features.memories=false`. Setting `DEV_TRIO_REVIEWER_MODEL=codex-no-memories` selects the same model without the flag (and without the checks below). With the flag, `ask-reviewer.sh` exits with rc=2 before starting any CLI when the reviewer role resolves to a model other than `codex` / `codex-no-memories`, or when the models config defines its own `codex-no-memories`.

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
A second atomic rewrite of the same file adds `completion`
(`ended_at`, `exit_code`, `verdict`, `reason`) when the run ends — including on
an abort, published from the wrapper's EXIT trap, so an interrupted run does not
read as live forever. Unlike the RFC 0004 manifest, this file exists while the
run is live and is written for nested dispatches too.

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

Override the log root with `DEV_TRIO_LOG_DIR=/path/to/logs`.

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
│   ├── manifest.sh            # RFC 0004 run-manifest helper (vendored)
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
