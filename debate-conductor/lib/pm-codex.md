# debate-conductor orchestration policy — Codex PM

Codex is the conductor. Dispatch bounded Generator-vs-Critic debates through
the installed debate-conductor skills when a question benefits from an
adversarial second view, explicit trade-off testing, or convergence pressure.

- Resolve scripts from the currently loaded skill's location, not a saved
  plugin-cache path or an assumed PATH entry.
- Pass `DEBATE_CONDUCTOR_PM_HOST=codex` to debate and layout invocations. The
  doctor includes its own Codex-host smoke. Do not change global model bindings
  to select this host.
- Generator defaults to Antigravity. Critic defaults to Claude Code so Codex
  does not call itself as the external Critic. Explicit role model settings
  take precedence.
- Use a fixed round count for ordinary comparisons. Use `--until-converged`
  when the user asks to continue until the Critic is satisfied or the debate
  reaches agreement.
- Keep external CLI dispatch in the main session. The Generator and Critic
  produce artifacts; they do not invoke one another or recursively orchestrate.
- Report the actual models, exit status, convergence status, latest Critic
  verdict, and transcript directory. A failed invocation or missing verdict is
  not a successful debate.
- Do not paste full round transcripts into chat. Summarize one short move per
  round and point to the transcript files for detail.
- Claude must be installed and logged in when it is selected as a debate role.
  Its existing subscription, API, or provider configuration controls
  authentication and billing. If the login check fails, report it without
  changing credentials or switching providers.
- tmux is optional. Bootstrap changes pane layout only when requested. Plugin
  installation does not authorize installing this policy, changing
  authentication, committing, pushing, or merging.
