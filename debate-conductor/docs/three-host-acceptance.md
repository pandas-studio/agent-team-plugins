# Three-host PM acceptance

The engine and skills support Claude, Codex and Antigravity as the active PM.
Each host has a separate skill tree; dispatch explicitly selects `--host`.
Ordinary debates default to four rounds. Continuation keeps its saved model
pair and rotation, with two additional rounds by default.

| PM | Default Generator | Default Critic | Optional policy target |
| --- | --- | --- | --- |
| Claude | agy | codex | CLAUDE.md |
| Codex | agy | claude | AGENTS.md |
| Antigravity | claude | codex | GEMINI.md |

Explicit role settings retain their existing precedence. Antigravity chooses
Claude as critic when the generator is explicitly Codex. Invalid pairs are
rejected. Policy installation is an explicit separate request, not part of
plugin installation.

## Recorded checks (2026-10-27)

- Real Claude-host four-round debate, live Ghostty output and final verdict:
  confirmed complete by the user on the preceding release.
- Official installed Codex plugin 0.5.39: a fresh real Codex PM loaded the
  installed skill, prepared manual viewing, dispatched four rounds without an
  explicit user count, and successfully read the validated receipt. Generator
  and Critic were recording fixtures. Ledger order was gen/crit/gen/crit and
  the receipt named round 4 as the latest completed critic.
- Antigravity 0.5.40 candidate: installation and plugin validation found all
  four agy-specific skills with no findings. Engine fixtures cover four-round
  dispatch, receipt validation, saved-pair continuation across hosts, explicit
  role selection and auth failure before debate creation. The doctor checks
  the default Claude/Codex pair.
- A fresh real Antigravity PM attempt stopped at Antigravity's own login
  requirement and exited 1 before loading/executing the debate. No role calls
  or receipt were produced. Native PM orchestration and interactive command
  approval remain unverified until the user authenticates Antigravity.

These fixture checks establish orchestration, not provider answer quality.
An agy exit code of zero alone is insufficient: command approval can be
soft-denied in print mode. Require successful dispatch, receipt validation,
and successful round-end ledger entries before claiming completion.

## Host behavior and evidence

The installed Codex CLI accepts `owner/repo --ref main` for marketplace add.
Changing a registered source first requires marketplace remove, which retains
plugin activation entries. Refreshing the catalog can automatically refresh
other enabled plugins too; inspect all installed versions before and after.
This is a shared-catalog operation, not a per-plugin version pin.

Antigravity's CLI supports local plugin installation and slash conversion of
skills. Its published skill frontmatter lists name and description; we do not
promise a host-enforced explicit-only guard. See the official
[plugins](https://antigravity.google/docs/plugins?tab=cli) and
[skills](https://antigravity.google/docs/skills/) references.

Antigravity loads AGENTS.md and GEMINI.md project rules, so the Codex and agy
policies identify their active host. See the official
[rules](https://antigravity.google/docs/rules/) reference.

The terminal sandbox is configurable and is off by default; auto mode enables
it. Public documentation does not establish Claude Keychain access inside
that sandbox. An unverified Claude login therefore stops the agy skill and
asks the user to check in their own terminal; it does not fabricate a Codex
approval parameter or change authentication. See the official
[sandbox](https://antigravity.google/docs/sandbox/) and
[headless permissions](https://antigravity.google/docs/cli/headless/#permissions-in-headless-mode)
references.
