#!/usr/bin/env bash
set -euo pipefail

# safe-direct-merge.sh — explicit, gate-checked squash merge for PRs the
# scheduled merge-gatekeeper cannot reach. The script re-reads every mutable
# gate input immediately before the merge and preserves local checkout state.
# Remote branch cleanup is policy-controlled and uses a verified URL plus a
# SHA-guarded ref-deletion CAS when a future policy enables it.

usage() {
  cat <<'USAGE'
usage: safe-direct-merge.sh [--dry-run] [--keep-branch] <pr> [<pr> ...]

Gate-checked squash merge for one or more PRs, for the manual path the
scheduled merge-gatekeeper cannot reach (a PR with no closing issue, or issues
outside the agent lifecycle). Pass PRs in dependency-friendly order: land a
referenced PR before one that references it.

For each PR, verifies (mirroring merge_gate in backlog-policy.json):
  - state OPEN, not draft
  - mergeable true, mergeState CLEAN
  - every required check from backlog-policy.json concluded pass
  - the PR targets the protected base branch and has a trusted head
  - live branch protection matches the policy, including check App IDs
  - no current-head P0/P1 or unknown review finding
  - no unmanaged open PR uses this PR's head branch as its base

Then, per PR:
  - preserves every git worktree and local branch, including dirty, ignored,
    and local-only worktrees
  - squash-merges via `gh pr merge --squash --match-head-commit`, or uses the
    bounded native-stack asynchronous API when GitHub requires it
  - preserves the remote branch when `merge_gate.delete_branch` is false

Options:
  --dry-run          verify and report only; merge nothing
  --keep-branch      preserve the remote head branch after merge; required for
                     an ordinary PR with open dependents

Does NOT touch issue/PR labels, never performs an unguarded force-push, never
requests @codex, never removes worktrees or local branches, and never blocks
on a fresh Automatic review.
USAGE
}

dry_run=false
keep_branch=false
prs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=true; shift ;;
    --keep-branch) keep_branch=true; shift ;;
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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
policy_file="${SAFE_DIRECT_MERGE_POLICY_FILE:-$script_dir/../.agents/workflows/backlog-policy.json}"

if ! policy_required_checks_json="$(jq -ce '
  .merge_gate.required_checks
  | if type == "array" and length > 0
      and all(.[]; type == "string" and length > 0 and . == (gsub("^[[:space:]]+|[[:space:]]+$"; "")))
    then .
    else error("invalid required checks")
    end
' "$policy_file" 2>/dev/null)"; then
  echo "safe-direct-merge.error=invalid-merge-gate-policy" >&2
  exit 2
fi
if ! jq -e 'length == (unique | length)' <<<"$policy_required_checks_json" >/dev/null 2>&1; then
  echo "safe-direct-merge.error=duplicate-required-check-policy" >&2
  exit 2
fi

if ! policy_server_protection_json="$(jq -ce '
  .merge_gate.server_protection
  | select(
      type == "object"
      and (.branch | type == "string" and length > 0)
      and .enforce_admins == true
      and .required_conversation_resolution == true
      and (.required_status_checks | type == "array" and length > 0
        and all(.[];
          type == "object"
          and (.context | type == "string" and length > 0)
          and (.app_id | type == "number" and floor == . and . == 15368)
        ))
      and .strict_status_checks == true
      and .allow_force_pushes == false
      and .allow_deletions == false
    )
' "$policy_file" 2>/dev/null)"; then
  echo "safe-direct-merge.error=invalid-server-protection-policy" >&2
  exit 2
fi

protected_branch="$(jq -er '.branch' <<<"$policy_server_protection_json")"
policy_protected_checks_json="$(jq -c '.required_status_checks' <<<"$policy_server_protection_json")"
if ! jq -e --argjson required "$policy_required_checks_json" '
  . as $configured
  | $required as $expected
  | ([ $configured[].context ] | sort) == ($expected | sort)
  and all($configured[]; .app_id == 15368)
' <<<"$policy_protected_checks_json" >/dev/null 2>&1; then
  echo "safe-direct-merge.error=server-protection-check-mismatch" >&2
  exit 2
fi
if ! jq -e '
  .merge_gate.enabled == true
  and .merge_gate.method == "squash"
  and (.merge_gate.delete_branch | type == "boolean")
' "$policy_file" >/dev/null 2>&1; then
  echo "safe-direct-merge.error=invalid-merge-policy" >&2
  exit 2
fi
policy_delete_branch="$(jq -er '.merge_gate.delete_branch | tostring' "$policy_file")"

required_checks=()
while IFS= read -r required_check; do
  required_checks+=("$required_check")
done < <(jq -r '.[]' <<<"$policy_required_checks_json")

server_protection_reason="server-protection-invalid"
verify_server_protection() {
  local repository="$1" protection
  protection="$(gh api "repos/${repository}/branches/${protected_branch}/protection" 2>/dev/null || true)"
  if ! printf '%s' "$protection" | jq -e --argjson required "$policy_protected_checks_json" '
    type == "object"
    and (.enforce_admins | type == "object" and .enabled == true)
    and (.required_conversation_resolution | type == "object" and .enabled == true)
    and (.required_status_checks | type == "object")
    and (.required_status_checks.strict == true)
    and (.required_status_checks.checks | type == "array" and length > 0
      and all(.[];
        type == "object"
        and (.context | type == "string" and length > 0)
        and (.app_id | type == "number" and floor == . and . == 15368)
      ))
    and (.allow_force_pushes | type == "object" and .enabled == false)
    and (.allow_deletions | type == "object" and .enabled == false)
    and (([ .required_status_checks.checks[] | {context,app_id} ] | sort_by(.context))
      == ([ $required[] | {context,app_id} ] | sort_by(.context)))
  ' >/dev/null 2>&1; then
    server_protection_reason="server-protection-invalid"
    return 1
  fi
  server_protection_reason="ok"
  return 0
}

max_review_thread_pages=100
max_async_merge_polls="${SAFE_DIRECT_MERGE_ASYNC_MAX_POLLS:-30}"
async_merge_poll_interval_seconds="${SAFE_DIRECT_MERGE_ASYNC_POLL_INTERVAL_SECONDS:-1}"
if [[ ! "$max_async_merge_polls" =~ ^[1-9][0-9]*$ ]] \
  || [ "$max_async_merge_polls" -gt 100 ] \
  || [[ ! "$async_merge_poll_interval_seconds" =~ ^[0-9]+$ ]] \
  || [ "$async_merge_poll_interval_seconds" -gt 60 ]; then
  echo "safe-direct-merge.error=invalid-async-poll-settings" >&2
  exit 2
fi

native_stack_merge_error='part of a stack and must be merged using the asynchronous merge REST API'
async_merge_api_version='2026-03-10'

validate_branch_name() {
  local branch="$1"
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    && [[ "$branch" != *'..'* ]] \
    && [[ "$branch" != *'@{'* ]] \
    && [[ "$branch" != */ ]] \
    && [[ "$branch" != *. ]] \
    && [[ "$branch" != *'//'* ]]
}

pr_state=""
pr_draft=false
pr_mergeable=""
pr_merge_state=""
pr_branch=""
pr_base_ref=""
pr_head_oid=""
pr_review_decision=""
pr_head_repository=""
pr_is_cross_repository=false
pr_metadata_snapshot=""

