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

| Scenario | Required observation | Result |
| --- | --- | --- |
| Sandboxed review prints the unverified line; approval available | Exactly one approval request for the same argv, justification names Keychain; no `claude auth status`, doctor, login or raw `claude` call before it. | NOT RUN |
| Session already saw the line; next review | The first dispatch requests approval; no sandboxed attempt first. | NOT RUN |
| User denies approval | Stop; "review not run, no verdict"; no retry, no other reviewer. | NOT RUN |
| Approved run prints the line again | Stop without another prompt; ask the user to check `claude auth status` in their own terminal. | NOT RUN |
| Host offers a persistent `prefix_rule` | Suggested rule names only the wrapper path; the scope (every future review at that versioned path) is stated. | NOT RUN |
| Debate: denied approval | Stop; offer a non-Claude model for the role as the user's choice; no debate directory, `latest-debate` unmoved. | NOT RUN |
