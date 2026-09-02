---
name: safe-direct-merge
description: Gate-checked squash merge for PRs the scheduled merge-gatekeeper cannot reach (no closing issue, or issues outside the agent lifecycle). Verifies the same gate conditions, preserves local and remote branches under policy, and handles native stack merges safely.
---

# Safe Direct Merge

요구 도구: Bash·gh·git.

## Role

Manual merge path for PRs the scheduled merge-gatekeeper queue cannot select:
the PR has no closing issue (e.g. it lands work scoped by an open
milestone-contract issue), or its linked issue is not in `agent:awaiting-merge`.
This skill mirrors the gate's deterministic conditions, then squash-merges and
preserves local checkout state. It reads policy v4 server-protection checks as
`{context, app_id}` objects and requires App ID `15368` for every required
check. The current policy sets `merge_gate.delete_branch` to `false`, so the
remote head branch is preserved after a verified merge. Native GitHub stacks
use the bounded asynchronous merge API and keep their branch lifecycle under
GitHub's stack rules. This skill does not replace the gatekeeper for normal
lifecycle PRs and has no dependency on the obsolete agent-loop adapter.

## When to use

- The PR has no closing issue (milestone-contract exemption).
- The linked issue is outside the agent lifecycle and the 5-step label
  transition (`untracked→…→awaiting-merge`) is not justified.
- The user has explicitly authorized a direct merge.

Prefer the scheduled `merge-gatekeeper` for PRs already in `agent:awaiting-merge`.

## Workflow

1. Dry-run first to confirm every PR passes the gate:
   `bash scripts/safe-direct-merge.sh --dry-run <pr>...`
2. Pass PRs in dependency-friendly order (land a referenced PR before one that
   references it).
3. Merge: `bash scripts/safe-direct-merge.sh [--keep-branch] <pr>...`
4. Per PR the script verifies: OPEN / non-draft, exact protected base branch,
   trusted same-repository head, `mergeable` true, `mergeState` CLEAN, required
   checks (`metadata`, `verify`) pass, live branch protection with exact
   context/App ID pairs, and no unresolved current-head P0/P1 or unclassified
   review finding. Top-level review bodies are included in this check. Review
   body markers carry no trust; a current-head `COMMENTED` or
   `CHANGES_REQUESTED` review without a recognized P0-P2 classification is an
   unknown finding and blocks merge. It repeats mutable checks before
   merge, including the PR head, required checks, review snapshot, native-stack
   state, dependent PR set, and live branch protection. All local worktrees and
   branches remain untouched. The current `delete_branch=false` policy
   preserves the remote branch after a verified squash merge.

GitHub's required conversation-resolution rule protects the final unresolved
thread race. GitHub has no equivalent atomic rule for a new top-level review
body or a changed PR base branch between the final local read and the merge
mutation. These remain residual risks and must be covered by server-side
required checks before automatic merge is enabled.

## Boundaries

- Never force-push. Never merge a PR that fails the gate. Never touch labels or
  remove worktrees/local branches.
- Never request `@codex review`; never make merge depend on a fresh Automatic review.
- Preserve the remote branch whenever `merge_gate.delete_branch` is `false`.
- This is a deliberate manual bypass; the scheduled `merge-gatekeeper` remains
  the default and sole merge path for lifecycle PRs.
