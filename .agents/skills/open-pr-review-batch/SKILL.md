---
name: open-pr-review-batch
description: Post a non-blocking code review on every open PR in parallel. One reviewer agent per PR; multi-lens (correctness, contract, filesystem safety, determinism), confidence-scored, false-positive-filtered, posted as a COMMENT review.
---

# Open PR Review Batch

요구 도구: Agent·Bash·gh·GitHub plugin.

## Role

Review every open PR (or an explicit subset) by spawning one reviewer agent per
PR in parallel. Each review is non-blocking (COMMENT), confidence-scored, and
false-positive-filtered. This complements the existing Codex Automatic review
flow and the `pr-review-resolution` skill; it does not replace either.

## Workflow

1. Inventory open PRs: `gh pr list --state open --json number,title,...`.
   Skip drafts and PRs with nothing to review. Narrow to an explicit subset when
   the user named specific PRs.
2. Spawn ONE background agent per PR in a single message (parallel). Do NOT use
   worktree isolation: reviewers are read-only and share the working tree; the
   only writes are the per-PR review post and distinct temp files.
3. Each agent follows [references/worker-prompt.md](references/worker-prompt.md)
   and the method in [references/review-method.md](references/review-method.md):
   fetch diff + sibling-PR context, review through the AGENTS.md lenses, score
   findings 0–100, keep only ≥80, drop false positives, post exactly one COMMENT
   review, and report `PR: <url>`.
4. Render a status table; update it as completion notifications arrive.

## Boundaries

- Review only. Never edit code, push, merge, or touch labels.
- Post exactly one COMMENT review per PR (never APPROVE / REQUEST_CHANGES).
- Never post or request `@codex review`. Never resolve threads.
- Use the AGENTS.md "Code Review Rules" as the review lens.

## When to read references

- `references/worker-prompt.md` — the exact per-PR reviewer prompt template.
- `references/review-method.md` — lenses, scoring rubric, false-positive list,
  and the COMMENT review body format.
