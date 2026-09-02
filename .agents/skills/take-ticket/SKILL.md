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

`no-work` is a healthy terminal result. Report it concisely and make no repository or GitHub mutation. The policy `blocking_states` list controls whether a new issue run waits. An open `agent:claimed`, `agent:review-pending`, or `agent:awaiting-merge` issue blocks a new ready-issue run while the current issue moves through implementation, review, and merge.

Before the scheduled `agent:ready` to `agent:claimed` transition, validate the
managed execution metadata and run the policy-defined claim contract. Persist
the `plan_revision`, `scope_hash`, `executor`, lease, run id, event id, and
idempotency record with the compare-and-set label mutation. A stale revision,
scope, executor, or expired lease returns `blocked`.

The normalized ready candidate must include the `ready_transition_actor` read
from the GitHub issue timeline. It must match a name in
`trusted_lifecycle_actors.ready`. A missing, malformed, or untrusted actor, or
any other invalid ready record, is `malformed-ready`; the result includes the
issue number and exact reason. Apply one policy-checked `ready` to `blocked`
transition through the GitHub plugin, preserve ordinary labels, refetch, and
then stop the run. Do not select a replacement issue or retry the demotion. A
compare-and-set race returns the observed state and leaves the issue unchanged.

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
   - maximum correction loops from `review_correction.max_attempts` in the policy, normally `5`
6. Wait for its structured result.
   - When the scheduled selector returns `malformed-ready`, perform the single
     `ready` to `blocked` demotion described above and report its verification.
7. When it returns a publication checkpoint:
   - inspect the reported contract decision, focused plan, and
     branch/base evidence;
   - ask `rpm_ticket_publisher` for its read-only issue, branch-name, base, and
     conflicting-PR preflight;
   - require the verified preflight and resume the same router with that
     evidence. No pull request is created before the branch is pushed.
8. When it returns `status:"complete"` in a local/manual run:
   - inspect the final diff and evidence;
   - stage only intended files and create atomic Conventional Commits;
   - push only the validated feature branch with
     `git push https://github.com/nerdchanii/rpm.git HEAD:refs/heads/<safe-head>`;
     the target must use an approved non-protected branch prefix and must match
     the publisher's refetched head branch;
   - call `rpm_ticket_publisher` with the exact pushed head and validation
     evidence to create or adopt the matching Draft PR, verify and update its
     managed body, initialize `agent:correction-0`, mark the PR ready, and
     replace the linked issue's `agent:claimed` lifecycle label with
     `agent:review-pending`;
   - require the publisher's refetch verification for PR state, body,
     correction label, closing issue, and linked issue state.
     `bash scripts/check-workflow-final.sh <pr-number>` remains a
     local/manual fallback.
9. When it returns `status:"complete|no-work|blocked"` in a `codex cloud exec`
   run, do not commit, push, or finalize the PR inside the Cloud container. Ask
   `rpm_cloud_result_writer` to write the exact `.codex-cloud-result.json`
   handoff. The GitHub Actions publisher retrieves the Cloud diff, validates
   it, removes the handoff file, and performs any guarded commit, push, PR
   publication, and lifecycle transition.
10. When it returns `status:"no-work"`, finish successfully without retrying in the same run.
11. When it returns `status:"blocked"`, resolve the stated decision or report the blocker. Do not silently substitute a different workflow.

The router owns detailed routing. Do not duplicate its manager or leaf map here.

Use `python3 scripts/check-cloud-queue-contract.py --issues-json '<normalized-json>' --operation initialize-correction --pr <pr>` in Cloud, or `--issues-file <normalized-fixture>` in local tests, before adding the initial counter label. The inline JSON must be one shell-quoted argument and contain only the normalized fields required by the checker.

## Isolation

Use one worktree for the single active issue pipeline. Sequential scheduled runs may reuse the same worktree after the previous task reaches a clean terminal state.

## Main Session Responsibilities

1. Final scope decisions and split decisions.
2. SPEC classification acceptance.
3. Acceptance of the `rpm_ticket_publisher` read-only publication preflight.
4. Whether follow-up issue creation is authorized.
5. Final diff review, commits, pushes, and publisher result acceptance. The
   publisher owns the allowed PR and issue publication mutations; the main
   session owns final workflow audit and user-facing summary.

Never post, request, or wait for `@codex review`. Repository-configured Codex Automatic reviews start after the PR becomes review-ready. Do not make ticket completion depend on that asynchronous review.
Never merge the pull request.

If the router reports `blocked`, stop guessing. Supply the missing decision or report the blocker.