read_pr_metadata() {
  local json="$1" context="${2:-PR metadata}"

  if ! jq -e '
    type == "object"
    and (.state | type) == "string"
    and (.isDraft | type) == "boolean"
    and (.mergeable | type) == "string"
    and (.mergeStateStatus | type) == "string"
    and (.headRefName | type) == "string" and (.headRefName | length) > 0
    and (.baseRefName | type) == "string" and (.baseRefName | length) > 0
    and (.headRefOid | type) == "string" and (.headRefOid | test("^[0-9a-fA-F]{40}$"))
    and ((.reviewDecision == null) or (.reviewDecision == "")
      or (.reviewDecision == "APPROVED") or (.reviewDecision == "CHANGES_REQUESTED")
      or (.reviewDecision == "REVIEW_REQUIRED"))
    and (.headRepository | type) == "object"
    and (.headRepository.nameWithOwner | type) == "string"
    and (.headRepository.nameWithOwner | test("^[^/[:space:]]+/[^/[:space:]]+$"))
    and (.isCrossRepository | type) == "boolean"
  ' <<<"$json" >/dev/null 2>&1; then
    echo "skip: invalid ${context} response; merge gate is closed" >&2
    return 1
  fi

  pr_state="$(jq -er '.state' <<<"$json")"
  pr_draft="$(jq -er '.isDraft' <<<"$json")"
  pr_mergeable="$(jq -er '.mergeable' <<<"$json")"
  pr_merge_state="$(jq -er '.mergeStateStatus' <<<"$json")"
  pr_branch="$(jq -er '.headRefName' <<<"$json")"
  pr_base_ref="$(jq -er '.baseRefName' <<<"$json")"
  pr_head_oid="$(jq -er '.headRefOid' <<<"$json")"
  pr_review_decision="$(jq -r '.reviewDecision // ""' <<<"$json")"
  pr_head_repository="$(jq -er '.headRepository.nameWithOwner' <<<"$json")"
  pr_is_cross_repository="$(jq -er '.isCrossRepository' <<<"$json")"
  if ! validate_branch_name "$pr_branch" || ! validate_branch_name "$pr_base_ref"; then
    echo "skip: invalid PR branch name; merge gate is closed" >&2
    return 1
  fi
  pr_metadata_snapshot="$(jq -cS '{
    state,isDraft,mergeable,mergeStateStatus,headRefName,baseRefName,headRefOid,
    reviewDecision,headRepository:.headRepository.nameWithOwner,isCrossRepository
  }' <<<"$json")"
}

checks_gate_snapshot=""
check_failed=()
check_pending=()
check_counts=()

read_required_checks() {
  local checks_json="$1" context="${2:-required check}"
  local check_name bucket count

  if ! jq -e '
    type == "array"
    and all(.[ ]; type == "object" and (.name | type) == "string"
      and (.name | length) > 0 and (.bucket | type) == "string")
  ' <<<"$checks_json" >/dev/null 2>&1; then
    echo "skip: invalid ${context} response; merge gate is closed" >&2
    return 1
  fi

  check_failed=()
  check_pending=()
  check_counts=()
  for check_name in "${required_checks[@]}"; do
    count="$(jq -r --arg name "$check_name" '[.[] | select(.name == $name)] | length' <<<"$checks_json")"
    check_counts+=("$check_name=$count")
    if [ "$count" -eq 0 ]; then
      check_pending+=("$check_name=pending")
      continue
    fi
    while IFS= read -r bucket; do
      case "$bucket" in
        pass) : ;;
        fail|failure|cancelled|timed_out|action_required) check_failed+=("$check_name=$bucket") ;;
        *) check_pending+=("$check_name=${bucket:-pending}") ;;
      esac
    done < <(jq -r --arg name "$check_name" '.[] | select(.name == $name) | .bucket' <<<"$checks_json")
  done
  printf 'checks_gate: required_counts=%s\n' "${check_counts[*]}"
  if [ "${#check_failed[@]}" -gt 0 ]; then
    echo "skip: required checks failed: ${check_failed[*]}"
    return 1
  fi
  if [ "${#check_pending[@]}" -gt 0 ]; then
    echo "skip: required checks pending: ${check_pending[*]} (retry shortly)"
    return 1
  fi
  checks_gate_snapshot="$(jq -cS 'sort_by([.name,.bucket])' <<<"$checks_json")"
}

review_thread_query='
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { body }
          }
        }
      }
    }
  }
}'

review_top_level_query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      reviews(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          body state submittedAt commit { oid } author { login }
        }
      }
    }
  }
}'

review_severity() {
  local body="$1" markers marker priority severity=""
  # Keep this marker grammar in step with collect-merge-gate-evidence.sh.
  # Markdown headings may bold the priority itself (`**P1**:`) or the
  # priority plus its delimiter (`**P1:**`).
  markers="$(printf '%s\n' "$body" | grep -Eo '\*{0,2}P[0-2]\*{0,2}[[:space:]]*[:—–-]|\[P[0-2]\]|\*{0,2}P[0-2]\*{0,2}[[:space:]]+Badge' || true)"
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    priority="$(printf '%s' "$marker" | grep -Eo 'P[0-2]')"
    case "$priority:$severity" in
      P0:*) severity="P0" ;;
      P1:P0) : ;;
      P1:*) severity="P1" ;;
      P2:P0|P2:P1) : ;;
      P2:*) severity="P2" ;;
    esac
  done <<<"$markers"
  printf '%s\n' "${severity:-none}"
}

review_thread_severity() {
  local node="$1" comment body severity highest="" first_severity="" index=0
  while IFS= read -r comment; do
    [ -n "$comment" ] || continue
    body="$(jq -r '.body' <<<"$comment")"
    severity="$(review_severity "$body")"
    if [ "$index" -eq 0 ]; then first_severity="$severity"; fi
    index=$((index + 1))
    case "$severity:$highest" in
      P0:*) highest="P0" ;;
      P1:P0) : ;;
      P1:*) highest="P1" ;;
      P2:P0|P2:P1) : ;;
      P2:*) highest="P2" ;;
      none:*) : ;;
    esac
  done < <(jq -c '.comments.nodes[]' <<<"$node")

  if [ "$first_severity" = "none" ] && { [ "$highest" = "" ] || [ "$highest" = "P2" ]; }; then
    printf 'unknown\n'
  elif [ -z "$highest" ]; then
    printf 'unknown\n'
  else
    printf '%s\n' "$highest"
  fi
}

review_current_unresolved=0
review_current_p0=0
review_current_p1=0
review_current_unknown=0
review_outdated_unresolved=0
review_gate_snapshot=""
review_threads_snapshot_json='[]'
review_top_level_reviews_snapshot_json='[]'

