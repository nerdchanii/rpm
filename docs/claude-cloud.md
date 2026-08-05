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

The routines use the gh CLI for issue, label, and PR mutations. Configure the
cloud environment once:

1. Create a fine-grained GitHub PAT scoped to `nerdchanii/rpm` with
   read/write on contents, issues, and pull requests.
2. In the routine's cloud environment settings, add an environment variable
   `GH_TOKEN` with that PAT. The gh CLI picks it up automatically.
3. Set `./scripts/claude-cloud-setup.sh` as the environment setup script. It
   installs gh when missing and reuses `scripts/codex-cloud-setup.sh` for the
   Rust toolchain. The result is cached across runs.
4. Keep the default Trusted network access. If gh calls fail with
   `x-deny-reason: host_not_allowed`, add `api.github.com` to the
   environment's allowed domains.

Every routine prompt begins with `gh auth status` and reports BLOCKED without
mutating anything when authentication is missing, so a misconfigured
environment fails safely.

The setup script runs from the cloned repository, so a fix only takes effect
once it is on the branch the environment checks out. When the cloud image
carries third-party apt repositories that the sandbox network policy blocks,
`apt-get update` exits non-zero even though the Ubuntu indexes were fetched;
the script therefore treats the refresh as best effort and fails only when gh
is still missing afterwards.

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
