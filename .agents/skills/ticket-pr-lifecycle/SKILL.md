---
name: ticket-pr-lifecycle
description: Execute RPM GitHub issue-to-PR lifecycle work after take-ticket prepares context. Use for intake, issue reading, exploration handoff, draft PR setup, focused implementation, validation, PR checklist updates, and final audit; not for review feedback resolution.
---

# Ticket PR Lifecycle

## Role

Run an RPM ticket from clean intake to ready PR while keeping behavior changes small and auditable. Use `pr-review-resolution` for review feedback.

## Tool Surface

- `scripts/ticket-gen <issue-number-or-url> --format jsonl`
- `scripts/ticket-gen <issue-number-or-url> --format json`
- `bash scripts/check-workflow-intake.sh`
- `bash scripts/check-workflow-final.sh <pr-number>`
- `gh pr create --draft ...`
- `gh pr view <pr> --json ...`
- `gh pr edit <pr> --body-file <file>`
- narrow validation from `AGENTS.md`: `cargo check`, targeted `cargo test`, or `cargo clippy --all-targets --all-features`

## Core Workflow

1. Run or receive the `ticket-gen` JSONL packet.
2. Run intake checks.
3. Use the ticket packet as the issue source of truth.
4. Use `ticket-explorer` for read-only exploration when non-trivial.
5. Classify SPEC impact and fixture needs.
6. Write a short plan: scope, SPEC status, likely files, validation, split decision.
7. Open a draft PR before implementation.
8. Implement one focused behavior change.
9. Run the narrowest relevant validation.
10. Update PR body/checklist when needed. Prefer `pr-checklist-updater` with `gpt-5.4-mini` and `thinking=low`; use `thinking=medium` only for non-mechanical body rewrites.
11. Hand review feedback to `$pr-review-resolution`.
12. Push final commits, mark ready, and run the final audit.

## When To Read References

Read [references/prompts-and-outputs.md](references/prompts-and-outputs.md) when spawning `ticket-explorer`, creating the draft PR body, or returning lifecycle JSONL.

For command output or agent output consumed by another agent, use JSONL. Use Markdown only for human-facing PR bodies or summaries.
