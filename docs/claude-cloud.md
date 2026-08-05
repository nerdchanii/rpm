# Claude Code cloud routines

The autonomous loop runs on three Claude Code cloud routines. Their durable
prompts live in `.agents/docs/automation-prompts.md`; the deterministic
contracts they follow live in `.agents/workflows/backlog-policy.json` and
`scripts/`.

| Routine | Purpose | Cron fallback (UTC) |
|---|---|---|
| rpm-backlog-executor | Claim one ready issue, implement, publish PR | `12 */2 * * *` |
| rpm-review-reconciler | Apply accepted review findings | `25 * * * *` |
| rpm-merge-gatekeeper | Gated squash merge of awaiting-merge PRs | `45 * * * *` |

Manage them at <https://claude.ai/code/routines>.

## Environment setup

The routines mutate issues, labels, and pull requests through the GitHub MCP
plugin. The sandbox git client reaches GitHub through a proxy that authenticates
git transactions only, so pushes work without configuration while GitHub API
mutations need their own credential. Configure the cloud environment once:

1. Create a fine-grained GitHub PAT scoped to `nerdchanii/rpm` with
   read/write on contents, issues, and pull requests. Keep the expiry short:
   the environment variable field stores values in plain text and shows them to
   everyone who uses that environment.
2. In the routine's cloud environment settings, add an environment variable
   `GITHUB_PERSONAL_ACCESS_TOKEN` with that PAT. The plugin sends it as the
   bearer token for `https://api.githubcopilot.com/mcp/`.
3. Set `./scripts/claude-cloud-setup.sh` as the environment setup script,
   referencing the file rather than pasting its contents, so repository fixes
   reach the environment. It prepares the Rust toolchain through
   `scripts/codex-cloud-setup.sh` and installs the gh CLI as a fallback when
   apt allows it. The result is cached across runs.
4. Keep the default Trusted network access. If plugin or gh calls fail with
   `x-deny-reason: host_not_allowed`, add `api.githubcopilot.com` and
   `api.github.com` to the environment's allowed domains.

`.claude/settings.json` enables `github@claude-plugins-official` and registers
its marketplace, which is how cloud sessions load a plugin without the
interactive `/plugin` installer. Confirm a session picked it up by checking that
`mcp__plugin_github_github__*` tools are available: missing tools mean the
plugin never loaded, while tools that return 401 mean the token is absent or
insufficient.

The setup script runs from the cloned repository, so a fix only takes effect
once it is on the branch the environment checks out. When the cloud image
carries third-party apt repositories that the sandbox network policy blocks,
`apt-get update` exits non-zero even though the Ubuntu indexes were fetched;
the script therefore treats the refresh as best effort.

## Event-driven fires

Cron keeps the loop alive, but `.github/workflows/agent-loop-triggers.yml`
fires the matching routine immediately when the loop advances:

| GitHub event | Guard | Fired routine |
|---|---|---|
| Issue labeled `agent:ready` | — | executor |
| Issue labeled `agent:awaiting-merge` | — | gatekeeper |
| PR review submitted | an open `agent:review-pending` issue exists | reconciler |
| Check suite completed (success) | an open `agent:awaiting-merge` issue exists | gatekeeper |

Routines treat no-work as a healthy result, so duplicate fires are harmless;
the fire endpoint has no idempotency key, and each fire consumes one routine
run from the account's daily allowance.

To enable the fires, add an API trigger to each routine in the web UI
(Edit routine → Add another trigger → API → Generate token) and store the
three tokens as repository secrets:

- `CLAUDE_ROUTINE_EXECUTOR_TOKEN`
- `CLAUDE_ROUTINE_RECONCILER_TOKEN`
- `CLAUDE_ROUTINE_GATEKEEPER_TOKEN`

Until the secrets exist, the workflow routes events but skips the fire step,
and the cron schedules carry the loop alone. Native GitHub triggers on the
routines are not used: they only cover pull-request and release events, which
cannot express the issue-label and check-suite conditions above.
