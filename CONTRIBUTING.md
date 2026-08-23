# Contributing

RPM is a package manager prototype. Keep changes small, reviewable, and easy to verify.

## Issues

Use the closest issue template and include:

- context
- contract or expected behavior
- initial scope
- done criteria
- related work, if any

Issue text explains intent, but it does not override an owning SPEC.

A GitHub issue is the durable handoff for a fresh worker. Keep the current body
self-contained with the goal, scope, non-goals, acceptance criteria,
dependencies, validation plan, and necessary context. Issue #207 remains the
open implementation that will persist and validate the executable-issue
contract and its schema/mutations; current manual guidance does not claim
automatic template enforcement.

When work is discovered during execution or review, record one disposition:
an in-scope fix, a narrowly justified blocker or hotfix, or a durable linked
follow-up issue. Actionable findings cannot remain hidden output or expand an
unrelated PR. Follow-up creation requires policy authorization,
`may_create_followup_issues=true`, a duplicate check, and a bounded writer;
without approval, link an existing issue or post the draft disposition and its
evidence to the source issue or PR as a durable comment. A session-local draft
is only preparation, not a terminal disposition. If the workflow cannot persist
either record, it must stop as blocked and report the missing permission. Issue
#208 owns the discovered-work disposition implementation.

Structured model proposals and bounded deterministic writes have separate
responsibilities. A proposal supplies classification or planning evidence; an
authorized workflow applies only the bounded mutation allowed by its contract.

### Agent-backed backlog

Unrefined product ideas use the Idea issue template and enter GitHub Project #7
through the local backlog-preparation workflow. Cloud scheduled execution uses
open issue lifecycle labels as its queue. The state labels and allowed
transitions are defined in
`.agents/workflows/backlog-policy.json`.

- `agent:research`: evidence, contract impact, scope, or done criteria still need work
- `agent:ready`: the readiness gate passed and scheduled execution may select the issue
- `agent:claimed`: one scheduled execution owns the issue
- `agent:review-pending`: the implementation PR is review-ready and awaits review reconciliation
- `agent:awaiting-merge`: review reconciliation is complete and the issue is eligible for the scheduled merge gatekeeper
- `agent:blocked`: a user, product, permission, or dependency decision is required

Scheduled research and ticket execution process at most the configured batch
size. An issue reaches `agent:ready` only after its owning SPEC impact, scope,
dependencies, observable done criteria, and validation plan are explicit.
Codex is the current primary and default repository operating path. Codex Cloud
scheduled execution and repository-configured Codex Automatic review are current
mechanisms. Shared lifecycle, state, validation, and mutation contracts are
provider-neutral, with provider-specific details kept in adapters, environments,
and role instructions.

Issue #199 owns repository-external Codex Automatic review creation. Lifecycle
ticket execution does not create or request an Automatic review or post `@codex review`;
its arrival is asynchronous evidence, not a synchronous
completion dependency or blocking condition. Review reconciliation returns
`no-work` without mutation when feedback is absent and rechecks on a later
scheduled run. Explicit review-only workflows retain their documented
non-blocking COMMENT review-posting scope. Issue #195 owns the planned
deterministic blocking CI aggregate contract; current `merge_gate.required_checks`
consumes policy `metadata` and `verify` conclusions as individual evidence. The
scheduled `merge-gatekeeper` is the actual merge owner, with issue #202
preserving and organizing that lifecycle ownership.

## Milestones

Use GitHub milestones for milestone-level tracking, not as the detailed source
of truth for scope.

Each active milestone should have one first issue that acts as the milestone
contract issue.

That issue should:

- stay open until the milestone itself is complete
- be labeled so it is distinguishable from implementation issues
- remain pinned while the milestone is active
- hold the current summary of:
  - purpose
  - in scope
  - out of scope
  - owning SPECs and ADRs known so far
  - delivery order or dependency chain
  - exit criteria

If new ADRs or SPECs become relevant during the milestone, update the milestone
contract issue body. Do not rely on comments alone as the current summary.

## Pull Requests

Open PRs with a clear summary, validation notes, and a focused checklist. Keep
implementation and cleanup separate.

PR metadata supports triage and planning. Add a descriptive label such as
`bug`, `documentation`, `enhancement`, `refactor`, `planning`,
`milestone-contract`, or `process:metadata-cleanup` when one clearly applies.
Add `Closes #123` only when the PR should close that exact issue. Descriptive
labels and issue-link hygiene do not determine merge eligibility, and issue
lifecycle labels stay separate from PR classification.

The `metadata` job skips draft PRs and publishes advisory notices from the
pull-request event payload. Missing descriptive labels or closing references
do not fail the job. The merge gate still requires the job to complete so
ready PRs have a current metadata report; `verify` owns code and validation
correctness. Branch protection should require the status checks named in
`.agents/workflows/backlog-policy.json`.

Before marking a PR ready:

- run the narrowest relevant validation
- add a descriptive label or closing issue reference when it improves triage
- update the PR checklist
- push the branch
- list follow-up work instead of expanding scope

## Local Checks

Run the narrowest relevant check first. Before marking a PR ready, make sure the
same baseline Cargo checks that run in CI pass locally:

```sh
cargo fmt --check
cargo check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

Use local scripts when they match the change you are making. CI remains the shared verification point for pull requests.

## Local Git Hooks

The repository includes an opt-in local hook path for fast guardrails before review.
CI remains the source of enforcement.

Install the repo-local hooks with:

```sh
bash scripts/install-git-hooks.sh
```

The installer only points your local clone at `.githooks/` through
`git config --local core.hooksPath .githooks` and marks the hook scripts
executable. It does not change tracked files outside the hook setup.

Default hooks:

- `pre-commit`: `cargo fmt --check`
- `pre-push`: `cargo clippy --quiet --all-targets --all-features -- -D warnings`
- `pre-push`: `cargo test --quiet`

The pre-push checks use Cargo's quiet mode to hide intermediate build progress.
Compiler diagnostics, test failures, summaries, and exit statuses remain visible.
The `just build`, `just check`, `just lint`, `just test`, `just docs`, and
`just validate` recipes follow the same output policy. Agent-asset validation
prints one success summary and expands individual output only when a check fails.

If you need to bypass the local guardrail for a one-off case, use normal Git hook
escape hatches such as `--no-verify`. Do not treat that as a replacement for the
repository validation gate.

## Commits

Use atomic commits:

- one behavior, bug, or mechanical change per commit
- no cleanup bundled with behavior changes
- no file moves bundled with behavior changes
- explicit staging when the worktree contains unrelated files
