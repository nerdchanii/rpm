#!/usr/bin/env bash
set -euo pipefail

# safe-direct-merge.sh — gate-checked squash merge for PRs the scheduled
# merge-gatekeeper cannot reach (e.g. a PR with no closing issue, or issues
# outside the agent lifecycle). Verifies the SAME conditions the gate checks
# in .agents/workflows/backlog-policy.json `merge_gate`, refuses to operate on
# a branch held by any worktree, squash-merges, and cleans up branches without
# paying the full pre-push test gate on ref deletions.

usage() {
  cat <<'USAGE'
usage: safe-direct-merge.sh [--dry-run] [--allow-findings] <pr> [<pr> ...]

Gate-checked squash merge for one or more PRs, for the manual path the
scheduled merge-gatekeeper cannot reach (a PR with no closing issue, or issues
outside the agent lifecycle). Pass PRs in dependency-friendly order: land a
referenced PR before one that references it.

For each PR, verifies (mirroring merge_gate in backlog-policy.json):
  - state OPEN, not draft
  - mergeable true, mergeState CLEAN
  - required checks (metadata, verify) concluded pass
  - no unresolved review threads (--allow-findings overrides)

Then, per PR:
  - refuses to continue when any git worktree still holds the PR branch
  - squash-merges via `gh pr merge --squash`
  - deletes the merged remote branch (`git push --delete`, which the local
    pre-push gate skips for ref-deletion-only pushes)
  - deletes the local branch if present

Options:
  --dry-run          verify and report only; merge nothing
  --allow-findings   merge even when unresolved review threads remain

Does NOT touch issue/PR labels, never force-pushes, never requests @codex,
and never blocks on a fresh Automatic review.
USAGE
}

dry_run=false
allow_findings=false
prs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=true; shift ;;
    --allow-findings) allow_findings=true; shift ;;
    --*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) prs+=("$1"); shift ;;
  esac
done

if [ "${#prs[@]}" -eq 0 ]; then
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "safe-direct-merge.error=missing-gh" >&2
  exit 127
fi

required_checks=(metadata verify)

merge_one() {
  local pr="$1"
  echo "=== PR #$pr ==="

  local state draft mergeable merge_state branch
  state="$(gh pr view "$pr" --json state -q .state)"
  draft="$(gh pr view "$pr" --json isDraft -q .isDraft)"
  mergeable="$(gh pr view "$pr" --json mergeable -q .mergeable)"
  merge_state="$(gh pr view "$pr" --json mergeStateStatus -q .mergeStateStatus)"
  branch="$(gh pr view "$pr" --json headRefName -q .headRefName)"

  if [ "$state" != "OPEN" ]; then
    echo "skip: state=$state (not OPEN)"; return 1
  fi
  if [ "$draft" = "true" ]; then
    echo "skip: draft PR"; return 1
  fi
  if [ "$mergeable" != "MERGEABLE" ]; then
    echo "skip: mergeable=$mergeable"; return 1
  fi
  if [ "$merge_state" != "CLEAN" ]; then
    echo "skip: mergeState=$merge_state (resolve conflicts/blocking reviews first)"; return 1
  fi

  # Required checks must be green. gh exits 8 while checks are pending, so
  # capture JSON regardless of exit code and classify each required check.
  local checks_json bucket failed=() pending=()
  checks_json="$(gh pr checks "$pr" --json name,bucket 2>/dev/null || true)"
  printf '%s' "$checks_json" | jq -e . >/dev/null 2>&1 || checks_json='[]'
  for c in "${required_checks[@]}"; do
    bucket="$(printf '%s' "$checks_json" | jq -r --arg n "$c" '.[]? | select(.name==$n) | .bucket // ""' | head -1)"
    case "$bucket" in
      pass) : ;;
      fail|failure|cancelled|timed_out|action_required) failed+=("$c=$bucket") ;;
      *) pending+=("$c=${bucket:-pending}") ;;
    esac
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "skip: required checks failed: ${failed[*]}"; return 1
  fi
  if [ "${#pending[@]}" -gt 0 ]; then
    echo "skip: required checks pending: ${pending[*]} (retry shortly)"; return 1
  fi

  # Best-effort unresolved-thread check (P0/P1 proxy). gh --json reviewThreads
  # support varies by version; degrade gracefully when unavailable.
  if [ "$allow_findings" = "false" ]; then
    local unresolved
    unresolved="$(gh pr view "$pr" --json reviewThreads \
      -q '[.reviewThreads[]? | select(.isResolved != true)] | length' 2>/dev/null || printf '0')"
    if [ "${unresolved:-0}" -gt 0 ]; then
      echo "skip: $unresolved unresolved review thread(s); pass --allow-findings to override"
      return 1
    fi
  fi

  # Never delete or force-remove a worktree. A held branch may contain user
  # changes or belong to another Codex task; the caller must hand it off or
  # clean it explicitly before retrying this merge.
  local wt wt_branch worktree_record
  while IFS= read -r worktree_record; do
    case "$worktree_record" in
      "worktree "*) wt="${worktree_record#worktree }" ;;
      *) continue ;;
    esac
    [ -n "$wt" ] || continue
    wt_branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
    if [ "$wt_branch" = "$branch" ]; then
      echo "skip: branch-held-by-worktree=$wt branch=$branch (handoff or clean it, then retry)"
      return 1
    fi
  done < <(git worktree list --porcelain 2>/dev/null)

  echo "OK: branch=$branch mergeable=$mergeable mergeState=$merge_state checks=green"

  if [ "$dry_run" = "true" ]; then
    echo "(dry-run) would squash-merge and delete branch $branch"
    return 0
  fi

  # Squash merge (non-interactive). No --delete-branch: we clean via ref-delete
  # push so the pre-push test gate is skipped.
  if ! gh pr merge "$pr" --squash < /dev/null; then
    echo "FAIL: gh pr merge returned non-zero"; return 1
  fi

  # Delete the merged remote branch (ref-deletion push skips the local gate).
  if git push origin --delete "$branch" 2>/dev/null; then
    echo "deleted remote branch $branch"
  else
    local repo
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    if [ -n "$repo" ] \
      && gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1; then
      echo "deleted remote branch $branch via API"
    else
      echo "note: remote branch $branch already gone or delete failed (non-fatal)"
    fi
  fi

  # Local branch cleanup.
  git branch -D "$branch" 2>/dev/null || true

  echo "merged #$pr"
}

rc=0
for pr in "${prs[@]}"; do
  merge_one "$pr" || rc=1
done

exit "$rc"