audit_top_level_reviews() {
  local pr="$1" repository="$2" expected_head_oid="$3"
  local owner="${repository%%/*}" name="${repository#*/}"
  local response graphql_head_oid node body severity state submitted_at commit_oid

  if ! response="$(gh api graphql -f "query=${review_top_level_query}" \
    -f "owner=${owner}" -f "name=${name}" -F "number=${pr}")"; then
    echo "skip: top-level review GraphQL query failed; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e '
    type == "object"
    and ((.errors? == null) or ((.errors | type) == "array" and (.errors | length) == 0))
    and (.data | type) == "object"
    and (.data.repository | type) == "object"
    and (.data.repository.pullRequest | type) == "object"
    and (.data.repository.pullRequest.headRefOid | type) == "string"
    and (.data.repository.pullRequest.headRefOid | test("^[0-9a-fA-F]{40}$"))
    and (.data.repository.pullRequest.reviews | type) == "object"
    and (.data.repository.pullRequest.reviews.nodes | type) == "array"
    and (.data.repository.pullRequest.reviews.pageInfo | type) == "object"
    and (.data.repository.pullRequest.reviews.pageInfo.hasNextPage | type) == "boolean"
    and ((.data.repository.pullRequest.reviews.pageInfo.endCursor == null)
      or (.data.repository.pullRequest.reviews.pageInfo.endCursor | type) == "string")
    and all(.data.repository.pullRequest.reviews.nodes[];
      type == "object" and (.body | type) == "string" and (.state | type) == "string"
      and (.state | IN("APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED","PENDING"))
      and ((.submittedAt == null) or (.submittedAt | type) == "string")
      and ((.commit == null) or ((.commit | type) == "object"
        and (.commit.oid | type) == "string" and (.commit.oid | test("^[0-9a-fA-F]{40}$"))))
      and ((.author == null) or ((.author | type) == "object"
        and (.author.login | type) == "string" and (.author.login | length) > 0)))
  ' <<<"$response" >/dev/null 2>&1; then
    echo "skip: invalid top-level review GraphQL response; merge gate is closed" >&2
    return 1
  fi
  graphql_head_oid="$(jq -er '.data.repository.pullRequest.headRefOid' <<<"$response")"
  if [ "$graphql_head_oid" != "$expected_head_oid" ]; then
    echo "skip: top-level review data is for a different PR head; merge gate is closed" >&2
    return 1
  fi
  if [ "$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' <<<"$response")" = "true" ]; then
    echo "skip: top-level review response exceeds the readable page; merge gate is closed" >&2
    return 1
  fi
  review_top_level_reviews_snapshot_json="$(jq -cS '[.data.repository.pullRequest.reviews.nodes[] | {body,state,submittedAt,commit,author}]' <<<"$response")"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    state="$(jq -r '.state' <<<"$node")"
    submitted_at="$(jq -r '.submittedAt // empty' <<<"$node")"
    commit_oid="$(jq -r '.commit.oid // empty' <<<"$node")"
    if [ "$state" = "DISMISSED" ] || [ -z "$submitted_at" ] || [ "$commit_oid" != "$expected_head_oid" ]; then
      continue
    fi
    body="$(jq -r '.body' <<<"$node")"
    severity="$(review_severity "$body")"
    case "$severity" in
      P0) review_current_p0=$((review_current_p0 + 1)) ;;
      P1) review_current_p1=$((review_current_p1 + 1)) ;;
      none)
        case "$state" in
          COMMENTED|CHANGES_REQUESTED)
            review_current_unknown=$((review_current_unknown + 1))
            ;;
        esac
        ;;
    esac
  done < <(jq -c '.data.repository.pullRequest.reviews.nodes[]' <<<"$response")
}

audit_review_threads() {
  local pr="$1" repository="$2" expected_head_oid="$3"
  local owner="${repository%%/*}" name="${repository#*/}"
  local cursor="" previous_cursor="" page=0 response nodes has_next end_cursor
  local node comments_has_next severity graphql_head_oid page_nodes
  local graphql_args

  if [[ ! "$repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    echo "skip: invalid repository identity for GraphQL review gate" >&2
    return 1
  fi
  review_current_unresolved=0
  review_current_p0=0
  review_current_p1=0
  review_current_unknown=0
  review_outdated_unresolved=0
  review_gate_snapshot=""
  review_threads_snapshot_json='[]'
  review_top_level_reviews_snapshot_json='[]'

  while :; do
    page=$((page + 1))
    if [ "$page" -gt "$max_review_thread_pages" ]; then
      echo "skip: review thread GraphQL pagination exceeded ${max_review_thread_pages} pages" >&2
      return 1
    fi
    graphql_args=(api graphql -f "query=${review_thread_query}" -f "owner=${owner}" -f "name=${name}" -F "number=${pr}")
    if [ -n "$cursor" ]; then graphql_args+=(-f "after=${cursor}"); fi
    if ! response="$(gh "${graphql_args[@]}")"; then
      echo "skip: review thread GraphQL query failed; merge gate is closed" >&2
      return 1
    fi
    if ! jq -e '
      type == "object"
      and ((.errors? == null) or ((.errors | type) == "array" and (.errors | length) == 0))
      and (.data.repository.pullRequest | type) == "object"
      and (.data.repository.pullRequest.headRefOid | type) == "string"
      and (.data.repository.pullRequest.headRefOid | test("^[0-9a-fA-F]{40}$"))
      and (.data.repository.pullRequest.reviewThreads | type) == "object"
      and (.data.repository.pullRequest.reviewThreads.nodes | type) == "array"
      and (.data.repository.pullRequest.reviewThreads.pageInfo | type) == "object"
      and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) == "boolean"
      and ((.data.repository.pullRequest.reviewThreads.pageInfo.endCursor == null)
        or (.data.repository.pullRequest.reviewThreads.pageInfo.endCursor | type) == "string")
      and all(.data.repository.pullRequest.reviewThreads.nodes[];
        type == "object" and (.id | type) == "string" and (.id | length) > 0
        and (.isResolved | type) == "boolean" and (.isOutdated | type) == "boolean"
        and (.comments | type) == "object" and (.comments.nodes | type) == "array"
        and (.comments.pageInfo | type) == "object"
        and (.comments.pageInfo.hasNextPage | type) == "boolean"
        and ((.comments.pageInfo.endCursor == null) or (.comments.pageInfo.endCursor | type) == "string")
        and all(.comments.nodes[]; type == "object" and (.body | type) == "string"))
    ' <<<"$response" >/dev/null 2>&1; then
      echo "skip: invalid review thread GraphQL response; merge gate is closed" >&2
      return 1
    fi
    graphql_head_oid="$(jq -er '.data.repository.pullRequest.headRefOid' <<<"$response")"
    if [ "$graphql_head_oid" != "$expected_head_oid" ]; then
      echo "skip: review data is for a different PR head; merge gate is closed" >&2
      return 1
    fi
    nodes="$(jq -c -e '.data.repository.pullRequest.reviewThreads.nodes' <<<"$response")"
    page_nodes="$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | {id,isResolved,isOutdated,comments:[.comments.nodes[].body]}]' <<<"$response")"
    review_threads_snapshot_json="$(jq -c --argjson page "$page_nodes" '. + $page' <<<"$review_threads_snapshot_json")"
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      comments_has_next="$(jq -r '.comments.pageInfo.hasNextPage' <<<"$node")"
      if [ "$comments_has_next" = "true" ]; then
        echo "skip: review thread comments exceed the readable page; merge gate is closed" >&2
        return 1
      fi
      if [ "$(jq -r '.isResolved' <<<"$node")" = "true" ]; then continue; fi
      if [ "$(jq -r '.isOutdated' <<<"$node")" = "true" ]; then
        review_outdated_unresolved=$((review_outdated_unresolved + 1))
        continue
      fi
      review_current_unresolved=$((review_current_unresolved + 1))
      severity="$(review_thread_severity "$node")"
      case "$severity" in
        P0) review_current_p0=$((review_current_p0 + 1)) ;;
        P1) review_current_p1=$((review_current_p1 + 1)) ;;
        unknown) review_current_unknown=$((review_current_unknown + 1)) ;;
        P2) : ;;
        *) echo "skip: invalid review severity; merge gate is closed" >&2; return 1 ;;
      esac
    done < <(jq -c '.[]' <<<"$nodes")
    has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$response")"
    end_cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<<"$response")"
    if [ "$has_next" != "true" ]; then break; fi
    if [ -z "$end_cursor" ] || [ "$end_cursor" = "$cursor" ] || [ "$end_cursor" = "$previous_cursor" ]; then
      echo "skip: review thread GraphQL pagination returned no new cursor; merge gate is closed" >&2
      return 1
    fi
    previous_cursor="$cursor"
    cursor="$end_cursor"
  done
  if ! jq -e '([.[].id] | unique | length) == length' <<<"$review_threads_snapshot_json" >/dev/null 2>&1; then
    echo "skip: review thread GraphQL response repeated a thread id; merge gate is closed" >&2
    return 1
  fi
  if ! audit_top_level_reviews "$pr" "$repository" "$expected_head_oid"; then return 1; fi
  printf 'review_gate: current_unresolved=%s current_p0=%s current_p1=%s current_unknown=%s outdated_unresolved=%s\n' \
    "$review_current_unresolved" "$review_current_p0" "$review_current_p1" "$review_current_unknown" "$review_outdated_unresolved"
  review_gate_snapshot="$(jq -n -cS --arg head "$expected_head_oid" --argjson threads "$review_threads_snapshot_json" --argjson reviews "$review_top_level_reviews_snapshot_json" \
    '{headRefOid:$head,threads:($threads | sort_by(.id)),reviews:$reviews}')"
}

