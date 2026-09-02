# PR Review Resolution Workflow

## Steps

1. For a scheduled run, use the GitHub plugin to find open issues in `agent:review-pending`, ordered by issue number, and select at most one linked open PR.
2. Return `status:"no-work"` without mutation when there is no candidate or the latest Codex Automatic review has not arrived.
3. Collect the latest Codex review and every unresolved review comment through the GitHub plugin. The local/manual fallback is `bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl`.
4. Spawn `pr-review-resolver` using the prompt in `templates.md`.
5. Review resolver output and current diff.
6. Before any `accept-now` file edit, run the deterministic correction operation against normalized current PR labels. Ask `rpm_review_reconciler` to reserve the returned next counter with its compare-and-set label update and refetch it. A missing, conflicting, or exhausted counter moves the linked issue to `agent:blocked` with one reason comment and leaves the PR head unchanged. The comment contains `<!-- rpm-agent-correction-block: source=pr:<positive integer>; reason=<reason-code>; counter=<agent:correction-N> -->`; read existing comments first and do not post the same marker twice.
7. If resolver applied `accept-now` fixes, verify validation actually ran or rerun it in the main session.
8. Commit accepted fixes, push with the exact repository URL and explicit safe PR-head destination, then run internal adversarial review. Refetch the exact PR head and validation evidence after the push. Ask `rpm_review_reconciler` to call `resolve_review_thread(thread_id)` only for a thread fixed by that pushed change and verify it. Keep rejected, deferred, or unfixed threads unresolved. The `pr-review-resolver` leaf never resolves threads. Missing connector access, permission, head, or evidence keeps the issue in `agent:review-pending` or returns `blocked`. The merge gate rereads `isResolved` immediately before its decision.
9. If resolver drafted follow-up issues, deduplicate by source and canonical lowercase `sha256:<64 hex>` fingerprint and enforce the five-per-source policy limit. A trusted source is exactly `pr:<positive integer>` or `issue:<positive integer>`. The body starts with source and fingerprint markers, in that order. The fingerprint hashes final-title UTF-8 bytes, one NUL byte, and the canonical body UTF-8 bytes after removing the fingerprint marker. Scheduled Cloud and local helper paths use the same calculation, return `drafted` for preview and `created` after a successful create, and apply `process:agent-followup`. Scheduled Cloud runs use the GitHub plugin. Local/manual runs use `scripts/create-review-followup-issue.sh`; pass `--create` only when `may_create_followup_issues=true`.
10. Keep `agent:review-pending` while actionable P0/P1 findings remain. Otherwise ask `rpm_review_reconciler` to replace it with `agent:awaiting-merge` and remove stale `agent:claimed`, preserving ordinary labels and verifying the refetch.
11. Never merge, request `@codex review`, or make a new Automatic review a completion dependency.

## Decision Taxonomy

- `accept-now`: correct, in scope, consistent with active SPEC, and small enough for this PR.
- `reject-invalid`: incorrect, already handled, or based on a false premise.
- `reject-out-of-scope`: plausible but outside this ticket or patch discipline.
- `reject-conflicts-with-spec`: conflicts with active SPEC and this PR is not a contract-change task.
- `defer-contract-change`: conflicts with active SPEC but is a valuable product or contract idea.
- `defer-missing-spec`: valuable but no authoritative SPEC exists to judge it safely.

Only `accept-now` may change code in the current PR.

Cross-PR dependency awareness: the collected context may include
`pr_sibling_pr` events describing other open PRs (number, title, branch,
changed files, body). When a finding asserts something is "missing" or
"not yet implemented", check whether a sibling PR introduces it. If so,
prefer a forward-looking `accept-now` reword that stays accurate both before
and after that sibling lands (e.g. "tracked by #N, landing in #<sibling>");
otherwise defer. This avoids classifying a real dependency as a defect.

If validation fails after an accepted change, stop and return a blocked result with the failing command and log summary.
