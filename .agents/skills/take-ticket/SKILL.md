---
name: take-ticket
description: Explicit or scheduled entry point for claiming and executing one RPM GitHub issue.
argument-hint: "[explicit <issue-number-or-url> | scheduled]"
disable-model-invocation: true
---

# Take Ticket

요구 도구: Agent·Read·Bash·GitHub plugin.

## Role

Act as the explicit user or scheduled entry point for one ticket execution run. Delegate all routing to `rpm_workflow_manager` and preserve final accountability in the main session.

## Modes

### Explicit

Use `explicit <issue-number-or-url>` when the user selects an issue. Supply the exact issue, requested outcome, exclusions, repository, worktree, and authorization flags.

### Scheduled

Use `scheduled` without an issue number. The router reads `.agents/workflows/backlog-policy.json`, claims at most the configured execution batch limit, and executes the single claimed issue.

`no-work` is a healthy terminal result. Report it concisely and make no repository or GitHub mutation.

## Entry Workflow

1. Read `.agents/workflows/backlog-policy.json`.
2. Run `bash scripts/check-workflow-intake.sh`.
3. For scheduled mode, use the connected GitHub plugin to verify repository and issue-label access. Do not require `gh`, `gh auth`, `GH_TOKEN`, or Project access. Project #7 is outside the Cloud execution gate.
4. Check the current branch and preserve unrelated worktree changes.
5. Spawn only `rpm_workflow_manager` with:
   - `workflow=take-ticket`
   - `mode=explicit|scheduled`
   - issue number or URL for explicit mode
   - repository/worktree scope
   - requested outcome and exclusions for explicit mode
   - issue-defined intent and exclusions for scheduled mode
   - `may_create_followup_issues` from policy or explicit user authorization
   - maximum correction loops, normally `2`
6. Wait for its structured result.
7. When it returns a Draft PR checkpoint:
   - inspect the reported contract decision and focused plan;
   - create the Draft PR in the main session;
   - resume the same router with the PR URL.
8. When it returns `status:"complete"`:
   - inspect the final diff and evidence;
   - stage only intended files and create atomic Conventional Commits;
   - push the issue branch;
   - update the PR body with Contract, Changes, Validation, checklist, and `Closes #<issue>`;
   - apply an approved PR label and mark the PR ready so repository-configured Codex Automatic reviews can run;
   - replace the linked issue's `agent:claimed` lifecycle label with `agent:review-pending`, preserving every non-lifecycle label;
   - use the GitHub plugin to verify PR state, body, approved label, closing issue, and the linked issue's `agent:review-pending` state. `bash scripts/check-workflow-final.sh <pr-number>` remains a local/manual fallback.
9. When it returns `status:"no-work"`, finish successfully without retrying in the same run.
10. When it returns `status:"blocked"`, resolve the stated decision or report the blocker. Do not silently substitute a different workflow.

The router owns detailed routing. Do not duplicate its manager or leaf map here.

## Isolation

Use one worktree per concurrently active issue. Sequential scheduled runs may reuse the same worktree after the previous task reaches a clean terminal state.

## Main Session Responsibilities

1. Final scope decisions and split decisions.
2. SPEC classification acceptance.
3. Draft PR creation at the router checkpoint.
4. Whether follow-up issue creation is authorized.
5. Final diff review, commits, pushes, PR state, final workflow audit, and user-facing summary.

Never post, request, or wait for `@codex review`. Repository-configured Codex Automatic reviews start after the PR becomes review-ready. Do not make ticket completion depend on that asynchronous review.
Never merge the pull request.

If the router reports `blocked`, stop guessing. Supply the missing decision or report the blocker.
