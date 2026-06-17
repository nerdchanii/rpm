---
name: take-ticket
description: Context handoff for RPM GitHub issue-to-PR work. Use when the user says to take a ticket, implement a GitHub issue, run the ticket loop, or coordinate RPM issue work; this skill prepares the shared context packet and delegates execution to ticket-pr-lifecycle, spec-governance, fixture-governance, and pr-review-resolution.
---

# Take Ticket

## Role

Act as the coordinator for RPM ticket work. Keep this skill thin: collect stable context, choose the next specialized skill or agent, and preserve final accountability in the main session.

Do not place detailed implementation, review-resolution, or GitHub mutation procedures here. Delegate those to the owning skills.

## One Command Surface

Start by running:

```sh
scripts/ticket-gen <issue-number-or-url> --format jsonl
```

Pass the generated JSONL ticket packet to specialist skills and agents. Do not ask agents to hand-build `ticket_context.*` fields.

Use JSON only when a tool needs it:

```sh
scripts/ticket-gen <issue-number-or-url> --format json
```

Follow-up issue creation is disabled unless a packet or main-session decision explicitly sets `may_create_followup_issues=true`.

## Delegation Map

- Use `$ticket-pr-lifecycle` for intake checks, issue reading, draft PR setup, implementation discipline, validation, PR checklist updates, and final audit.
- Use `$spec-governance` whenever the ticket may affect CLI, lockfile, manifest, semver, resolver, registry, cache, installer, linker, scripts, diagnostics, or other observable package-manager contracts.
- Use `$fixture-governance` whenever tests need package manifests, lockfiles, registry metadata, install projects, or regression fixtures.
- Use `$pr-review-resolution` for review handling; it should request/watch review with `bash scripts/watch-codex-review.sh <pr-number> --request-review --format jsonl` and collect final context with `bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl`.

## Preferred Agents

- `ticket-explorer`: read-only issue/code/SPEC exploration. Use before implementation when the ticket is non-trivial.
- `pr-review-resolver`: SPEC-aware review feedback classification, accepted fixes, validation, and deferred issue drafts/creation.
- `pr-checklist-updater`: PR body/checklist updates only. No repository file edits.

## Main Session Responsibilities

The main session owns:

1. Final scope decisions and split decisions.
2. SPEC classification acceptance.
3. Whether a subagent may create GitHub follow-up issues.
4. Final diff review, commits, pushes, PR state, and user-facing summary.

If a delegated skill or agent reports `blocked`, stop guessing. Either supply the missing context or report the blocker.
