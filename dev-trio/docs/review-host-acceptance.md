# Claude login preflight under a Codex host (#127)

Covers the Claude login check in `dev-trio/lib/host.sh` (reviewer, and a Claude
researcher) and `debate-conductor/lib/host.sh` (debate rounds). Three kinds of
evidence are kept apart; none of them stands in for another.

## Why the wrapper cannot say "logged out"

Measured on macOS with codex-cli 0.157.0 and Claude Code 2.1.283, on an account
that is logged in:

| Where `claude auth status --json` ran | stdout | rc |
| --- | --- | --- |
| host shell | `"loggedIn": true, "authMethod": "claude.ai"` | 0 |
| `codex sandbox -c 'sandbox_mode="workspace-write"' --` | `"loggedIn": false, "authMethod": "none"` | 1 |
| same with network access enabled | `"loggedIn": false, "authMethod": "none"` | 1 |

Inside the sandbox `CODEX_SANDBOX=seatbelt` is set. A logged-out install would
print the same bytes, and the marker is a hint rather than proof, so every
failed check reports what it saw (`Claude login unverified in this
environment (auth status: loggedIn=false, rc=1, CODEX_SANDBOX=seatbelt)`) and
exits 2 before any invocation. The Codex skill decides, because only it knows
whether the host approved the run.

## 1. Stub tests (automated, `scripts/check.sh`)

`tests/test_dev_trio_hosts.py` and `tests/test_debate_conductor_hosts.py` compare
the exact stderr lines, the recorded calls (`auth status --json` only) and the
absence of artifacts for: the measured sandbox shape with and without the
marker; a confirmed login with the marker set (proceeds); five other probe
results; `ask-researcher.sh` with a Claude researcher (approval line, no doctor
command, and the setup check kept when an inherited flag meets a missing CLI or an unregistered model); `dev-trio-doctor.sh`; `debate.sh`, `ask-critic.sh` and
`ask-generator.sh`; and `debate.sh --continue-from` (ledger, files and
`latest-debate` unchanged). These prove wrapper behavior only.

## 2. Live wrapper runs (real `claude`, no Codex session)

Run on 2026-09-26 from this branch, macOS, codex-cli 0.157.0, Claude Code
2.1.283. "Sandboxed" is `codex sandbox -c 'sandbox_mode="workspace-write"' --`;
the default read-only mode cannot create the wrappers' here-document temp files
and fails earlier for an unrelated reason.

| Command | Where | Observed |
| --- | --- | --- |
| `DEV_TRIO_PM_HOST=codex ask-reviewer.sh "dev-trio/lib/host.sh"` | sandboxed | rc 2, the two login lines with `loggedIn=false, rc=1, CODEX_SANDBOX=seatbelt`; no log directory created |
| same | host shell | rc 0, run header `MODEL: claude`, `.review.json` `status: ok` |
| `DEBATE_CONDUCTOR_PM_HOST=codex debate.sh --primary-gen=codex -n 2 "<topic>"` | sandboxed | rc 2, the two login lines; no `.debate-conductor` directory |
| same | host shell | rc 0; ledger `end` records rc 0 for round 1 (gen, codex) and round 2 (crit, claude) |

`-n 2` matters: with `-n 1` the critic is never scheduled and never probed.
The host-shell runs stand in for an approved run; they do not show that a
Codex approval prompt produces one.

## 3. Codex-session behavior (manual)

The skills' one-attempt rule can only be observed in a Codex session with a
real approval prompt. Record plugin version, host policy, each tool request,
the approval outcome and artifact paths. Do not edit the user's permission or
model settings to test. Mark scenarios not exercised as NOT RUN.

Run on 2026-10-02, macOS, codex-cli 0.159.3, Claude Code 2.1.287, PM model
`gpt-6-astra` (reasoning effort medium, from each rollout's `turn_context`).
Codex loaded dev-trio 0.8.35 and debate-conductor 0.5.32 from its plugin
cache; `cmp` against `origin/main` at `432f00d` showed
`codex-skills/review/SKILL.md`, `bin/ask-reviewer.sh` and `lib/host.sh`
(dev-trio) and `codex-skills/run/SKILL.md`, `bin/debate.sh` and `lib/host.sh`
(debate-conductor) identical. The sandbox still hides the login: under
`codex sandbox -c 'sandbox_mode="workspace-write"' --`, `claude auth status
--json` printed `loggedIn: false`, rc 1, `CODEX_SANDBOX=seatbelt`, while the
host shell printed `loggedIn: true`.

Method. Four interactive sessions (A–D), each new, started by the user in
their own terminal from a scratch Git workspace `<ws>` holding two short
shell scripts, `a.sh` and `b.sh`, as
`codex -c features.memories=false -s workspace-write -a on-request` (network
off) under `env -i`. Passed through from the user's terminal, each only if
set: `HOME PATH USER LOGNAME SHELL TERM COLORTERM TERM_PROGRAM
TERM_PROGRAM_VERSION TERMINFO LANG LC_ALL LC_CTYPE TMPDIR SSH_AUTH_SOCK
__CF_USER_TEXT_ENCODING CODEX_HOME`; added: `AGENT_TEAM=default`, and in
session C only, `REVIEWER_CLI` (below). Apart from that one intended
override, no wrapper, registry or manifest variable reached a session; the
cached libraries resolved the reviewer and the debate critic to `claude` and
the generator to `agy`.
Memories were off so one session could not prime the next. The prompt was
the skill invocation and a focus or topic, nothing else. Refusals ran first;
every approval was the one-time "Yes, proceed". Evidence per session: the
rollout under `~/.codex/sessions/2026/10/02/` (each escalated call's
`sandbox_permissions`, `justification` and any `prefix_rule`), and listings of
`<ws>/.dev-trio/log/default` and `<ws>/.debate-conductor/log/default` before
and after. `~/.codex/rules/default.rules` had the same checksum before and
after every session. `~/.codex/config.toml` changed once, during session A
(checksum `a643ba12…` before, `f95ae977…` after and through D). Afterwards it
holds `[projects."<ws>"] trust_level = "trusted"`, and its mtime (21:21)
matches A's start (21:21:00); the earlier contents were not saved, so the
write is not shown to have added only that entry. Whatever it changed, each
rollout's `turn_context` records the policy the flags set: approval
`on-request`, `workspace-write`, network off.

In every session the PM's only calls before its first dispatch were reading
the skill file and, in A and D, `pwd` and `rg --files`. No session ran
`claude auth status`, the doctor, `claude auth login` or a raw `claude`.

Codex 0.159.3 offers one way to decline: "No, and tell Codex what to do
differently (esc)". It aborts the turn (`turn_aborted`, reason
`interrupted`), so after a refusal the PM writes no reply. The reply that
rows 3 and 6 require is therefore not observable in this Codex version; the
rest of those rows is.

