# RPM Scheduled Workflow Prompts

Use these prompts after the related skills pass once in a normal interactive
task. Local backlog preparation, Cloud execution, Cloud review reconciliation,
and Cloud gated merge are separate workflows.

## Capture An Idea

Invoke from a normal task whenever a new intent or product idea appears:

```text
Use $prepare-backlog in capture mode.

Idea:
<original intent and desired outcome>

Known constraints:
<constraints or "none known">

Create at most one issue after duplicate checking. Preserve my wording outside
the managed research section. Register the issue in Project #7 with the
policy-defined research state.
```

## Local Backlog Research

```text
Use $prepare-backlog in research-cycle mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json. Run the backlog access preflight,
inventory Project #7 locally, and process at most the configured research batch. Gather
current repository, SPEC, ADR, issue, PR, dependency, and necessary primary
external evidence. Update only the managed research section and an allowed
lifecycle label. Treat no-work as success. Do not implement code, create a pull
request, merge, or request Codex review.
```

## Cloud Backlog Executor

Recommended interval: every 2 hours.

```text
Use $take-ticket in scheduled mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json. Use the connected GitHub plugin
and the open issue lifecycle-label queue. Do not require the gh CLI or Project
access. If any open issue is agent:claimed or agent:review-pending,
return no-work without mutation. Otherwise select at most one agent:ready issue
in issue-number ascending order, refetch it, preserve ordinary labels, and
replace agent:ready with agent:claimed. Skip an issue already closed by an open
PR. Execute it in an isolated worktree, complete contract review, tests,
just validate, internal adversarial review, intentional commits, push, and PR
publication. Mark the PR review-ready for repository-configured Codex Automatic
reviews, then transition the linked issue to agent:review-pending. Treat
no-work as a healthy idempotent result. Never merge or request @codex review.
```

## Cloud PR Feedback Reconciler

Recommended interval: every 1 hour. Claude Code routines enforce a one-hour
minimum interval; stagger the three Cloud schedules within the hour so they
serialize through the lifecycle labels.

```text
Use $pr-review-resolution in scheduled mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json. Use the connected GitHub plugin
to select at most one open PR linked to an open agent:review-pending issue,
ordered by issue number. Collect the latest Codex Automatic review and
unresolved review comments. If the review has not arrived, return no-work
without mutation. Classify findings against the issue, owning SPEC, tests, and
repository invariants. Apply only accepted in-scope findings, run focused
validation and the appropriate repository gate, perform internal adversarial
review, and push one intentional commit to the same PR branch. Do not assume
Automatic review reruns after the push. Keep agent:review-pending while
actionable P0/P1 findings remain. Otherwise remove agent:review-pending and any
stale agent:claimed label, preserve ordinary labels, and add
agent:awaiting-merge. Treat no-work as a healthy idempotent result. Never merge
or request @codex review.
```

## Cloud Merge Gatekeeper

Recommended interval: every 1 hour.

```text
Use $merge-gatekeeper in scheduled mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json merge_gate. Use the connected
GitHub plugin to select at most one open agent:awaiting-merge issue in
issue-number ascending order with exactly one open closing PR. Collect required
check conclusions, mergeability, and unresolved P0/P1 review threads, normalize
them, and confirm the decision with scripts/check-merge-gate.py. On a merge
verdict, squash-merge through the GitHub plugin and verify the issue closed. On
checks-pending or an unknown mergeability, return no-work without mutation. On
a blocked verdict, transition the issue from agent:awaiting-merge to
agent:blocked, preserve ordinary labels, and post one comment naming the exact
reason. Treat no-work as a healthy idempotent result. Never bypass required
checks and never request @codex review.
```

## Initial Rollout

1. Run capture manually with one sample idea.
2. Run one research cycle manually and inspect the issue-body diff.
3. Confirm the research cycle promoted one fully refined issue to the ready
   state on its own; intervene only when the readiness verdict is wrong.
4. Run scheduled ticket execution manually and inspect its Draft PR.
5. Configure branch protection on `main`: require the `verify` and `metadata`
   checks and forbid direct pushes, so the merge gate is enforced server-side.
6. Run the merge gatekeeper manually against one awaiting-merge issue and
   inspect the merged result before enabling its schedule.
7. Keep Project capture and research on the authenticated local environment.
8. Enable the three Cloud schedules after one manual executor, reconciler, and
   gatekeeper run.

Keep both policy batch limits at one. Run only one backlog executor at a time;
the active claimed/review-pending guard is the workflow concurrency boundary.
The gatekeeper merges at most one PR per run, so executor, reconciler, and
gatekeeper stay serialized through the lifecycle labels.
