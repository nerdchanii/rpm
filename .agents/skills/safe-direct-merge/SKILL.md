---
name: safe-direct-merge
description: Gate-checked squash merge for same-repository PRs the scheduled merge-gatekeeper cannot reach (no closing issue, or issues outside the agent lifecycle). Verifies the same gate conditions, clears only clean blocking worktrees, merges, and cleans branches.
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

Prefer the scheduled `merge-gatekeeper` for PRs already in `agent:awaiting-merge`.

## Workflow

1. Configure an absolute clean `main` checkout outside PR worktrees once in
   repository-local Git config:
   `git config rpm.safeDirectMergeTrustedCheckout /absolute/path/to/main-checkout`.
   Its HEAD must equal live GitHub `main`.
2. Resolve and execute only that configured launcher. Never execute the copy
   in the current PR checkout:
   `trusted_checkout="$(git config --path --get rpm.safeDirectMergeTrustedCheckout)"`
   then
   `bash "$trusted_checkout/scripts/safe-direct-merge.sh" --dry-run <pr>...`.
3. Pass PRs in dependency-friendly order (land a referenced PR before one that
   references it).
4. Merge through the same trusted path:
   `bash "$trusted_checkout/scripts/safe-direct-merge.sh" [--allow-findings] <pr>...`.
5. Per PR the script verifies the trusted origin and PR URL identify the same
   repository, then pins every GitHub lookup to that repository. It captures
   the head SHA and passes it as an API merge pin. It verifies OPEN / non-draft, `mergeable` true,
   `mergeState` CLEAN, every check named in the policy
   `merge_gate.required_checks` passes, and no unresolved review threads
   (unless `--allow-findings`). The override never suppresses collection,
   identity, or parsing failures, and GitHub conversation-resolution rules
   still apply. Review lookup and parsing failures block the
   merge. Dry-run performs the worktree safety scan. The script rejects
   cross-repository PRs and dirty worktrees, preserves the primary and current
   checkouts, and blocks when another linked worktree holds the PR branch.
   It never removes a worktree automatically. After proving the PR reached
   `MERGED`, it deletes the remote branch through a repository-pinned,
   percent-encoded GitHub API endpoint. A checked-out or divergent local branch
   is retained; an unreferenced local ref is deleted only when it still equals
   the captured PR head.
   The clean-main launcher materializes the merge implementation, policy, and
   review collector from one immutable live-main Git commit, verifies the exact
   bytes loaded into memory, removes the temporary paths, and executes only
   those in-memory copies. GitHub branch protection or one active no-bypass ruleset must
   enforce every policy check and review-thread resolution at merge time.
   Missing or ambiguous platform enforcement and merge-queue rules block both
   dry-run and merge.

## Boundaries

- Never force-push. Never merge a PR that fails the gate. Never touch labels.
- Never execute this skill from a PR checkout. Never remove a worktree automatically.
- Never remove a dirty, primary, or current worktree. Never use this path for a cross-repository PR.
- Never request `@codex review`; never make merge depend on a fresh Automatic review.
- This is a deliberate manual bypass; the scheduled `merge-gatekeeper` remains
  the default and sole merge path for lifecycle PRs.