native_stack_query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      stack {
        id number size baseRefName
        entries(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id position
            pullRequest { number state merged headRefName headRefOid baseRefName }
          }
        }
      }
      stackEntry {
        id position
        pullRequest { number state merged headRefName headRefOid baseRefName }
      }
    }
  }
}'

native_stack_present=false
native_stack_bottom=false
native_stack_size=0
native_stack_entry_numbers=""
native_stack_snapshot=""

audit_native_stack() {
  local pr="$1" repository="$2" expected_head_oid="$3"
  local owner="${repository%%/*}" name="${repository#*/}"
  local response graphql_head_oid stack_is_present stack_entry_position stack_open_bottom_position
  local graphql_args=(api graphql -f "query=${native_stack_query}" -f "owner=${owner}" -f "name=${name}" -F "number=${pr}")

  if ! response="$(gh "${graphql_args[@]}")"; then
    echo "skip: native stack GraphQL query failed; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e '
    type == "object"
    and ((.errors? == null) or ((.errors | type) == "array" and (.errors | length) == 0))
    and (.data.repository.pullRequest | type) == "object"
    and (.data.repository.pullRequest.headRefOid | type) == "string"
    and (.data.repository.pullRequest.headRefOid | test("^[0-9a-fA-F]{40}$"))
    and (
      (.data.repository.pullRequest.stack == null and .data.repository.pullRequest.stackEntry == null)
      or (
        (.data.repository.pullRequest.stack | type) == "object"
        and (.data.repository.pullRequest.stack.id | type) == "string"
        and (.data.repository.pullRequest.stack.id | length) > 0
        and (.data.repository.pullRequest.stack.number | type) == "number"
        and (.data.repository.pullRequest.stack.number >= 1)
        and ((.data.repository.pullRequest.stack.number % 1) == 0)
        and (.data.repository.pullRequest.stack.size | type) == "number"
        and (.data.repository.pullRequest.stack.size >= 1)
        and ((.data.repository.pullRequest.stack.size % 1) == 0)
        and (.data.repository.pullRequest.stack.baseRefName | type) == "string"
        and (.data.repository.pullRequest.stack.baseRefName | length) > 0
        and (.data.repository.pullRequest.stack.entries | type) == "object"
        and (.data.repository.pullRequest.stack.entries.nodes | type) == "array"
        and (.data.repository.pullRequest.stack.entries.pageInfo | type) == "object"
        and (.data.repository.pullRequest.stack.entries.pageInfo.hasNextPage | type) == "boolean"
        and ((.data.repository.pullRequest.stack.entries.pageInfo.endCursor == null)
          or (.data.repository.pullRequest.stack.entries.pageInfo.endCursor | type) == "string")
        and all(.data.repository.pullRequest.stack.entries.nodes[];
          type == "object" and (.id | type) == "string" and (.id | length) > 0
          and (.position | type) == "number" and (.position >= 1) and ((.position % 1) == 0)
          and (.pullRequest | type) == "object"
          and (.pullRequest.number | type) == "number"
          and (.pullRequest.number >= 1) and ((.pullRequest.number % 1) == 0)
          and (.pullRequest.state | type) == "string"
          and (.pullRequest.state | IN("OPEN","MERGED"))
          and (.pullRequest.merged | type) == "boolean"
          and ((.pullRequest.state == "MERGED" and .pullRequest.merged == true)
            or (.pullRequest.state == "OPEN" and .pullRequest.merged == false))
          and (.pullRequest.headRefName | type) == "string" and (.pullRequest.headRefName | length) > 0
          and (.pullRequest.headRefOid | type) == "string" and (.pullRequest.headRefOid | test("^[0-9a-fA-F]{40}$"))
          and (.pullRequest.baseRefName | type) == "string" and (.pullRequest.baseRefName | length) > 0)
        and (.data.repository.pullRequest.stackEntry | type) == "object"
        and (.data.repository.pullRequest.stackEntry.id | type) == "string"
        and (.data.repository.pullRequest.stackEntry.id | length) > 0
        and (.data.repository.pullRequest.stackEntry.position | type) == "number"
        and (.data.repository.pullRequest.stackEntry.position >= 1)
        and ((.data.repository.pullRequest.stackEntry.position % 1) == 0)
        and (.data.repository.pullRequest.stackEntry.pullRequest | type) == "object"
        and (.data.repository.pullRequest.stackEntry.pullRequest.number | type) == "number"
        and (.data.repository.pullRequest.stackEntry.pullRequest.number >= 1)
        and ((.data.repository.pullRequest.stackEntry.pullRequest.number % 1) == 0)
        and (.data.repository.pullRequest.stackEntry.pullRequest.state | type) == "string"
        and (.data.repository.pullRequest.stackEntry.pullRequest.state == "OPEN")
        and (.data.repository.pullRequest.stackEntry.pullRequest.merged | type) == "boolean"
        and (.data.repository.pullRequest.stackEntry.pullRequest.merged == false)
        and (.data.repository.pullRequest.stackEntry.pullRequest.headRefName | type) == "string"
        and (.data.repository.pullRequest.stackEntry.pullRequest.headRefName | length) > 0
        and (.data.repository.pullRequest.stackEntry.pullRequest.headRefOid | type) == "string"
        and (.data.repository.pullRequest.stackEntry.pullRequest.headRefOid | test("^[0-9a-fA-F]{40}$"))
        and (.data.repository.pullRequest.stackEntry.pullRequest.baseRefName | type) == "string"
        and (.data.repository.pullRequest.stackEntry.pullRequest.baseRefName | length) > 0
      )
    )
  ' <<<"$response" >/dev/null 2>&1; then
    echo "skip: invalid native stack GraphQL response; merge gate is closed" >&2
    return 1
  fi
  graphql_head_oid="$(jq -er '.data.repository.pullRequest.headRefOid' <<<"$response")"
  if [ "$graphql_head_oid" != "$expected_head_oid" ]; then
    echo "skip: native stack data is for a different PR head; merge gate is closed" >&2
    return 1
  fi

  native_stack_present=false
  native_stack_bottom=false
  native_stack_size=0
  native_stack_entry_numbers=""
  native_stack_snapshot=""
  stack_is_present="$(jq -er '.data.repository.pullRequest.stack != null' <<<"$response")"
  if [ "$stack_is_present" = "false" ]; then
    if ! jq -e '.data.repository.pullRequest.stackEntry == null' <<<"$response" >/dev/null 2>&1; then
      echo "skip: native stack response has an entry without a stack; merge gate is closed" >&2
      return 1
    fi
    native_stack_snapshot="$(jq -cS '.data.repository.pullRequest | {stack,stackEntry}' <<<"$response")"
    printf 'stack_gate: standalone\n'
    return 0
  fi
  if [ "$(jq -er '.data.repository.pullRequest.stack.entries.pageInfo.hasNextPage' <<<"$response")" = "true" ]; then
    echo "skip: native stack entries exceed the readable page; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e --arg expected "$expected_head_oid" --arg pr "$pr" '
    .data.repository.pullRequest as $pull
    | ($pull.stack.entries.nodes) as $entries
    | ($pull.stack.size) as $size
    | ($pull.stackEntry) as $entry
    | ($entries | length) == $size
    and ([ $entries[].position ] | sort) == ([ range(1; ($size + 1)) ])
    and ([ $entries[].id ] | unique | length) == ($entries | length)
    and ([ $entries[].pullRequest.number | tostring ] | unique | length) == ($entries | length)
    and ($entry.position <= $size)
    and (($entry.pullRequest.number | tostring) == $pr)
    and ($entry.pullRequest.state == "OPEN") and ($entry.pullRequest.merged == false)
    and ($entry.pullRequest.headRefOid == $expected)
    and ([ $entries[] | select((.pullRequest.number | tostring) == $pr) ] | length) == 1
    and (([ $entries[] | select((.pullRequest.number | tostring) == $pr) ][0].position) == $entry.position)
  ' <<<"$response" >/dev/null 2>&1; then
    echo "skip: unable to prove native stack entry order or selected PR identity; merge gate is closed" >&2
    return 1
  fi
  native_stack_present=true
  native_stack_size="$(jq -er '.data.repository.pullRequest.stack.size' <<<"$response")"
  stack_entry_position="$(jq -er '.data.repository.pullRequest.stackEntry.position' <<<"$response")"
  stack_open_bottom_position="$(jq -er '[.data.repository.pullRequest.stack.entries.nodes[] | select(.pullRequest.state == "OPEN") | .position] | min' <<<"$response")"
  native_stack_entry_numbers="$(jq -r '.data.repository.pullRequest.stack.entries.nodes[].pullRequest.number' <<<"$response" | sort -n)"
  if [ "$stack_entry_position" -eq "$stack_open_bottom_position" ]; then native_stack_bottom=true; fi
  native_stack_snapshot="$(jq -cS '.data.repository.pullRequest | {stack,stackEntry}' <<<"$response")"
  printf 'stack_gate: native size=%s selected_position=%s open_bottom_position=%s bottom=%s entries=%s\n' \
    "$native_stack_size" "$stack_entry_position" "$stack_open_bottom_position" "$native_stack_bottom" \
    "$(printf '%s' "$native_stack_entry_numbers" | tr '\n' ' ')"
}

