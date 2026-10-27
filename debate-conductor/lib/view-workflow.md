# Skill viewing and dispatch contract

Read this for `run`, `continue`, or explicit `bootstrap`. Claude uses bare
`bin/` script names on the plugin PATH; Codex resolves the plugin root and uses
absolute `<plugin-root>/bin/…` paths. No leading shell environment assignments,
`eval`, raw model CLIs, or implicit invocation of another skill are needed.

Claude run/continue register a narrow `PreToolUse` announcement hook. Claude
keeps skill hooks for the session; this hook ignores other commands and receipt
reads. Before runner dispatch it also displays the latest helper's instructions
as a host notice, covering hosts that render progress replies as narration.
This does not grant tool permissions or alter global settings.
Unreadable, compacted or malformed transcript records skip the redundant host
notice and never block dispatch; the ordinary assistant reply remains required.

## 1. Parse controls and resolve the task

Consume leading `--view=auto|tmux|none` (default `auto`), `--open-view`, and
`--terminal=auto|ghostty|terminal`. A terminal choice requires `--open-view`;
`--view=none --open-view`, duplicates, malformed controls and unknown values
are errors: stop before setup/inference. `--` terminates control parsing.
Preserve quoted topic text containing option-like words. Resolve topic and
rounds before preparing a view. Bootstrap is view-only and needs no topic.

## 2. Prepare in its OWN tool call

For a new debate:

```sh
team-3pane.sh --view=auto
```

Replace the mode with the selected value. Add `--view-only` for `--open-view`
so the separate terminal will contain two viewers and no PM pane. Read the
returned JSON; retain its **exact `context_file` path**, never retype its JSON.

For a continuation, first resolve the chosen debate physically. Its parent is
the selection/log directory. For normal `<base>/<team>/debate-*`, pass both
`--team=<team>` and `--log-base=<absolute-base>` to this same preparation call.
For a nonstandard parent that is not a valid team namespace, use
`--log-dir=<absolute-parent>`: auto/none return manual tails; strict tmux refuses.
Never construct a different namespace from the PM's current tmux window.

`auto` can fall back to manual tails; `tmux` requires a ready view and exits 2
otherwise. A zero CLI exit is insufficient: inspect the returned status.
If `reason_code` is `sandbox-denied`, one narrow host-approved retry of this
same helper may be requested when supported. Never change allowlists/sandbox
settings. If unavailable/denied, auto uses manual instructions; strict tmux
stops. Do not repeatedly probe tmux or start a model before this is resolved.

## 3. Optional opening, then USER-VISIBLE instructions

Only if `--open-view` was requested and status is `ready-detached`, call:

```sh
open-view.sh --context '<exact context_file>' --terminal=auto
```

Use the chosen terminal. Local macOS supports Ghostty >=1.3 and Terminal.app;
other/SSH hosts return instructions. Allow at least 180 seconds for this tool
call (or background it and poll), so
native Automation consent/Apple Event timeout can finish before the host timeout.
On a host timeout do not immediately launch again: a window may still attach;
check the existing client first using the same saved opener context.
A native Automation denial is distinct
from sandbox denial: no retry/alternate-app permission cascade for TCC denial.
A sandbox-denied opener may get one narrow host-approved retry. GUI failure
is advisory when the tmux view is ready, including in strict tmux mode.

**Send a chat message BEFORE starting the long-running dispatch tool call:**
Copy the actual commands below into assistant text. Tool output alone is not
the viewing instruction, and `--view=none` does not waive this step.
The most recent helper supplies a ready-to-send `user_message` (use the opener's
message if opening was requested): **send that text verbatim as your assistant
reply after setup/optional opening and before the dispatch tool call**.

- `present`: verified Generator/Critic viewers are in this tmux window.
- `ready-detached`: a background view is prepared, **no terminal is visible
  yet**. Show the exact `attach_command` and say to use another terminal
  tab/window on the **same machine and user**. If opening confirmed an attached
  client, report that fact. `launch-requested` is not verified attachment.
- `manual`: show both `tail_commands` and the actual fallback reason.

Do not wait for a recurring preference question: the default immediately
continues. Offer “뷰 열어줘” as a later action. Mid-command handling may wait
until the host yields; `--open-view` is for watching from the beginning.
`switch_command` is only for a terminal inside the **same tmux server/socket**;
otherwise open a tab outside that tmux and use `attach_command`.

Default tmux keys: `Ctrl-b d` detaches, `Ctrl-b [` scrolls; `space` pauses one
viewer and `q` stops it. Neither stops the debate in its separate PM. A later
preparation revives owned dead viewers in a detached view; an incomplete current
PM layout stays intact and gets a separate view instead. Detached sessions remain after a run;
their `cleanup_command` removes only that view. Never kill the PM's session.
Full transcripts on disk remain the record beyond limited pane scrollback.

## 4. Dispatch in a SEPARATE long-running tool call

```sh
run-debate.sh --host=claude --context '<exact context_file>' -- -n 4 '<topic>'
```

Codex uses `--host=codex` and absolute script paths. Preserve model/mode/context
engine arguments after `--`. For continuation, use the RUNNER's option:

```sh
run-debate.sh --host=claude --context '<exact context_file>' --continue-from '<physical-debate-dir>' -- -n 2 '<topic>'
```

Never forward `--continue-from` after `--`: the runner rejects it before a
dispatch is marked or a model is called. Contexts are single-dispatch; use a
fresh preparation for another invocation or an authorized authentication retry
(same frozen team/base and engine arguments). Keep the existing one-approved-
attempt Claude login policy; do not change auth, probe raw CLIs, or switch models.

Choose a host timeout/background-and-poll mechanism sufficient for a 3–10 minute
debate. A tool timeout is not debate success. Relay failure and preserve logs.

## 5. Validate results and retain context

Only after dispatch exit 0, in another tool call:

```sh
run-debate.sh --read-receipt --context '<exact context_file>'
```

This verifies the recorded dispatch exit and existing receipt schema/file
checks. Missing status/receipt or any nonzero validation means incomplete.
Read the returned `debate_dir` and its ledger, not stdout or `latest-debate` to
decide which run completed. Never infer a critic completion from filenames.
Private context/receipt artifacts remain until OS temp cleanup for follow-ups.

## Standing instruction: a later “뷰 열어줘”

**Directly call `open-view.sh --context <saved-file>`; do not invoke bootstrap
implicitly and do not run a debate.** If the saved context is `present` or
`manual`, or a
detached view has gone away, prepare with `--view=auto --view-only` using the
saved team/base, then open that new context. If no context remains, prepare the
current workspace view-only. Raw log-directory contexts only offer manual tails.
These paths never call `run-debate.sh` to dispatch, `debate.sh`, or a model.

On a new user turn Claude's skill `allowed-tools` grant has expired. Instructions
remain, but normal host permission checks may require a narrow approval. Do not
promise permission-free opening or install persistent rules. The user may
explicitly invoke `/debate-conductor:bootstrap --open-view` (Codex dollar form)
to load the view-only skill; never make that implicit Skill call yourself.