| Scenario | Required observation | Result |
| --- | --- | --- |
| Sandboxed review prints the unverified line; approval available | Exactly one approval request for the same argv, justification names Keychain; no `claude auth status`, doctor, login or raw `claude` call before it. | PASS, three times. Sessions A `01a0fc8f-8a71-7ff1-916b-9548f23c26d1`, C `01a0fc95-a346-7f20-8b00-ca2d7356c9ec` and D `01a0fc98-5df5-7b03-8f91-f7270a86435b` (first review): the sandboxed `ask-reviewer.sh "a.sh"` exited 2 with `loggedIn=false, rc=1, CODEX_SANDBOX=seatbelt`; the next call was the same command with `sandbox_permissions: require_escalated` and a justification naming macOS Keychain; no other escalation followed. In D it was approved and gave run `codex-20261002-213114-71907` (`MODEL: claude`, `.review.json` `status: ok`) |
| Session already saw the line; next review | The first dispatch requests approval; no sandboxed attempt first. | PASS — session D, second prompt (`$dev-trio:review b.sh`, after the first review above had printed the line): the first `ask-reviewer.sh "b.sh"` call already carried `require_escalated`, with no sandboxed attempt. Approved once; run `codex-20261002-213354-88688`, `status: ok` |
| User denies approval | Stop; "review not run, no verdict"; no retry, no other reviewer. | PASS for stop, no retry and no other reviewer; the reply is not observable. Session A: after the line, one escalated request; the user declined; the call's output is `aborted by user`, the turn ended (`turn_aborted`), and no run file was added. (Session C's reply in the approved-run branch did say "did not run; no verdict is available".) |
| Approved run prints the line again | Stop without another prompt; ask the user to check `claude auth status` in their own terminal. | PASS — session C, with `REVIEWER_CLI` set to a stub named `claude` whose `auth status --json` prints `{"loggedIn":false,"authMethod":"none"}` and exits 1. The approved login cannot be made to fail without editing the user's auth, so the stub replaced only the probe result; the skill saw the same two lines. The stub's receipt holds two `auth status --json` probes, the sandboxed one with `CODEX_SANDBOX=seatbelt` and the approved one without it, and no other call. After the approved run the PM stopped with no further tool call: "The review of `a.sh` did not run; no verdict is available. Claude's login check failed even with host access. Run `claude auth status` in your terminal and log in if it reports that you're logged out." |
| Host offers a persistent `prefix_rule` | Suggested rule names only the wrapper path; the scope (every future review at that versioned path) is stated. | NOT RUN — not suggested. Each session's developer message carried the host's `prefix_rule` guidance, but none of the five escalated calls (A, B, C, D ×2) suggested one. The host offered its own persistent option anyway, built from the whole command: "Yes, and don't ask again for commands that start with `DEV_TRIO_PM_HOST=codex "<cache>/dev-trio/0.8.35/bin/ask-reviewer.sh" "b.sh" </dev/null`" (session D, second review). It includes the focus, so it would match only another review of `b.sh`. It was not chosen |
| Debate: denied approval | Stop; offer a non-Claude model for the role as the user's choice; no debate directory, `latest-debate` unmoved. | PASS for stop, no debate directory and `latest-debate` unmoved; the offer is not observable. Session B `01a0fc92-170a-72e1-b29e-10486ab8ad3a`, `$debate-conductor:run -n 2 "<topic>"`: the sandboxed `debate.sh` exited 2 with the critic's unverified line (which itself names choosing a non-Claude model); one escalated retry of the same command, justification naming Keychain for the Claude critic; the user declined; `turn_aborted`. No `ask-generator.sh`, `ask-critic.sh` or `claude` call. `<ws>/.debate-conductor` did not exist before or after, so no `latest-debate` |
