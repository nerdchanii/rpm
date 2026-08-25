---
name: safe-direct-merge
description: Read-only gate audit for same-repository PRs the scheduled merge-gatekeeper cannot reach. Direct mutation stays disabled until GitHub can atomically pin both PR head and base.
---

# Safe Direct Merge

요구 도구: Bash·gh·git.

## Role

Read-only audit path for PRs the scheduled merge-gatekeeper queue cannot select:
the PR has no closing issue (e.g. it lands work scoped by an open
milestone-contract issue), or its linked issue is not in `agent:awaiting-merge`.
This skill mirrors the gate's deterministic conditions. It does not mutate a
PR, branch, or worktree. GitHub's direct merge boundary can pin the head SHA
but cannot atomically pin `baseRefName=main`, so non-dry-run fails closed.

## When to use

- The PR has no closing issue (milestone-contract exemption).
- The linked issue is outside the agent lifecycle and the 5-step label
  transition (`untracked→…→awaiting-merge`) is not justified.
- The user needs a non-mutating readiness audit.

Prefer the scheduled `merge-gatekeeper` for PRs already in `agent:awaiting-merge`.

## Workflow

1. Keep the bootstrap wrapper in an operator-owned location outside every PR
   checkout. Pass the clean trusted `main` checkout as an explicit
   wrapper argument. Never read the trust-root path from repository-local Git
   config. The wrapper must validate the canonical absolute path, the
   `nerdchanii/rpm` origin, a clean `main` checkout, the live
   `main` SHA, and the expected launcher blob before reading or
   evaluating any repository bytes:

   ```sh
   # /protected/rpm-safe-direct-merge-bootstrap.sh
   set -euo pipefail
   trusted_input="${1:?trusted main checkout path}"
   pr="${2:?pull request number}"
   expected_repo='nerdchanii/rpm'
   case "$trusted_input" in /*) ;; *) exit 2 ;; esac
   [ -d "$trusted_input" ] && [ ! -L "$trusted_input" ] || exit 2
   trusted_checkout="$(cd "$trusted_input" && pwd -P)"
   [ "$trusted_input" = "$trusted_checkout" ] || exit 2
   [ "$(git -C "$trusted_checkout" rev-parse --show-toplevel)" = "$trusted_checkout" ] || exit 2
   [ "$(git -C "$trusted_checkout" symbolic-ref --short HEAD)" = "main" ] || exit 2
   origin="$(git -C "$trusted_checkout" config --local --get remote.origin.url)"
   origin="${origin%.git}"; origin="${origin#https://github.com/}"
   [ "${origin,,}" = "$expected_repo" ] || exit 2
   [ -z "$(git -C "$trusted_checkout" status --porcelain --untracked-files=all)" ] || exit 2
   trusted_sha="$(gh api -X GET "repos/$expected_repo/commits/main" --jq .sha)"
   [[ "$trusted_sha" =~ ^[[:xdigit:]]{40}$ ]]
   [ "$(git -C "$trusted_checkout" rev-parse HEAD)" = "$trusted_sha" ] || exit 2
   git -C "$trusted_checkout" cat-file -e "${trusted_sha}^{commit}"
   expected_blob="$(git -C "$trusted_checkout" rev-parse \
     "$trusted_sha:scripts/safe-direct-merge.sh")"
   trusted_source="$(git -C "$trusted_checkout" \
     show "$trusted_sha:scripts/safe-direct-merge.sh"; printf .)"
   trusted_source="${trusted_source%.}"
   [ "$(printf '%s' "$trusted_source" | git hash-object --stdin)" = "$expected_blob" ] || exit 2
   (
     cd "$trusted_checkout"
     RPM_SAFE_DIRECT_MERGE_BOOTSTRAPPED=1 \
       RPM_SAFE_DIRECT_MERGE_TRUSTED_CHECKOUT="$trusted_checkout" \
       bash -c "$trusted_source" \
       "$trusted_checkout/scripts/safe-direct-merge.sh" --dry-run "$pr"
   )
   ```

   The wrapper is copied or installed from a verified trusted location. The
   launcher repeats the path, repository, clean-main, live-SHA, and source-hash
   checks. An invalid or changed checkout fails before `bash -c`;
   its `git show` result is never sourced or evaluated.
2. Audit one PR per invocation. Re-launch from the trusted checkout before
   auditing another PR so policy and collector assets are rematerialized from
   the current live `main` revision.
3. Treat any invocation without `--dry-run` as an expected safety blocker.
   Direct merge may be restored only after GitHub provides an atomic expected-base
   condition or an equivalent transactional boundary.
4. Per PR the script verifies the trusted origin and PR URL identify the same
   repository, then pins every GitHub lookup to that repository. It captures
   the head SHA. It verifies OPEN / non-draft, `mergeable` true,
   `mergeState` CLEAN, every check named in the policy
   `merge_gate.required_checks` passes, and no unresolved review threads
   (unless `--allow-findings`). The override never suppresses collection,
   identity, or parsing failures, and GitHub conversation-resolution rules
   still apply. Review lookup and parsing failures block the audit. Dry-run
   performs the worktree safety scan. The script rejects
   cross-repository PRs and dirty worktrees, preserves the primary and current
   checkouts, and blocks when another linked worktree holds the PR branch.
   Immediately before reporting readiness, it re-reads and validates the PR
   identity, state/draft status, base/head, mergeability, and merge state.
   It never removes a worktree or deletes a local or remote branch.
   The clean-main launcher materializes the merge implementation, policy, and
   review collector from one immutable live-main Git commit, verifies the exact
   bytes loaded into memory, removes the temporary paths, and executes only
   those in-memory copies. GitHub branch protection or one active no-bypass ruleset must
   enforce every policy check and review-thread resolution at merge time.
   Missing or ambiguous platform enforcement and merge-queue rules block the
   audit. Verified enforcement still cannot fix the PR base, so it does not
   enable direct mutation.

## Boundaries

- Never merge, push, delete refs, or touch labels through this path.
- Never execute this skill from a PR checkout. Never remove a worktree automatically.
- Never remove a dirty, primary, or current worktree. Never delete a local branch automatically.
- Never use this path for a cross-repository PR.
- Never request `@codex review`; never make merge depend on a fresh Automatic review.
- The scheduled `merge-gatekeeper` remains the sole merge path. This skill is
  advisory until an atomic expected-base boundary exists.
