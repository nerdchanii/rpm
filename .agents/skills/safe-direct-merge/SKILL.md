---
name: safe-direct-merge
argument-hint: "[--dry-run] [--allow-findings] <pr> ..."
disable-model-invocation: true
description: Gate-checked squash merge for explicitly authorized PRs outside the scheduled lifecycle. Verifies the same gate conditions, refuses branches held by worktrees, merges, and cleans branches.
---

# Safe Direct Merge

요구 도구: Bash·gh·git.

## Role

Manual merge path for PRs the scheduled merge-gatekeeper queue cannot select:
the PR has no closing issue (e.g. it lands work scoped by an open
milestone-contract issue), or its linked issue is not in `agent:awaiting-merge`.
This skill mirrors the gate's deterministic conditions, then squash-merges and
cleans up branches. It does not replace the gatekeeper for normal lifecycle PRs.

## When to use

- The PR has no closing issue (milestone-contract exemption).
- The linked issue is outside the agent lifecycle and the 5-step label
  transition (`untracked→…→awaiting-merge`) is not justified.
- The user has explicitly authorized a direct merge.
- The user has explicitly authorized `--allow-findings` when that override is
  needed.

Prefer the scheduled `merge-gatekeeper` for PRs already in `agent:awaiting-merge`.

## Workflow

1. Dry-run first to confirm every PR passes the gate:
   `bash scripts/safe-direct-merge.sh --dry-run <pr>...`
2. Pass PRs in dependency-friendly order (land a referenced PR before one that
   references it).
3. Merge: `bash scripts/safe-direct-merge.sh [--allow-findings] <pr>...`
4. Per PR the script verifies: OPEN / non-draft, `mergeable` true,
   `mergeState` CLEAN, required checks (`metadata`, `verify`) pass, and no
   unresolved review threads (unless explicitly authorized `--allow-findings`).
   It blocks when any worktree holds the PR branch. The caller must hand off or
   clean that worktree before retrying. After the branch is unheld, it
   squash-merges and deletes the merged remote branch (ref-deletion push,
   which the local pre-push gate skips) and local branch.

## Boundaries

- Never force-push. Never merge a PR that fails the gate. Never touch labels.
- Never delete or force-remove a worktree. A held or dirty worktree is a
  blocker and requires explicit cleanup outside this skill.
- Never request `@codex review`; never make merge depend on a fresh Automatic review.
- This is a deliberate manual bypass; the scheduled `merge-gatekeeper` remains
  the default and sole merge path for lifecycle PRs.
