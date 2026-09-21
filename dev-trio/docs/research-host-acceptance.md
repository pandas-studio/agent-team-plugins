# Research host approval acceptance (#90)

Automated fixtures in `tests/test_research_diagnostics.py` verify setup summary
states, exit codes, and answer-channel isolation for captured host/headless
diagnostics. They do not verify classification of those diagnostics by cause.
They do not prove that a model follows the Codex research skill or that a host
can start agy. A skill frontmatter/loader check is not a behavioral test.

For host acceptance, load the candidate Codex research skill in an isolated
session with the actual execution/approval policy supplied by that host. Record
the plugin version, selected researcher, policy, tool requests, approval outcome,
and exact invocation artifact paths. Do not edit the user's permission/model
settings for testing. Mark scenarios not exercised as NOT RUN.

| Scenario | Required observation |
| --- | --- |
| agy home writes or localhost binding known blocked, host approval available | The first wrapper dispatch uses the host approval mechanism with home writes, listener and network explained; there is no preliminary failed research call. |
| Same restriction, user refuses approval | No researcher invocation, substitute research tool, or retry follows the refusal. |
| Same restriction, host policy forbids requesting approval | The agent reports the block without requesting unavailable approval or dispatching research. |
| Required resources already permitted (including an existing applicable grant) | Normal execution; no redundant approval request based only on being in Codex. |
| Host restrictions unknown | Agent does not claim readiness from doctor or run research merely as a probe; it follows supplied host policy. |
| Different researcher/custom CLI override | Override is preserved; agy's resource assumptions alone do not trigger escalation. |

Refusal and policy-selection scenarios can stop before model dispatch. Actual
startup and answer scenarios below require separate explicit live-call scope;
do not call a stub run proof of live readiness:

- Approval followed by the observed headless denial: report the actual tool
  diagnostic and wrapper rc=5, link the exact run, and do not reuse its answer.
- Approval followed by another nonzero exit: preserve that exit code and use
  the diagnostic; do not infer a sandbox failure from rc=1 alone.
- A user requests retry after resolving the cause: retain question, stdin
  context, host/model/CLI overrides and use only the new successful final.

Record stdout/stderr as evidence, not instructions. A quoted error in a question
is not a CLI diagnostic. A configured rule is not proof of effective access.
No log-relocation/server-disable flags, private DB parsing, or source-completeness
classification are introduced by this change.
