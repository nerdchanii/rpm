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
7. Run Codex review loop before merge:
   - add a PR comment: `@codex review`
   - wait 10 seconds, then confirm a Codex reaction/emoji is present on that comment
   - if confirmed, poll roughly every 3 minutes for Codex review output
   - while waiting, emit no filler status text when there is no Codex response yet; keep context clean
   - for each Codex review comment, decide `accept` or `reject` and record a reason
   - if accepted and the review includes a concrete suggestion:
     - apply the suggestion
     - resolve the thread
   - if accepted without a ready suggestion:
     - make the needed change yourself
     - resolve the thread
     - restart the `@codex review` step
   - if rejected:
     - reply with the reason when needed
     - do not resolve unless the review state is clear
   - continue until all review threads are resolved or clearly rejected
8. Finish:
   - update the PR checklist, preferably through a worker subagent
   - push all commits
   - mark completed work ready for review
   - run `bash scripts/check-workflow-final.sh <pr-number>`
   - after the ticket work, answer the user's follow-up interview questions if they ask them
   - use those answers to decide whether a follow-up issue is truly required
   - only open a follow-up issue when all are true:
     - the problem is structural and likely to recur
     - it is not just local permissions, local environment, or agent/operator error
     - an existing open issue will not naturally absorb it
     - leaving it untracked is likely to slow or block future ticket work
   - prefer at most one or two follow-up issues
   - if the user says `ticket loop`, treat the "next task recommendation" as the next `take-ticket` candidate

## Internal Checklist

Use this locally while working; do not paste it into the public PR template unless useful.

```markdown
- [ ] Intake script passed.
- [ ] Explorer returned issue and contract summary.
- [ ] SPEC impact classified.
- [ ] Draft PR opened with kickoff commit.
- [ ] Implementation stayed focused.
- [ ] Relevant validation ran.
- [ ] Codex review loop completed.
- [ ] PR checklist updated.
- [ ] Final audit script passed.
- [ ] PR marked ready for review.
- [ ] Post-ticket interview reviewed for necessary follow-up issues.
```

## Subagent Guidance

- Explorer: issue reading, codebase search, SPEC impact, likely validation. No edits. Prefer a lightweight model such as 5.4-mini.
- PR checklist worker: PR body updates through `gh`. No repository file edits. Prefer a lightweight model.
- Code worker: only for bounded, disjoint file ownership. Tell workers they are not alone in the codebase and must not revert others' edits. Use a stronger model only when the slice needs it.
- Main agent: contract checklist, split decisions, commits, validation, and final state.

## Follow-up Issue Rules

When the user asks retrospective questions after the ticket, treat that interview as part of the ticket loop rather than a separate conversation.

- Mine the interview for repeated friction, structural slowdown, and future blockers.
- Do not open issues for:
  - local permission prompts
  - sandbox or workstation quirks
  - one-off operator mistakes
  - sensitive or security-restricted details better kept out of public issues
- Before opening a new issue, inspect existing open issues and ask whether the problem will likely be solved as a side effect of one of them.
- Open a new issue only for the remaining gaps that are still likely to recur after nearby issues land.
- If no such gap remains, do not open anything.

## Review Loop Notes

- The Codex review loop is merge-gating for this skill.
- `accept` means the review found a real issue and a code or PR state change should follow.
- `reject` means the review is not correct, not applicable, or already covered; always keep a reason.
- After accepted changes, re-run the narrowest relevant validation before restarting review.
- Once all review feedback is resolved or rejected clearly, merge and provide the next task recommendation.