find_open_dependent_prs() {
  local branch="$1" prs_json
  local dependent_pr_limit=1000
  if ! prs_json="$(gh pr list --state open --base "$branch" --limit "$dependent_pr_limit" --json number,baseRefName)"; then
    echo "skip: unable to inspect open dependent PRs; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "object" and (.number | type) == "number" and (.baseRefName | type) == "string")' <<<"$prs_json" >/dev/null 2>&1; then
    echo "skip: invalid dependent PR response; merge gate is closed" >&2
    return 1
  fi
  if [ "$(jq -er 'length' <<<"$prs_json")" -ge "$dependent_pr_limit" ]; then
    echo "skip: dependent PR response reached the readable limit; merge gate is closed" >&2
    return 1
  fi
  jq -r --arg branch "$branch" '.[] | select(.baseRefName == $branch) | .number' <<<"$prs_json"
}

recheck_final_gate() {
  local pr="$1" repository="$2" expected_head_oid="$3"
  local expected_metadata_snapshot="$4" expected_checks_snapshot="$5"
  local expected_review_snapshot="$6" expected_stack_snapshot="$7"
  local expected_dependents_snapshot="$8"
  local final_pr_json final_checks_json final_dependents

  if ! final_pr_json="$(gh pr view "$pr" \
    --json state,isDraft,mergeable,mergeStateStatus,headRefName,baseRefName,headRefOid,reviewDecision,headRepository,isCrossRepository)"; then
    echo "skip: unable to re-read PR metadata before merge; merge gate is closed" >&2
    return 1
  fi
  if ! read_pr_metadata "$final_pr_json" "final PR metadata"; then return 1; fi
  if [ "$pr_base_ref" != "$default_branch" ] || [ "$pr_base_ref" != "$protected_branch" ]; then
    echo "skip: final base branch=$pr_base_ref is not the repository default/protected branch; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_is_cross_repository" != "false" ] || [ "$pr_head_repository" != "$repository" ]; then
    echo "skip: final head repository=$pr_head_repository (cross_repository=$pr_is_cross_repository) is not the exact trusted repository $repository; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_metadata_snapshot" != "$expected_metadata_snapshot" ]; then
    echo "skip: PR metadata changed before merge; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_state" != "OPEN" ] || [ "$pr_draft" = "true" ] \
    || [ "$pr_mergeable" != "MERGEABLE" ] || [ "$pr_merge_state" != "CLEAN" ]; then
    echo "skip: final PR state is no longer mergeable; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_head_oid" != "$expected_head_oid" ]; then
    echo "skip: PR head changed before merge; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_review_decision" = "CHANGES_REQUESTED" ]; then
    echo "skip: latest reviewDecision=CHANGES_REQUESTED before merge; merge gate is closed"
    return 1
  fi

  final_checks_json="$(gh pr checks "$pr" --json name,bucket 2>/dev/null || true)"
  if ! read_required_checks "$final_checks_json" "final required check"; then return 1; fi
  if [ "$checks_gate_snapshot" != "$expected_checks_snapshot" ]; then
    echo "skip: required checks changed before merge; merge gate is closed" >&2
    return 1
  fi
  if ! audit_review_threads "$pr" "$repository" "$expected_head_oid"; then return 1; fi
  if [ "$review_gate_snapshot" != "$expected_review_snapshot" ]; then
    echo "skip: review findings changed before merge; merge gate is closed" >&2
    return 1
  fi
  local final_blocking_findings=$((review_current_p0 + review_current_p1 + review_current_unknown))
  if [ "$final_blocking_findings" -gt 0 ]; then
    echo "skip: current-head review findings block merge (p0=$review_current_p0 p1=$review_current_p1 unknown=$review_current_unknown); merge gate is closed"
    return 1
  fi
  if ! audit_native_stack "$pr" "$repository" "$expected_head_oid"; then return 1; fi
  if [ "$native_stack_snapshot" != "$expected_stack_snapshot" ]; then
    echo "skip: native stack state changed before merge; merge gate is closed" >&2
    return 1
  fi
  if [ "$native_stack_present" = "true" ] && [ "$native_stack_bottom" = "false" ]; then
    echo "skip: selected PR is no longer the native stack bottom; merge gate is closed" >&2
    return 1
  fi
  if ! final_dependents="$(find_open_dependent_prs "$pr_branch")"; then return 1; fi
  final_dependents="$(printf '%s\n' "$final_dependents" | sort -n)"
  if [ "$final_dependents" != "$expected_dependents_snapshot" ]; then
    echo "skip: dependent PR set changed before merge; merge gate is closed" >&2
    return 1
  fi
}

