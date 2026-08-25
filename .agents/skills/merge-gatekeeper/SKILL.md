---
name: merge-gatekeeper
description: Gated scheduled merge for RPM. Selects at most one awaiting-merge issue, verifies the deterministic merge gate, and squash-merges the linked PR or demotes the issue to blocked.
argument-hint: "[scheduled]"
disable-model-invocation: true
---

# Merge Gatekeeper

요구 도구: Read·Bash·GitHub plugin.

## Role

Own the single authorized merge path for the RPM autonomous loop. This skill
runs only as the top-level scheduled Cloud session. RPM subagents remain
merge-forbidden by the tool policy hook; do not delegate the merge decision or
the merge action to any subagent.

The policy gate in `.agents/workflows/backlog-policy.json` under `merge_gate`
is the complete authority for what may merge. The deterministic checker is the
decision procedure; this skill only gathers evidence and applies the checker's
verdict.

## Scheduled Workflow

1. Read `.agents/workflows/backlog-policy.json`. If `merge_gate.enabled` is not
   exactly `true`, return `no-work` without mutation.
2. Use the connected GitHub plugin to inventory open issues carrying the
   `agent:awaiting-merge` label, ordered by issue number ascending. Do not
   require the `gh` CLI. Select at most the gate batch limit.
3. Refetch the selected issue and its closing PRs. Bind one `selected_head_sha`
   to the exact repository, base ref/SHA, and head ref/SHA. Collect every
   required check named in `merge_gate.required_checks` with its conclusion,
   selected head SHA, source, and workflow run id. Reject incomplete reads and
   duplicate check names. Collect mergeability and the current-head P0/P1
   finding disposition independently of the review-thread UI flag.
4. Inventory every open PR in the repository with complete pagination. Record
   each PR number, repository, base ref/SHA, and head ref/SHA. If an open PR is
   based on the selected PR head, return `retarget-required` without merge or
   branch deletion. Missing, partial, or stale dependent inventory is blocked.
5. Normalize that evidence into the connector fixture shape and confirm the
   decision with
   `python3 scripts/check-merge-gate.py --issues-file <normalized-file> --operation select-merge`.
   The script verdict is authoritative; do not merge on your own judgment.
6. On `merge`: refetch the selected head and dependent inventory, normalize
   that final evidence, and run `check-merge-gate.py` again for the exact
   selected head immediately before mutation. Proceed only when the second
   verdict is `merge` and its head matches the checked snapshot. Then
   squash-merge the PR through the GitHub plugin using the policy method,
   delete the branch when the gate configures it, and verify the linked issue
   closed. Lifecycle labels on the closed issue are inert; leave them.
7. On `no-work` (`checks-pending`, `mergeability-unknown`,
   `no-awaiting-merge-candidate`, `merge-gate-disabled`): report and make no
   mutation. `no-work` is a healthy idempotent result.
8. On `blocked` (`checks-failed`, `not-mergeable`, `review-findings-remain`,
   `multiple-lifecycle-labels`, `no-open-closing-pr`,
   `multiple-open-closing-prs`, `retarget-required`, or incomplete evidence):
   verify the label change with
   `python3 scripts/check-cloud-queue-contract.py --issues-file <normalized-file> --operation transition --issue <n> --from-state awaiting-merge --to-state blocked`,
   apply it while preserving ordinary labels, and post exactly one issue
   comment naming the blocked reason and the evidence.

## Boundaries

- At most one merge per run.
- Never bypass, override, or re-run required checks; never force a merge over
  a failed or pending gate.
- Never edit PR title, body, code, or review threads.
- Never post or request `@codex review`.
- Never reopen, retitle, or rewrite issues; the only issue mutations are the
  blocked transition and its single explanatory comment.

## Tool Surface

- GitHub plugin issue, label, check, review-thread, and PR tools
- `python3 scripts/check-merge-gate.py --issues-file <file> --operation select-merge`
- `python3 scripts/check-cloud-queue-contract.py --issues-file <file> --operation transition --issue <n> --from-state awaiting-merge --to-state blocked`

Use `/tmp/rpm-merge-gate-issue<n>.json` for the normalized evidence file. Do
not commit it.
