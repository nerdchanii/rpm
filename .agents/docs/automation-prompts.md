# RPM Scheduled Workflow Prompts

Use these prompts after both skills pass once in a normal interactive task.
Create the research and execution schedules as separate standalone tasks.

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

## Scheduled Backlog Research

```text
Use $prepare-backlog in research-cycle mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json. Run the backlog access preflight,
inventory Project #7, and process at most the configured research batch. Gather
current repository, SPEC, ADR, issue, PR, dependency, and necessary primary
external evidence. Update only the managed research section and an allowed
lifecycle label. Treat no-work as success. Do not implement code, create a pull
request, merge, or request Codex review.
```

## Scheduled Ticket Execution

```text
Use $take-ticket in scheduled mode for nerdchanii/rpm.

Follow .agents/workflows/backlog-policy.json. Run the intake and backlog access
preflights, claim at most one ready issue, and execute it in an isolated
worktree. Keep follow-up issue creation disabled. Complete the Draft PR
checkpoint, targeted tests, just validate, internal adversarial review,
intentional commits, push, PR body/checklist, ready state, and final workflow
audit. Treat no-work as success. Never merge or request Codex review.
```

## Initial Rollout

1. Run capture manually with one sample idea.
2. Run one research cycle manually and inspect the issue-body diff.
3. Move one fully refined issue to the ready state.
4. Run scheduled ticket execution manually and inspect its Draft PR.
5. Enable recurring research first.
6. Enable recurring execution after the first research runs are stable.

Start with one research run and one execution run per day. Stagger execution
after research, and keep both policy batch limits at one until the run history
is consistently clean.
