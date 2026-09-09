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
   to the exact base repository, base ref/SHA, head repository, head ref/SHA,
   and ready-for-review state (`is_draft: false`). Collect every
   required check named in `merge_gate.required_checks` with its status,
   conclusion, selected head SHA, source, and workflow run id. Reject incomplete
   reads and duplicate check names. Collect mergeability and the current-head
   P0/P1 finding disposition independently of the review-thread UI flag. Read
   the base repository's live `delete_branch_on_merge` setting through the
   connected GitHub plugin and require an explicit boolean. If the connector
   cannot expose it, return run-level blocked with
   `repository-setting-unavailable` and make no mutation.
4. Inventory every open PR in the repository with complete pagination. Record
   each PR number, repository, base ref/SHA, and head ref/SHA. If an open PR is
   based on the selected PR head repository and ref, return `retarget-required`
   without merge or branch deletion. Missing, partial, or stale dependent
   inventory is blocked.
5. Normalize the first snapshot into the connector fixture shape and run the
   initial gate with this exact command:
   `python3 scripts/check-merge-gate.py --issues-file /tmp/rpm-merge-gate-issue<n>-initial.json --operation select-merge --gate-phase initial`.
   The verdict must contain `phase: initial` and pass for the selected target.
   This phase records preflight state only; it never creates a merge grant.
6. Refetch the selected head, repository branch-deletion setting, and dependent
   inventory immediately before mutation. Write that complete snapshot to the
   different path `/tmp/rpm-merge-gate-issue<n>-final.json` and run the final
   gate in the same transcript with this exact command:
   `python3 scripts/check-merge-gate.py --issues-file /tmp/rpm-merge-gate-issue<n>-final.json --operation select-merge --gate-phase final`.
   The final verdict must contain `phase: final`, status `merge`, and the same
   repository and PR number as the successful initial verdict. A missing phase,
   a direct final call without the initial call, or a second final evidence path
   is blocked. The top-level tool-policy hook runs the trusted checker again on
   the exact final bytes, binds the final evidence path and regular-file
   identity, and creates one grant only after this final verdict succeeds. It
   also binds the policy/checker/hook SHA-256 values and consumes the grant once.
   Use the verdict's `merge_request` object unchanged as the GitHub plugin
   input, including its mandatory `expected_head_sha`. If the connected merge
   tool cannot send that compare-and-swap field, return blocked with
   `merge-cas-unsupported`. Then squash-merge using the policy method and
   verify the linked issue closed. Preserve the head branch: scheduled branch
   deletion is disabled. The final gate requires both policy
   `delete_branch: false` and live repository
   `delete_branch_on_merge: false`, because the merge request cannot override
   repository-side automatic deletion. Lifecycle labels on the closed issue
   are inert; leave them.
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
- Never omit or change the checker-provided `expected_head_sha` on the merge
  request.
- Never delete a local or remote branch. The committed policy must keep
  `delete_branch` false, and both gate reads must prove live repository
  `delete_branch_on_merge` false; any other value makes the gate block.
- Never use another evidence path after the first final-gate path is recorded;
  multiple paths make the transcript grant ambiguous and blocked. The initial
  and final evidence paths must have the `-initial.json` and `-final.json`
  suffixes respectively. Never change or replace the evidence file or trusted
  merge files after the grant; any byte, inode, metadata, or digest drift
  blocks the call.
- Never edit PR title, body, code, or review threads.
- Never post or request `@codex review`.
- Never reopen, retitle, or rewrite issues; the only issue mutations are the
  blocked transition and its single explanatory comment.

## Tool Surface

- GitHub plugin issue, label, check, review-thread, and PR tools
- `python3 scripts/check-merge-gate.py --issues-file <file>-initial.json --operation select-merge --gate-phase initial`
- `python3 scripts/check-merge-gate.py --issues-file <file>-final.json --operation select-merge --gate-phase final`
- `python3 scripts/check-cloud-queue-contract.py --issues-file <file> --operation transition --issue <n> --from-state awaiting-merge --to-state blocked`

Use `/tmp/rpm-merge-gate-issue<n>-initial.json` for the first normalized
evidence file and `/tmp/rpm-merge-gate-issue<n>-final.json` for the final file.
Do not commit either file.

For a direct `exec_command` gate call, provide the exact repository workdir
with `cmd`; execution overrides such as a custom shell or login mode are
blocked.

When the host exposes GitHub only through `functions.exec`, use one direct
literal call to the connected GitHub merge tool with strict JSON and emit only
the serialized result. Computed tool names and additional statements are
blocked because they cannot be tied mechanically to the checker verdict.