verify_sync_post_merge() {
  local pr="$1" expected_head_oid="$2" post_json
  if ! post_json="$(gh pr view "$pr" --json number,state,mergedAt,mergeCommit,headRefOid)"; then
    echo "skip: unable to verify synchronous merge state; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e --arg pr "$pr" --arg expected_head "$expected_head_oid" '
    type == "object"
    and ((.number | type) == "number") and ((.number | tostring) == $pr)
    and (.state == "MERGED") and (.mergedAt | type) == "string" and (.mergedAt | length) > 0
    and (.headRefOid == $expected_head)
    and (.mergeCommit | type) == "object"
    and (.mergeCommit.oid | type) == "string" and (.mergeCommit.oid | test("^[0-9a-fA-F]{40}$"))
  ' <<<"$post_json" >/dev/null 2>&1; then
    echo "skip: synchronous merge did not produce a live MERGED PR state; merge gate is closed" >&2
    return 1
  fi
}

async_response_status=""
async_response_uuid=""
async_response_sha=""
async_merged_sha=""

parse_async_response() {
  local response="$1" phase="$2" expected_head_oid="$3" expected_uuid="${4:-}"
  if ! jq -e '
    type == "object"
    and ((.errors? == null) or ((.errors | type) == "array" and (.errors | length) == 0))
    and (.status | type) == "string" and (.details | type) == "object"
  ' <<<"$response" >/dev/null 2>&1; then
    echo "skip: invalid asynchronous merge ${phase} response; merge gate is closed" >&2
    return 1
  fi
  async_response_status="$(jq -er '.status' <<<"$response")"
  async_response_uuid=""
  async_response_sha=""
  case "$async_response_status" in
    pending)
      if ! jq -e --arg expected "$expected_head_oid" --arg expected_uuid "$expected_uuid" '
        (.details.uuid | type) == "string" and (.details.uuid | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
        and (.details.merge_method == "squash") and (.details.merge_action == "default")
        and (.details.expected_head_sha == $expected)
        and (($expected_uuid == "") or (.details.uuid == $expected_uuid))
      ' <<<"$response" >/dev/null 2>&1; then
        echo "skip: invalid asynchronous merge ${phase} pending details; merge gate is closed" >&2
        return 1
      fi
      async_response_uuid="$(jq -er '.details.uuid' <<<"$response")"
      ;;
    merged)
      if ! jq -e '(.details.sha | type) == "string" and (.details.sha | test("^[0-9a-fA-F]{40}$"))' <<<"$response" >/dev/null 2>&1; then
        echo "skip: invalid asynchronous merge ${phase} merged SHA; merge gate is closed" >&2
        return 1
      fi
      async_response_sha="$(jq -er '.details.sha' <<<"$response")"
      ;;
    failed|enqueued) : ;;
    *) echo "skip: unknown asynchronous merge ${phase} status=$async_response_status; merge gate is closed" >&2; return 1 ;;
  esac
}

verify_async_post_merge() {
  local pr="$1" expected_head_oid="$2" expected_merge_sha="$3" post_json
  if ! post_json="$(gh pr view "$pr" --json number,state,mergedAt,mergeCommit,headRefOid)"; then
    echo "skip: unable to verify asynchronous merge state; merge gate is closed" >&2
    return 1
  fi
  if ! jq -e --arg pr "$pr" --arg expected_head "$expected_head_oid" --arg expected "$expected_merge_sha" '
    type == "object" and ((.number | type) == "number") and ((.number | tostring) == $pr)
    and (.state == "MERGED") and (.mergedAt | type) == "string" and (.mergedAt | length) > 0
    and (.headRefOid == $expected_head) and (.mergeCommit | type) == "object"
    and (.mergeCommit.oid | type) == "string" and (.mergeCommit.oid | test("^[0-9a-fA-F]{40}$"))
    and (.mergeCommit.oid == $expected)
  ' <<<"$post_json" >/dev/null 2>&1; then
    echo "skip: asynchronous merge response did not match the live merged PR state; merge gate is closed" >&2
    return 1
  fi
}

perform_async_stack_merge() {
  local pr="$1" repository="$2" expected_head_oid="$3"
  local api_path="repos/${repository}/pulls/${pr}/merge-async" submit_json poll_json poll_path poll_count=0
  async_merged_sha=""
  if ! submit_json="$(jq -n --arg sha "$expected_head_oid" '{sha:$sha,merge_method:"squash",merge_action:"default"}' \
    | gh api --method PUT "$api_path" -H 'Accept: application/vnd.github+json' \
      -H "X-GitHub-Api-Version: ${async_merge_api_version}" --input -)"; then
    echo "skip: asynchronous stack merge submission failed; merge gate is closed" >&2
    return 1
  fi
  if ! parse_async_response "$submit_json" submission "$expected_head_oid"; then return 1; fi
  case "$async_response_status" in
    merged) async_merged_sha="$async_response_sha" ;;
    pending)
      poll_path="${api_path}/${async_response_uuid}"
      while [ "$poll_count" -lt "$max_async_merge_polls" ]; do
        poll_count=$((poll_count + 1))
        if ! poll_json="$(gh api "$poll_path" -H 'Accept: application/vnd.github+json' -H "X-GitHub-Api-Version: ${async_merge_api_version}")"; then
          echo "skip: asynchronous stack merge poll failed; merge gate is closed" >&2
          return 1
        fi
        if ! parse_async_response "$poll_json" "poll ${poll_count}" "$expected_head_oid" "$async_response_uuid"; then return 1; fi
        case "$async_response_status" in
          pending)
            if [ "$poll_count" -lt "$max_async_merge_polls" ] && [ "$async_merge_poll_interval_seconds" -gt 0 ]; then sleep "$async_merge_poll_interval_seconds"; fi
            ;;
          merged) async_merged_sha="$async_response_sha"; break ;;
          failed|enqueued) echo "skip: asynchronous stack merge ended with status=$async_response_status; merge gate is closed" >&2; return 1 ;;
          *) echo "skip: asynchronous stack merge returned an unusable status; merge gate is closed" >&2; return 1 ;;
        esac
      done
      if [ -z "$async_merged_sha" ]; then
        echo "skip: asynchronous stack merge timed out after ${max_async_merge_polls} polls; merge gate is closed" >&2
        return 1
      fi
      ;;
    failed|enqueued) echo "skip: asynchronous stack merge submission ended with status=$async_response_status; merge gate is closed" >&2; return 1 ;;
    *) echo "skip: asynchronous stack merge did not reach a merged state; merge gate is closed" >&2; return 1 ;;
  esac
  if ! verify_async_post_merge "$pr" "$expected_head_oid" "$async_merged_sha"; then return 1; fi
  printf 'async_merge: status=merged sha=%s polls=%s\n' "$async_merged_sha" "$poll_count"
}

