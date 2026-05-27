---
name: take-ticket
description: Run the repository's minimal GitHub issue-to-PR workflow. Use when the user says to take a ticket, implement a GitHub issue, create the draft PR first, coordinate subagents, keep an internal checklist, run deterministic intake/final audits, update the PR, and mark completed work ready for review.
---

# Take Ticket

## Overview

Use this workflow for a GitHub issue that should become a focused PR. Keep repository rules in `AGENTS.md`; this skill only describes the active task procedure.

## Workflow

1. Run intake checks:
   - `bash scripts/check-workflow-intake.sh`
   - read the issue
   - inspect the worktree before editing
2. Delegate first exploration to an explorer subagent:
   - ask for exact request, SPEC/contract impact, likely files, and validation
   - do not allow file edits
   - use a lightweight model when available
3. Main agent owns the contract checklist:
   - classify SPEC impact
   - write a short plan
   - split work if it crosses repository limits
4. Open the PR before implementation:
   - create a branch
   - create an empty kickoff commit
   - push the branch
   - open a draft PR with contract, plan, validation, and `Closes #<issue>`
5. Implement surgically:
   - one purpose per patch
   - no cleanup bundled with behavior changes
   - use worker subagents only for bounded, disjoint ownership
6. Validate:
   - run the narrowest relevant command from `AGENTS.md`
   - report warnings separately from failures
7. Finish:
   - update the PR checklist, preferably through a worker subagent
   - push all commits
   - mark completed work ready for review
   - run `bash scripts/check-workflow-final.sh <pr-number>`

## Internal Checklist

Use this locally while working; do not paste it into the public PR template unless useful.

```markdown
- [ ] Intake script passed.
- [ ] Explorer returned issue and contract summary.
- [ ] SPEC impact classified.
- [ ] Draft PR opened with kickoff commit.
- [ ] Implementation stayed focused.
- [ ] Relevant validation ran.
- [ ] PR checklist updated.
- [ ] Final audit script passed.
- [ ] PR marked ready for review.
```

## Subagent Guidance

- Explorer: issue reading, codebase search, SPEC impact, likely validation. No edits. Prefer a lightweight model such as 5.4-mini.
- PR checklist worker: PR body updates through `gh`. No repository file edits. Prefer a lightweight model.
- Code worker: only for bounded, disjoint file ownership. Tell workers they are not alone in the codebase and must not revert others' edits. Use a stronger model only when the slice needs it.
- Main agent: contract checklist, split decisions, commits, validation, and final state.
