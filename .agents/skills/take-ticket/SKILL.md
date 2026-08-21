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

`no-work` is a healthy terminal result. Report it concisely and make no repository or GitHub mutation. Scheduled mode requires `executor=cloud`.

The scheduler must provide stable `run_id`, `event_id`, and `lease_owner`
values in the scheduled payload. Retries of the same delivery reuse all three
values, especially `event_id`; a new delivery receives a new event identifier.

Before the scheduled `agent:ready` to `agent:claimed` transition, validate the
managed execution metadata and run the policy-defined claim contract. The
scheduled caller supplies an `executor`, `run_id`, `event_id`, and `lease_owner`;
the claim mutation persists
the `plan_revision`, `scope_hash`, `executor`, lease, run id, event id, and
idempotency record in the execution marker together with the compare-and-set
label mutation. A stale revision, scope, executor, or expired lease returns
`blocked`.

## Entry Workflow

1. Read `.agents/workflows/backlog-policy.json`.
2. Run `bash scripts/check-workflow-intake.sh`.
3. For scheduled mode, use the connected GitHub plugin to verify repository and issue-label access. Do not require `gh`, `gh auth`, or Project access. Project #7 is outside the Cloud execution gate.
4. Check the current branch and preserve unrelated worktree changes.
5. Spawn only `rpm_workflow_manager` with:
   - `workflow=take-ticket`
   - `mode=explicit|scheduled`
   - issue number or URL for explicit mode
   - repository/worktree scope
   - requested outcome and exclusions for explicit mode
   - issue-defined intent and exclusions for scheduled mode
   - `may_create_followup_issues` from policy or explicit user authorization
   - `executor=cloud` for scheduled mode
   - scheduler-derived `run_id`, `event_id`, and `lease_owner` for scheduled mode
   - maximum correction loops, normally `2`
6. Wait for its structured result.
7. In scheduled mode, a claim result is a persistence checkpoint. Before
   starting the claimed issue, refetch the issue in the main session and run
   `scripts/apply-execution-marker.py` with both the returned marker and its
   `expected_execution_marker`. Before that update, refetch the complete issue
   and require it to remain open with no open closing PR, while its lifecycle
   state, complete label set, and execution marker exactly match the patch's
   `before_state`, `expected_labels`, `before_open`, `expected_closing_prs`, and
   predecessor marker. On any marker, state, label, open-state, or closing-PR
   mismatch, return `no-work` without selecting a replacement. Apply the
   resulting body and labels as one issue update. Verify the lease and idempotency record, then
   resume the same router with
   `claim_checkpoint={persisted:true,verified:true,after_state:"claimed",...}`.
   The router starts per-issue execution only after that checkpoint. A
   compare-and-set mismatch returns `no-work` without selecting a replacement.
8. When it returns a Draft PR checkpoint:
   - inspect the reported contract decision and focused plan;
   - create the Draft PR in the main session;
   - resume the same router with the PR URL.
9. When it returns `status:"complete"`:
   - inspect the final diff and evidence;
   - stage only intended files and create atomic Conventional Commits;
   - push the issue branch;
   - update the PR body with Contract, Changes, Validation, checklist, and `Closes #<issue>`;
   - apply an approved PR label and mark the PR ready so repository-configured Codex Automatic reviews can run;
   - replace the linked issue's `agent:claimed` lifecycle label with `agent:review-pending`, preserving every non-lifecycle label;
   - use the GitHub plugin to verify PR state, body, approved label, closing issue, and the linked issue's `agent:review-pending` state. `bash scripts/check-workflow-final.sh <pr-number>` remains a local/manual fallback.
10. When it returns `status:"no-work"`, finish successfully without retrying in the same run.
11. When it returns `status:"blocked"`, resolve the stated decision or report the blocker. Do not silently substitute a different workflow.

The router owns detailed routing. Do not duplicate its manager or leaf map here.

## Isolation

Use one worktree per concurrently active issue. Sequential scheduled runs may reuse the same worktree after the previous task reaches a clean terminal state.

- The main session records the worktree path, base revision, and branch before the
  router starts a worker.
- A dirty intake or a worktree held by another task is a blocker. Do not copy
  unrelated user changes into an issue worker.
- Workers do not remove, force-remove, or clean worktrees. The main session owns
  handoff and cleanup after the issue reaches a terminal state.

## Main Session Responsibilities

1. Final scope decisions and split decisions.
2. SPEC classification acceptance.
3. Draft PR creation at the router checkpoint.
4. Whether follow-up issue creation is authorized.
5. Final diff review, commits, pushes, PR state, final workflow audit, and user-facing summary.

Never post, request, or wait for `@codex review`. Repository-configured Codex Automatic reviews start after the PR becomes review-ready. Do not make ticket completion depend on that asynchronous review.
Never merge the pull request.

If the router reports `blocked`, stop guessing. Supply the missing decision or report the blocker.
