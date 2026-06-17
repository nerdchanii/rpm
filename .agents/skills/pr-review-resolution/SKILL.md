---
name: pr-review-resolution
description: Resolve RPM PR review feedback. Use after Codex or human PR comments arrive to collect review context, classify feedback, apply only accepted in-scope fixes, validate, and draft/create deferred follow-up issues when explicitly allowed.
---

# PR Review Resolution

## Role

Own PR review feedback resolution. Keep `take-ticket` thin and keep final decisions in the main session.

## Required Inputs

Require a clean JSONL `review_input` event before starting:

- `pr`
- `ticket_scope`
- `spec_status`
- `spec_paths`
- `validation_plan`
- `may_create_followup_issues`

If `may_create_followup_issues` is not exactly `true`, draft follow-up issue bodies only.

## Core Workflow

1. Request or wait for review output with `bash scripts/watch-codex-review.sh <pr> --request-review --format jsonl`.
2. Collect context with `bash scripts/collect-pr-review-context.sh <pr> --format jsonl`.
3. Use `pr-review-resolver` to classify actionable feedback.
4. Apply only `accept-now` fixes.
5. Rerun or verify the delegated validation after accepted fixes.
6. Draft deferred follow-up issues with `scripts/create-review-followup-issue.sh`; use `--create` only when explicitly allowed.
7. Main session owns GitHub thread replies/resolution and final acceptance.

## When To Read References

Read [references/resolution-workflow.md](references/resolution-workflow.md) before spawning `pr-review-resolver` or deciding review classifications.

Read [references/templates.md](references/templates.md) when you need the resolver prompt, output schema, or follow-up issue body template.

## Tool Surface

- `bash scripts/watch-codex-review.sh <pr> --request-review --format jsonl`
- `bash scripts/watch-codex-review.sh <pr> --start-time <iso8601> --format jsonl`
- `bash scripts/collect-pr-review-context.sh <pr> --format jsonl`
- `bash scripts/collect-pr-review-context.sh <pr> --format json`
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> [--label <label>] --format jsonl`
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> [--label <label>] --create --format jsonl`

Use `/tmp/rpm-review-followup-pr<pr>-<slug>.md` for temporary issue body files. Do not commit them.