remote_branch_sha=""
read_remote_branch_sha() {
  local repository="$1" branch="$2" response
  if ! response="$(gh api "repos/${repository}/git/ref/heads/${branch}")"; then
    echo "note: unable to read remote branch $branch SHA; preserving the branch" >&2
    return 1
  fi
  if ! jq -e --arg branch "$branch" '
    type == "object" and (.ref == ("refs/heads/" + $branch))
    and (.object | type) == "object" and (.object.type == "commit")
    and (.object.sha | type) == "string" and (.object.sha | test("^[0-9a-fA-F]{40}$"))
  ' <<<"$response" >/dev/null 2>&1; then
    echo "note: invalid remote branch $branch response; preserving the branch" >&2
    return 1
  fi
  remote_branch_sha="$(jq -er '.object.sha' <<<"$response")"
}

normalize_github_repository_name() {
  local repository="$1" owner name
  if [[ ! "$repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then return 1; fi
  if [[ "$repository" == *\?* || "$repository" == *\#* ]]; then return 1; fi
  owner="${repository%%/*}"
  name="${repository#*/}"
  printf '%s/%s\n' "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
}

normalize_github_remote_url() {
  local url="$1" path owner name
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    git@github.com:*) path="${url#git@github.com:}" ;;
    git://github.com/*) path="${url#git://github.com/}" ;;
    *) return 1 ;;
  esac
  if [[ "$path" =~ [[:space:]] ]] || [[ "$path" == *\?* || "$path" == *\#* ]]; then return 1; fi
  path="${path%/}"
  if [[ -z "$path" || "$path" == */ ]]; then return 1; fi
  owner="${path%%/*}"
  name="${path#*/}"
  if [[ -z "$owner" || -z "$name" || "$name" == */* ]]; then return 1; fi
  case "$name" in *.git) name="${name%.git}" ;; esac
  if [ -z "$name" ]; then return 1; fi
  normalize_github_repository_name "$owner/$name"
}

verified_push_url=""
verify_github_push_remote() {
  local repository="$1" remote="$2"
  local expected_repository fetch_url push_url normalized_fetch normalized_push
  local fetch_urls push_urls
  verified_push_url=""
  if ! expected_repository="$(normalize_github_repository_name "$repository")"; then
    echo "note: invalid GitHub repository identity; preserving the remote branch" >&2
    return 1
  fi
  if ! fetch_urls="$(git remote get-url --all "$remote" 2>/dev/null)" \
    || [ -z "$fetch_urls" ] || [[ "$fetch_urls" == *$'\n'* ]]; then
    echo "note: $remote must have exactly one fetch URL; preserving the remote branch" >&2
    return 1
  fi
  if ! push_urls="$(git remote get-url --push --all "$remote" 2>/dev/null)" \
    || [ -z "$push_urls" ] || [[ "$push_urls" == *$'\n'* ]]; then
    echo "note: $remote must have exactly one push URL; preserving the remote branch" >&2
    return 1
  fi
  fetch_url="$fetch_urls"
  push_url="$push_urls"
  if ! normalized_fetch="$(normalize_github_remote_url "$fetch_url")" \
    || ! normalized_push="$(normalize_github_remote_url "$push_url")"; then
    echo "note: $remote URL is not an exact GitHub repository; preserving the remote branch" >&2
    return 1
  fi
  if [ "$normalized_fetch" != "$expected_repository" ] || [ "$normalized_push" != "$expected_repository" ]; then
    echo "note: $remote URLs do not match GitHub repository $repository; preserving the remote branch" >&2
    return 1
  fi
  # Use the exact URL captured during validation. Resolving the mutable remote
  # name again at push time would leave a local-config redirect race.
  verified_push_url="$push_url"
}

remote_branch_cleanup_status="preserved"
attempt_remote_branch_cleanup() {
  local repository="$1" branch="$2" expected_head_oid="$3"
  remote_branch_cleanup_status="preserved"
  if [ "$policy_delete_branch" != "true" ]; then
    echo "preserved remote branch $branch (merge_gate.delete_branch=false)"
    return 0
  fi
  if [ "$keep_branch" = "true" ]; then
    echo "preserved remote branch $branch"
    return 0
  fi
  if [ "$branch" = "$protected_branch" ] || {
    [ -n "$default_branch" ] && [ "$branch" = "$default_branch" ];
  }; then
    echo "note: protected/default branch $branch is never eligible for cleanup; preserving the branch" >&2
    return 0
  fi
  if ! read_remote_branch_sha "$repository" "$branch"; then return 0; fi
  if [ "$remote_branch_sha" != "$expected_head_oid" ]; then
    echo "note: remote SHA changed from $expected_head_oid to $remote_branch_sha for remote branch $branch; preserving the branch" >&2
    return 0
  fi
  if ! verify_github_push_remote "$repository" origin; then return 0; fi
  if git push "--force-with-lease=refs/heads/${branch}:${expected_head_oid}" \
    "$verified_push_url" ":refs/heads/${branch}" 2>/dev/null; then
    remote_branch_cleanup_status="deleted"
    echo "deleted remote branch $branch with SHA-guarded CAS"
  else
    echo "note: remote branch $branch CAS deletion failed; preserving the branch" >&2
  fi
}

merge_one() {
  local pr="$1"
  echo "=== PR #$pr ==="
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    echo "skip: invalid PR number=$pr" >&2
    return 1
  fi

  local pr_json state draft mergeable merge_state branch base_ref head_oid
  if ! pr_json="$(gh pr view "$pr" --json state,isDraft,mergeable,mergeStateStatus,headRefName,baseRefName,headRefOid,reviewDecision,headRepository,isCrossRepository)"; then
    echo "skip: unable to read PR metadata; merge gate is closed" >&2
    return 1
  fi
  if ! read_pr_metadata "$pr_json"; then return 1; fi
  state="$pr_state"
  draft="$pr_draft"
  mergeable="$pr_mergeable"
  merge_state="$pr_merge_state"
  branch="$pr_branch"
  base_ref="$pr_base_ref"
  head_oid="$pr_head_oid"
  local initial_metadata_snapshot="$pr_metadata_snapshot"

  if [ "$state" != "OPEN" ]; then echo "skip: state=$state (not OPEN)"; return 1; fi
  if [ "$draft" = "true" ]; then echo "skip: draft PR"; return 1; fi
  if [ "$mergeable" != "MERGEABLE" ]; then echo "skip: mergeable=$mergeable"; return 1; fi
  if [ "$merge_state" != "CLEAN" ]; then echo "skip: mergeState=$merge_state (resolve conflicts/blocking reviews first)"; return 1; fi
  if [ "$pr_review_decision" = "CHANGES_REQUESTED" ]; then
    echo "skip: latest reviewDecision=CHANGES_REQUESTED; merge gate is closed"
    return 1
  fi
  if [ "$base_ref" != "$protected_branch" ]; then
    echo "skip: base branch=$base_ref is not protected merge branch $protected_branch; merge gate is closed" >&2
    return 1
  fi

  local checks_json
  checks_json="$(gh pr checks "$pr" --json name,bucket 2>/dev/null || true)"
  if ! read_required_checks "$checks_json"; then return 1; fi
  local initial_checks_snapshot="$checks_gate_snapshot"

  local repository repository_json expected_repository
  expected_repository="${GITHUB_REPOSITORY:-}"
  if [ -n "$expected_repository" ] && ! normalize_github_repository_name "$expected_repository" >/dev/null; then
    echo "skip: GITHUB_REPOSITORY is invalid; merge gate is closed" >&2
    return 1
  fi
  if [ -n "$expected_repository" ]; then
    if ! repository_json="$(gh repo view "$expected_repository" --json nameWithOwner,defaultBranchRef)"; then
      echo "skip: unable to resolve repository identity; merge gate is closed" >&2
      return 1
    fi
  elif ! repository_json="$(gh repo view --json nameWithOwner,defaultBranchRef)"; then
    echo "skip: unable to resolve repository identity; merge gate is closed" >&2
    return 1
  fi
  if ! repository="$(jq -er '.nameWithOwner | strings | select(test("^[^/[:space:]]+/[^/[:space:]]+$"))' <<<"$repository_json")" \
    || ! default_branch="$(jq -er '.defaultBranchRef.name | strings | select(length > 0)' <<<"$repository_json")"; then
    echo "skip: repository identity/default branch response is invalid; merge gate is closed" >&2
    return 1
  fi
  if [ -n "$expected_repository" ]; then
    local expected_normalized actual_normalized
    expected_normalized="$(normalize_github_repository_name "$expected_repository")"
    actual_normalized="$(normalize_github_repository_name "$repository")"
    if [ "$actual_normalized" != "$expected_normalized" ]; then
      echo "skip: repository identity=$repository does not match GITHUB_REPOSITORY=$expected_repository; merge gate is closed" >&2
      return 1
    fi
  fi
  if [ "$default_branch" != "$protected_branch" ]; then
    echo "skip: repository default branch=$default_branch does not match protected merge branch $protected_branch; merge gate is closed" >&2
    return 1
  fi
  if ! verify_server_protection "$repository"; then
    echo "skip: live GitHub branch protection is invalid for $protected_branch; merge gate is closed" >&2
    return 1
  fi
  if [ "$pr_is_cross_repository" != "false" ] || [ "$pr_head_repository" != "$repository" ]; then
    echo "skip: head repository=$pr_head_repository (cross_repository=$pr_is_cross_repository) is not the exact trusted repository $repository; merge gate is closed" >&2
    return 1
  fi

  if ! audit_review_threads "$pr" "$repository" "$head_oid"; then return 1; fi
  local initial_review_snapshot="$review_gate_snapshot"
  local blocking_findings=$((review_current_p0 + review_current_p1 + review_current_unknown))
  if [ "$blocking_findings" -gt 0 ]; then
    echo "skip: current-head review findings block merge (p0=$review_current_p0 p1=$review_current_p1 unknown=$review_current_unknown); merge gate is closed"
    return 1
  fi

  if ! audit_native_stack "$pr" "$repository" "$head_oid"; then return 1; fi
  local initial_stack_snapshot="$native_stack_snapshot"
  if [ "$native_stack_present" = "true" ] && [ "$native_stack_bottom" = "false" ]; then
    echo "skip: selected PR is not the native stack bottom; asynchronous stack merge could merge lower PRs" >&2
    return 1
  fi
  local dependent_prs unmanaged_dependent_prs dependent_pr
  if ! dependent_prs="$(find_open_dependent_prs "$branch")"; then return 1; fi
  local initial_dependents_snapshot
  initial_dependents_snapshot="$(printf '%s\n' "$dependent_prs" | sort -n)"
  unmanaged_dependent_prs="$dependent_prs"
  if [ "$native_stack_present" = "true" ]; then
    unmanaged_dependent_prs=""
    while IFS= read -r dependent_pr; do
      [ -n "$dependent_pr" ] || continue
      if ! printf '%s\n' "$native_stack_entry_numbers" | grep -Fxq "$dependent_pr"; then
        unmanaged_dependent_prs+="$dependent_pr"$'\n'
      fi
    done <<<"$dependent_prs"
  fi
  if [ -n "$unmanaged_dependent_prs" ] && [ "$keep_branch" = "false" ]; then
    echo "skip: open dependent PR(s) use base branch $branch: $(printf '%s' "$unmanaged_dependent_prs" | tr '\n' ' '); pass --keep-branch to preserve the branch"
    return 1
  fi
  if [ "$native_stack_present" = "true" ] && [ -n "$dependent_prs" ]; then
    echo "native stack manages dependent PR branch rebase/retarget: $(printf '%s' "$dependent_prs" | tr '\n' ' ')"
  elif [ -n "$dependent_prs" ]; then
    echo "warning: preserving remote branch $branch for dependent PR(s): $(printf '%s' "$dependent_prs" | tr '\n' ' ')"
  fi

  echo "OK: branch=$branch mergeable=$mergeable mergeState=$merge_state checks=green"
  if [ "$dry_run" = "true" ]; then
    if [ "$native_stack_present" = "true" ]; then
      echo "(dry-run) would submit async native-stack squash merge; GitHub controls stack branch rebase/retarget"
    elif [ "$policy_delete_branch" = "false" ] || [ "$keep_branch" = "true" ] || [ "$branch" = "$protected_branch" ] || [ "$branch" = "$default_branch" ]; then
      echo "(dry-run) would squash-merge and preserve branch $branch"
    else
      echo "(dry-run) would squash-merge and delete branch $branch with a verified remote SHA CAS"
    fi
    return 0
  fi

  if ! verify_server_protection "$repository"; then
    echo "skip: live GitHub branch protection changed before merge; merge gate is closed" >&2
    return 1
  fi
  if ! recheck_final_gate "$pr" "$repository" "$head_oid" "$initial_metadata_snapshot" "$initial_checks_snapshot" "$initial_review_snapshot" "$initial_stack_snapshot" "$initial_dependents_snapshot"; then
    return 1
  fi

  local merge_output merge_method=sync
  if merge_output="$(gh pr merge "$pr" --squash --match-head-commit "$head_oid" < /dev/null 2>&1)"; then
    [ -n "$merge_output" ] && printf '%s\n' "$merge_output"
  else
    printf '%s\n' "$merge_output" >&2
    if [[ "$merge_output" != *"$native_stack_merge_error"* ]]; then
      echo "FAIL: gh pr merge returned non-zero"
      return 1
    fi
    if [ "$native_stack_present" != "true" ] || [ "$native_stack_bottom" != "true" ]; then
      echo "FAIL: native stack metadata did not prove a safe bottom; asynchronous fallback is blocked" >&2
      return 1
    fi
    if ! perform_async_stack_merge "$pr" "$repository" "$head_oid"; then return 1; fi
    merge_method=async
  fi
  if [ "$merge_method" = "sync" ] && ! verify_sync_post_merge "$pr" "$head_oid"; then return 1; fi

  local branch_cleanup_status="preserved"
  if [ "$native_stack_present" = "true" ]; then
    echo "preserved native stack branch $branch (GitHub controls automatic rebase/retarget)"
  else
    attempt_remote_branch_cleanup "$repository" "$branch" "$head_oid"
    branch_cleanup_status="$remote_branch_cleanup_status"
  fi
  if [ "$merge_method" = "async" ]; then
    echo "merged #$pr via async stack merge; branch-$branch_cleanup_status"
  else
    echo "merged #$pr; branch-$branch_cleanup_status"
  fi
}

rc=0
for pr in "${prs[@]}"; do
  merge_one "$pr" || rc=1
done

exit "$rc"
