# PR Review Resolution Workflow

## Steps

1. Start after the configured external review system has produced review comments or checks.
2. Collect complete review context:
   `bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl`
3. If there is no actionable review comment, submitted review, or open review thread, return `status:"complete"` with no decisions and no changes.
4. Spawn `pr-review-resolver` using the prompt in `templates.md`.
5. Review resolver output and current diff.
6. If resolver applied `accept-now` fixes, verify validation actually ran or rerun it in the main session.
7. If resolver drafted follow-up issues, decide whether to create them. Use `--create` only when `may_create_followup_issues=true`.
8. Main session replies to or resolves GitHub threads. The resolver should not be the final authority for thread resolution.
9. Collect context again only after the external review system produces new feedback.

## Decision Taxonomy

- `accept-now`: correct, in scope, consistent with active SPEC, and small enough for this PR.
- `reject-invalid`: incorrect, already handled, or based on a false premise.
- `reject-out-of-scope`: plausible but outside this ticket or patch discipline.
- `reject-conflicts-with-spec`: conflicts with active SPEC and this PR is not a contract-change task.
- `defer-contract-change`: conflicts with active SPEC but is a valuable product or contract idea.
- `defer-missing-spec`: valuable but no authoritative SPEC exists to judge it safely.

Only `accept-now` may change code in the current PR.

If validation fails after an accepted change, stop and return a blocked result with the failing command and log summary.
