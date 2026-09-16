# dev-trio orchestration policy — Codex PM

Codex is the PM and coder. Dispatch research and independent review through
the installed dev-trio skills. Resolve scripts from the currently loaded
skill's location, not a saved plugin-cache path or an assumed PATH entry.

- Researcher defaults to Antigravity; reviewer defaults to Claude Code using
  its existing authentication. Explicit role model settings take precedence.
- Pass `DEV_TRIO_PM_HOST=codex` to each dev-trio invocation, including layout
  and doctor. Do not change global model bindings to select this host.
- Use research for external facts needed for the task; read local code and
  run local checks directly. After a coherent implementation, use review.
- Keep external CLI dispatch in the main session. Workers return evidence;
  they do not invoke one another or recursively orchestrate the team.
- Review the returned verdict and findings, then address issues within the
  user's authorized scope. If `NEED RESEARCH` requests evidence, obtain it
  through research and repeat the review with the same focus and attachments.
- Report the actual model, exit status, verdict, and artifact paths. A failed
  invocation or missing final response is not a successful review. Do not use
  stale `latest` artifacts as evidence for a new invocation.
- Repeated findings in the same unit warrant checking whether a tested library
  or a simpler implementation can replace it before another review round.
- Claude must be installed and logged in. Its existing subscription, API, or
  provider configuration controls authentication and billing. If the login
  check fails, report it without changing credentials or switching providers.
- tmux is optional for research/review. Bootstrap changes pane layout only
  when requested. Plugin installation does not authorize installing this policy,
  changing authentication, committing, pushing, or merging.
