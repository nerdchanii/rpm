---
name: pr-review-resolution
description: Resolve RPM PR review feedback. Use after Codex or human PR comments arrive, or on a scheduled reconciliation run, to collect review context, classify feedback, apply only accepted in-scope fixes, validate, and advance the linked issue.
---

# PR Review Resolution

요구 도구: Agent·Read·Bash·GitHub plugin.

## Role

Own PR review feedback resolution. Keep `take-ticket` thin and keep final decisions in the main session.

## Required Inputs

For an explicit or local/manual run, require a clean JSONL `review_input` event:

- `pr`
- `ticket_scope`
- `spec_status`
- `spec_paths`
- `validation_plan`
- `may_create_followup_issues`

If `may_create_followup_issues` is not exactly `true`, draft follow-up issue bodies only.

For a scheduled run, read `.agents/workflows/backlog-policy.json` and discover
the single review-pending issue and linked open PR through the GitHub plugin.
Use issue-authored scope, the linked PR, and repository evidence as the input;
do not invent missing product intent.

## Core Workflow

1. In scheduled mode, use the GitHub plugin to select at most one open PR linked to an open issue in `agent:review-pending`, ordered by issue number. Return `no-work` when none exists.
2. Use the GitHub plugin to collect the latest Codex review and unresolved review comments. Do not require `gh` in the scheduled Cloud workflow.
3. Return `no-work` without mutation when Codex review has not arrived.
4. Use `pr-review-resolver` to classify actionable feedback.
5. Apply only `accept-now` fixes.
6. Rerun focused validation, the appropriate repository gate, and internal adversarial review after accepted fixes. Do not assume an Automatic review reruns after a push.
7. Draft deferred follow-up issues with `scripts/create-review-followup-issue.sh`; use `--create` only when explicitly allowed.
8. Commit and push accepted fixes to the same PR branch.
9. Keep `agent:review-pending` when actionable P0/P1 findings remain. When no actionable finding remains, remove `agent:review-pending` and `agent:claimed`, add `agent:awaiting-merge`, and preserve all non-lifecycle labels.
10. Never merge or post `@codex review`.

## When To Read References

Read [references/resolution-workflow.md](references/resolution-workflow.md) before spawning `pr-review-resolver` or deciding review classifications.

Read [references/templates.md](references/templates.md) when you need the resolver prompt, output schema, or follow-up issue body template.

## Tool Surface

- GitHub plugin review, thread, issue, label, and PR tools for scheduled Cloud reconciliation
- `bash scripts/collect-pr-review-context.sh <pr> --format jsonl` as a local/manual fallback
- `bash scripts/collect-pr-review-context.sh <pr> --format json` as a local/manual fallback
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> [--label <label>] --format jsonl`
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> [--label <label>] --create --format jsonl`

Use `/tmp/rpm-review-followup-pr<pr>-<slug>.md` for temporary issue body files. Do not commit them.
