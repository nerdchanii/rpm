# PR Review Resolution Workflow

## Steps

1. For a scheduled run, use the GitHub plugin to find open issues in `agent:review-pending`, ordered by issue number, and select at most one linked open PR.
2. Return `status:"no-work"` without mutation when there is no candidate or the latest Codex Automatic review has not arrived.
3. Collect the latest Codex review and every unresolved review comment through the GitHub plugin. The local/manual fallback is `bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl`.
4. Spawn `pr-review-resolver` using the prompt in `templates.md`.
5. Review resolver output and current diff.
6. If resolver applied `accept-now` fixes, verify validation actually ran or rerun it in the main session.
7. If resolver drafted follow-up issues, decide whether to create them. Use `--create` only when `may_create_followup_issues=true`.
8. Commit and push accepted fixes to the same PR branch, then run internal adversarial review. Do not assume Automatic review reruns.
9. Keep `agent:review-pending` while actionable P0/P1 findings remain. Otherwise replace it with `agent:awaiting-merge` and remove stale `agent:claimed`, preserving ordinary labels.
10. Never merge, request `@codex review`, or make a new Automatic review a completion dependency.

## Decision Taxonomy

- `accept-now`: correct, in scope, consistent with active SPEC, and small enough for this PR.
- `reject-invalid`: incorrect, already handled, or based on a false premise.
- `reject-out-of-scope`: plausible but outside this ticket or patch discipline.
- `reject-conflicts-with-spec`: conflicts with active SPEC and this PR is not a contract-change task.
- `defer-contract-change`: conflicts with active SPEC but is a valuable product or contract idea.
- `defer-missing-spec`: valuable but no authoritative SPEC exists to judge it safely.

Only `accept-now` may change code in the current PR.

If validation fails after an accepted change, stop and return a blocked result with the failing command and log summary.
