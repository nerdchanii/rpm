#!/usr/bin/env bash
set -euo pipefail

# safe-direct-merge.sh — gate-checked squash merge for PRs the scheduled
# merge-gatekeeper cannot reach (e.g. a PR with no closing issue, or issues
# outside the agent lifecycle). Verifies the SAME conditions the gate checks
# in .agents/workflows/backlog-policy.json `merge_gate`, clears worktrees that
# would block local branch deletion, squash-merges, and cleans up branches
# without paying the full pre-push test gate on ref deletions.

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
  - every check named in merge_gate.required_checks concluded pass
  - no unresolved review threads (--allow-findings overrides)

Then, per PR:
  - rejects cross-repository PRs
  - rejects dirty git worktrees still holding the PR branch
  - removes clean worktrees still holding the PR branch
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

repo_root="$(git rev-parse --show-toplevel)"
policy_path="${repo_root}/.agents/workflows/backlog-policy.json"
required_checks=()
while IFS= read -r check; do
  [ -n "${check}" ] && required_checks+=("${check}")
done < <(jq -r '.merge_gate.required_checks[]?' "${policy_path}")

if [ "${#required_checks[@]}" -eq 0 ]; then
  echo "safe-direct-merge.error=missing-required-checks" >&2
  exit 2
fi

merge_one() {
  local pr="$1"
  echo "=== PR #$pr ==="

  local state draft mergeable merge_state branch cross_repository
  state="$(gh pr view "$pr" --json state -q .state)"
  draft="$(gh pr view "$pr" --json isDraft -q .isDraft)"
  mergeable="$(gh pr view "$pr" --json mergeable -q .mergeable)"
  merge_state="$(gh pr view "$pr" --json mergeStateStatus -q .mergeStateStatus)"
  branch="$(gh pr view "$pr" --json headRefName -q .headRefName)"
  if ! cross_repository="$(gh pr view "$pr" --json isCrossRepository -q .isCrossRepository)"; then
    echo "skip: unable to determine whether PR is cross-repository"; return 1
  fi

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
  if [ "$cross_repository" != "false" ]; then
    echo "skip: cross-repository PRs are not eligible for safe direct merge"; return 1
  fi

  # Required checks must be green. gh exits 8 while checks are pending, so
  # capture JSON regardless of exit code and classify each required check.
  local checks_json bucket failed=() pending=()
  checks_json="$(gh pr checks "$pr" --json name,bucket 2>/dev/null || true)"
  printf '%s' "$checks_json" | jq -e . >/dev/null 2>&1 || checks_json='[]'
  for c in "${required_checks[@]}"; do
    bucket="$(printf '%s' "$checks_json" | jq -r --arg n "$c" '
      [.[]? | select(.name == $n) | .bucket // ""] as $buckets |
      if ($buckets | length) == 0 then
        "pending"
      elif any($buckets[]; . == "fail" or . == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required") then
        "fail"
      elif all($buckets[]; . == "pass") then
        "pass"
      else
        "pending"
      end
    ')"
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

  # Read the complete paginated review-thread payload through the repository
  # collector. Any lookup or parsing failure is a merge blocker: treating a
  # missing review payload as an empty list would bypass the review gate.
  if [ "$allow_findings" = "false" ]; then
    local collector review_context unresolved
    collector="${repo_root}/scripts/collect-pr-review-context.sh"
    if [ ! -x "$collector" ]; then
      echo "skip: unable to locate review context collector"; return 1
    fi
    if ! review_context="$("$collector" --format json "$pr")"; then
      echo "skip: review context collection failed; refusing to merge"; return 1
    fi
    if ! jq -e 'type == "object" and (.reviewThreads | type == "array")' \
      <<<"$review_context" >/dev/null 2>&1; then
      echo "skip: review context payload is invalid; refusing to merge"; return 1
    fi
    if ! unresolved="$(jq -er '[.reviewThreads[] | select(.isResolved != true)] | length' \
      <<<"$review_context")"; then
      echo "skip: review context reviewThreads could not be parsed; refusing to merge"; return 1
    fi
    if [ "${unresolved:-0}" -gt 0 ]; then
      echo "skip: $unresolved unresolved review thread(s); pass --allow-findings to override"
      return 1
    fi
  fi

  echo "OK: branch=$branch mergeable=$mergeable mergeState=$merge_state checks=green"

  if [ "$dry_run" = "true" ]; then
    echo "(dry-run) would squash-merge and delete branch $branch"
    return 0
  fi

  # Check every matching worktree before removing any of them. A dirty
  # worktree may contain user changes, so it is never deleted implicitly.
  local wt wt_branch wt_status
  local worktrees_to_remove=()
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
    if [ "$wt_branch" = "$branch" ]; then
      if ! wt_status="$(git -C "$wt" status --ignored --porcelain --untracked-files=all 2>/dev/null)"; then
        echo "skip: unable to inspect worktree $wt; refusing to merge"; return 1
      fi
      if [ -n "$wt_status" ]; then
        echo "skip: dirty worktree $wt holds $branch; refusing to remove or merge"; return 1
      fi
      worktrees_to_remove+=("$wt")
    fi
  done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

  for wt in "${worktrees_to_remove[@]}"; do
    echo "removing worktree $wt holding $branch"
    if ! git worktree remove --force "$wt"; then
      echo "FAIL: unable to remove clean worktree $wt"; return 1
    fi
  done

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
