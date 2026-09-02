#!/usr/bin/env bash
set -euo pipefail

# Collect the complete, read-only input used by the deterministic merge gate.
# The output deliberately uses the same normalized shape as
# scripts/check-merge-gate.py.  This script never calls a GitHub write API.

readonly max_rest_pages="${RPM_MERGE_GATE_MAX_REST_PAGES:-100}"
readonly max_graphql_pages="${RPM_MERGE_GATE_MAX_GRAPHQL_PAGES:-100}"
readonly max_issues="${RPM_MERGE_GATE_MAX_ISSUES:-1000}"
readonly max_review_threads="${RPM_MERGE_GATE_MAX_REVIEW_THREADS:-10000}"
readonly max_reviews="${RPM_MERGE_GATE_MAX_REVIEWS:-10000}"
readonly max_closing_references="${RPM_MERGE_GATE_MAX_CLOSING_REFERENCES:-10000}"

usage() {
  cat <<'USAGE'
usage: collect-merge-gate-evidence.sh [options]

Collect one complete, canonical merge-gate snapshot using read-only GitHub
queries.  The lowest open agent:awaiting-merge issue is selected.  Optional
expected values make a later publisher fail closed when the selected item or
its exact refs changed.

Options:
  --repo OWNER/REPO             Repository (default: GITHUB_REPOSITORY)
  --policy FILE                 Backlog policy (default: repository policy)
  --output FILE                 Write canonical JSON to FILE instead of stdout
  --expected-issue NUMBER       Require the lowest selected issue to match
  --expected-pr NUMBER          Require its unique closing PR to match
  --expected-base-sha SHA       Require the PR base SHA to match
  --expected-head-sha SHA       Require the PR head SHA to match
  -h, --help                    Show this help
USAGE
}

error() {
  printf 'collect_merge_gate_evidence.error=%s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'collect_merge_gate_evidence.error=%s\n' "$1" >&2
  exit 2
}

repo="${GITHUB_REPOSITORY:-}"
policy=""
output=""
expected_issue=""
expected_pr=""
expected_base_sha=""
expected_head_sha=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || usage_error 'missing-repo-value'
      repo="$2"
      shift 2
      ;;
    --repo=*) repo="${1#--repo=}"; shift ;;
    --policy)
      [ "$#" -ge 2 ] || usage_error 'missing-policy-value'
      policy="$2"
      shift 2
      ;;
    --policy=*) policy="${1#--policy=}"; shift ;;
    --output)
      [ "$#" -ge 2 ] || usage_error 'missing-output-value'
      output="$2"
      shift 2
      ;;
    --output=*) output="${1#--output=}"; shift ;;
    --expected-issue|--issue)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-issue-value'
      expected_issue="$2"
      shift 2
      ;;
    --expected-issue=*|--issue=*) expected_issue="${1#*=}"; shift ;;
    --expected-pr|--pr)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-pr-value'
      expected_pr="$2"
      shift 2
      ;;
    --expected-pr=*|--pr=*) expected_pr="${1#*=}"; shift ;;
    --expected-base-sha|--base-sha)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-base-sha-value'
      expected_base_sha="$2"
      shift 2
      ;;
    --expected-base-sha=*|--base-sha=*) expected_base_sha="${1#*=}"; shift ;;
    --expected-head-sha|--head-sha)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-head-sha-value'
      expected_head_sha="$2"
      shift 2
      ;;
    --expected-head-sha=*|--head-sha=*) expected_head_sha="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown-option:$1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || error 'missing-gh'
command -v jq >/dev/null 2>&1 || error 'missing-jq'

if [ -z "$policy" ]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  policy="${script_dir}/../.agents/workflows/backlog-policy.json"
fi
[ -r "$policy" ] || error 'policy-not-readable'

[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || error 'invalid-repository'
[[ "$expected_issue" == '' || "$expected_issue" =~ ^[1-9][0-9]*$ ]] || usage_error 'invalid-expected-issue'
[[ "$expected_pr" == '' || "$expected_pr" =~ ^[1-9][0-9]*$ ]] || usage_error 'invalid-expected-pr'
[[ "$expected_base_sha" == '' || "$expected_base_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error 'invalid-expected-base-sha'
[[ "$expected_head_sha" == '' || "$expected_head_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error 'invalid-expected-head-sha'
expected_base_sha="${expected_base_sha,,}"
expected_head_sha="${expected_head_sha,,}"

[[ "$max_rest_pages" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-rest-pages'
[[ "$max_graphql_pages" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-graphql-pages'
[[ "$max_issues" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-issues'
[[ "$max_review_threads" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-review-threads'
[[ "$max_reviews" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-reviews'
[[ "$max_closing_references" =~ ^[1-9][0-9]*$ ]] || error 'invalid-max-closing-references'

awaiting_label="$(jq -er '.labels["awaiting-merge"] | strings' "$policy" 2>/dev/null)" || error 'policy-awaiting-label-invalid'
policy_repository="$(jq -er '.repository | strings' "$policy" 2>/dev/null)" || error 'policy-repository-invalid'
[ "$policy_repository" = "$repo" ] || error 'policy-repository-mismatch'
required_checks_json="$(jq -ce '
  .merge_gate.required_checks
  | select(type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  | unique | sort
' "$policy" 2>/dev/null)" || error 'policy-required-checks-invalid'
required_status_checks_json="$(jq -ce '
  .merge_gate.server_protection.required_status_checks as $checks
  | if ($checks | type) != "array" or ($checks | length) == 0 then
      error("required status check identities must be a non-empty array")
    else $checks end
  | map(
      . as $check
      | if ($check | type) != "object" then
          error("required status check identity must be an object")
        elif ($check.context | type) != "string" or ($check.context | length) == 0 then
          error("required status check context must be non-empty")
        elif ($check.context | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) != $check.context then
          error("required status check context must not have surrounding whitespace")
        elif ($check.app_id | type) != "number" then
          error("required status check app_id must be numeric")
        elif (($check.app_id | floor) != $check.app_id) or ($check.app_id <= 0) then
          error("required status check app_id must be positive")
        else {context: $check.context, app_id: $check.app_id}
        end
    )
  | if (map(.context) | length) != (map(.context) | unique | length) then
      error("required status check contexts must be unique")
    else sort_by(.context) end
' "$policy" 2>/dev/null)" || error 'policy-required-status-check-identities-invalid'
policy_required_contexts_json="$(jq -ce 'map(.context) | sort' <<<"$required_status_checks_json")" || error 'policy-required-status-check-contexts-invalid'
[ "$policy_required_contexts_json" = "$required_checks_json" ] || error 'policy-required-check-identities-mismatch'
protected_branch="$(jq -er '.merge_gate.server_protection.branch | strings' "$policy" 2>/dev/null)" || error 'policy-protected-branch-invalid'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-merge-gate-evidence.XXXXXX")" || error 'temporary-directory-failed'
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

validate_page_limit() {
  local value="$1" limit="$2" label="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || error "${label}-count-invalid"
  [ "$value" -le "$limit" ] || error "${label}-limit-exceeded"
}

write_output() {
  local value="$1" parent_dir
  if [ -z "$output" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  case "$output" in *$'\n'*|*$'\r'*|'') error 'output-path-invalid';; esac
  [ ! -L "$output" ] || error 'output-symlink'
  parent_dir="$(dirname -- "$output")"
  [ -d "$parent_dir" ] || error 'output-parent-not-directory'
  printf '%s\n' "$value" >"$output" || error 'output-write-failed'
}

# gh api --paginate --slurp returns one array per REST page.  Some test doubles
# return a single array, so accept that shape too while rejecting every other
# shape.  The resulting array is always flattened and sorted later.
rest_pages() {
  local endpoint="$1" response flattened page_count
  response="$(gh api --paginate --slurp \
    -H 'Accept: application/vnd.github+json' \
    "${endpoint}" 2>/dev/null)" || error "github-read-failed:${endpoint}"
  page_count="$(jq -r '
    if type != "array" then "invalid"
    elif length == 0 then "0"
    elif all(.[]; type == "array") then length
    else "1" end
  ' <<<"$response" 2>/dev/null)"
  [ "$page_count" != invalid ] || error "github-response-invalid:${endpoint}"
  validate_page_limit "$page_count" "$max_rest_pages" 'rest-page'
  flattened="$(jq -ce '
    if type != "array" then error("response-not-array")
    elif length == 0 then []
    elif all(.[]; type == "array") then map(.[])
    elif all(.[]; type == "object") then .
    else error("mixed-page-shape") end
  ' <<<"$response" 2>/dev/null)" || error "github-response-invalid:${endpoint}"
  printf '%s\n' "$flattened"
}

graphql_query() {
  local query="$1" number="$2" threads_after="$3" reviews_after="$4" include_threads="$5" include_reviews="$6"
  local args=(api graphql -f "query=${query}" -f "owner=${repo%%/*}" -f "name=${repo#*/}" -f "branch=${protected_branch}" -F "number=${number}" -F "includeThreads=${include_threads}" -F "includeReviews=${include_reviews}")
  [ -n "$threads_after" ] && args+=(-f "threadsAfter=${threads_after}")
  [ -n "$reviews_after" ] && args+=(-f "reviewsAfter=${reviews_after}")
  gh "${args[@]}" 2>/dev/null
}

# A timeline cross-reference is only a candidate hint.  GitHub's
# PullRequest.closingIssuesReferences connection is the source of truth for
# whether a PR actually closes the selected issue.  Read every page and fail
# closed on malformed pagination or GraphQL errors.
closing_references_query() {
  local number="$1" after="$2"
  local query='query($owner:String!,$name:String!,$number:Int!,$after:String) {
    repository(owner:$owner,name:$name) {
      pullRequest(number:$number) {
        number
        repository { nameWithOwner }
        closingIssuesReferences(first:100,after:$after) {
          pageInfo { hasNextPage endCursor }
          nodes { number repository { nameWithOwner } }
        }
      }
    }
  }'
  local args=(api graphql -f "query=${query}" -f "owner=${repo%%/*}" -f "name=${repo#*/}" -F "number=${number}")
  [ -n "$after" ] && args+=(-f "after=${after}")
  gh "${args[@]}" 2>/dev/null
}

closing_issue_numbers_for_pr() {
  local number="$1" after='' done=false page=0 response nodes has_next cursor all='[]' reference_count
  while [ "$done" != true ]; do
    page=$((page + 1))
    [ "$page" -le "$max_graphql_pages" ] || error "closing-reference-pagination-limit:${number}"
    response="$(closing_references_query "$number" "$after")" || error "closing-reference-read-failed:${number}"
    if ! jq -e --arg repo "$repo" --argjson pr "$number" '
      type == "object" and ((.errors? == null) or (.errors | type == "array" and length == 0)) and
      (.data.repository.pullRequest | type == "object") and
      (.data.repository.pullRequest.number == $pr) and
      (.data.repository.pullRequest.repository | type == "object" and .nameWithOwner == $repo) and
      (.data.repository.pullRequest.closingIssuesReferences | type == "object") and
      (.data.repository.pullRequest.closingIssuesReferences.pageInfo | type == "object") and
      (.data.repository.pullRequest.closingIssuesReferences.nodes | type == "array") and
      all(.data.repository.pullRequest.closingIssuesReferences.nodes[];
        type == "object" and
        (.number | type == "number" and floor == . and . >= 1) and
        (.repository | type == "object" and .nameWithOwner == $repo)
      )
    ' <<<"$response" >/dev/null 2>&1; then
      error "closing-reference-response-invalid:${number}"
    fi
    nodes="$(jq -ce '[.data.repository.pullRequest.closingIssuesReferences.nodes[].number]' <<<"$response")" || error "closing-reference-nodes-invalid:${number}"
    all="$(jq -ce --argjson nodes "$nodes" '. + $nodes' <<<"$all")" || error "closing-reference-accumulate-failed:${number}"
    validate_page_limit "$(jq 'length' <<<"$all")" "$max_closing_references" 'closing-reference'
    has_next="$(jq -r '.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage' <<<"$response")"
    cursor="$(jq -r '.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor // ""' <<<"$response")"
    [ "$has_next" = true ] || [ "$has_next" = false ] || error "closing-reference-page-info-invalid:${number}"
    if [ "$has_next" = true ]; then
      [ -n "$cursor" ] || error "closing-reference-cursor-missing:${number}"
      [ "$cursor" != "$after" ] || error "closing-reference-cursor-not-progressing:${number}"
      after="$cursor"
    else
      done=true
    fi
  done
  reference_count="$(jq 'length' <<<"$all")"
  if [ "$reference_count" -gt 1 ]; then
    error "closing-reference-count-invalid:${number}"
  fi
  jq -S -c 'unique | sort' <<<"$all"
}

issue_inventory="$(rest_pages "repos/${repo}/issues?state=open&labels=${awaiting_label//:/%3A}&per_page=100")"
validate_page_limit "$(jq 'length' <<<"$issue_inventory")" "$max_issues" 'issue-inventory'
if ! jq -e 'all(.[]; type == "object" and (.number | type == "number" and floor == . and . >= 1) and (.state | type == "string") and (.labels | type == "array"))' <<<"$issue_inventory" >/dev/null 2>&1; then
  error 'issue-inventory-invalid'
fi

normalized_issue_inventory="$(jq -ce --arg awaiting "$awaiting_label" '
  map(select(.pull_request? == null) |
    {
      number,
      title: (.title // ""),
      url: (.html_url // .url // ("#" + (.number | tostring))),
      state: (.state | ascii_upcase),
      labels: ([.labels[] | if type == "object" then .name else . end | strings] | unique | sort),
      _raw: .
    }
  )
  | sort_by(.number)
' <<<"$issue_inventory" 2>/dev/null)" || error 'issue-inventory-normalization-failed'

candidate="$(jq -c --arg awaiting "$awaiting_label" '
  map(select(.state == "OPEN" and (.labels | index($awaiting) != null))) | .[0] // empty
' <<<"$normalized_issue_inventory" 2>/dev/null)" || error 'no-awaiting-merge-candidate'

if [ -z "$candidate" ]; then
  result="$(jq -cn --arg repo "$repo" --arg branch "$protected_branch" --arg reason 'no-awaiting-merge-candidate' --argjson issues "$normalized_issue_inventory" --argjson required "$required_checks_json" '{schema_version:1,repository:$repo,protected_branch:$branch,required_checks:$required,selection:{status:"no-work",reason:$reason,issue:null,pr:null,base_ref:null,head_ref:null,base_sha:null,head_sha:null},issues:($issues | map(del(._raw)))}' | jq -S -c .)"
  write_output "$result"
  exit 0
fi

issue_number="$(jq -er '.number' <<<"$candidate")"
[ -z "$expected_issue" ] || [ "$issue_number" = "$expected_issue" ] || error "selected-issue-mismatch:expected-${expected_issue}:actual-${issue_number}"

issue_timeline="$(rest_pages "repos/${repo}/issues/${issue_number}/timeline?per_page=100")"
if ! jq -e 'all(.[]; type == "object")' <<<"$issue_timeline" >/dev/null 2>&1; then
  error 'issue-timeline-invalid'
fi

awaiting_actor="$(jq -r --arg awaiting "$awaiting_label" '
  [ .[]
    | select(.event == "labeled" and ((.label.name // "") == $awaiting))
    | (.actor.login // .user.login // .performed_via_github_app.slug // empty)
    | select(type == "string" and length > 0)
  ] | last // ""
' <<<"$issue_timeline")"

timeline_prs="$(jq -ce '
  [ .[]
    | select(.event == "cross-referenced" or .event == "connected")
    | (.source.issue? // empty)
    | select(.pull_request? != null)
    | {number, title: (.title // ""), url: (.html_url // .url // ("#" + (.number | tostring)))}
  ] | unique_by(.number) | sort_by(.number)
' <<<"$issue_timeline" 2>/dev/null)" || error 'closing-pr-timeline-invalid'

printf '%s\n' "$timeline_prs" | jq -r '.[].number' >"$tmp_dir/pr-numbers"
>"$tmp_dir/open-prs.jsonl"
while IFS= read -r pr_number; do
  [ -n "$pr_number" ] || continue
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || error 'closing-pr-number-invalid'
  pr_raw="$(gh api -H 'Accept: application/vnd.github+json' "repos/${repo}/pulls/${pr_number}" 2>/dev/null)" || error "pull-request-read-failed:${pr_number}"
  if ! jq -e 'type == "object" and (.number | type == "number" and floor == . and . >= 1) and (.state | type == "string") and (.base | type == "object") and (.head | type == "object")' <<<"$pr_raw" >/dev/null 2>&1; then
    error "pull-request-invalid:${pr_number}"
  fi
  closing_issue_numbers="$(closing_issue_numbers_for_pr "$pr_number" '')" || error "closing-reference-read-failed:${pr_number}"
  if ! jq -e --argjson issue "$issue_number" 'index($issue) != null' <<<"$closing_issue_numbers" >/dev/null 2>&1; then
    # A simple timeline mention is not a closing relationship.  It remains
    # visible in the read-only timeline, while this PR is excluded from the
    # canonical closing_prs list.
    continue
  fi
  pr_state="$(jq -r '.state | ascii_upcase' <<<"$pr_raw")"
  [ "$pr_state" = OPEN ] || continue
  normalized_pr="$(jq -ce --arg repo "$repo" --argjson closing_issue_numbers "$closing_issue_numbers" '
    {
      number,
      title: (.title // ""),
      url: (.html_url // .url // ("#" + (.number | tostring))),
      state: (.state | ascii_upcase),
      is_draft: (.draft == true),
      head_sha: (.head.sha // "" | ascii_downcase),
      base_sha: (.base.sha // "" | ascii_downcase),
      head_ref: (.head.ref // ""),
      base_ref: (.base.ref // ""),
      head_repository: (.head.repo.full_name // null),
      base_repository: (.base.repo.full_name // null),
      same_repository: ((.head.repo.full_name // "") == $repo and (.base.repo.full_name // "") == $repo),
      is_cross_repository: ((.head.repo.full_name // "") != $repo or (.base.repo.full_name // "") != $repo),
      closing_issue_numbers: $closing_issue_numbers,
      auto_merge_enabled: (.auto_merge != null),
      mergeable: (if .mergeable == true then true elif .mergeable == false then false else null end),
      merge_state: ((.mergeable_state // "UNKNOWN") | ascii_upcase)
    }
  ' <<<"$pr_raw" 2>/dev/null)" || error "pull-request-normalization-failed:${pr_number}"
  printf '%s\n' "$normalized_pr" >>"$tmp_dir/open-prs.jsonl"
done <"$tmp_dir/pr-numbers"

open_prs="$(jq -sc 'sort_by(.number)' "$tmp_dir/open-prs.jsonl")"
[ -z "$expected_pr" ] || {
  if ! jq -e --argjson expected "$expected_pr" 'any(.[]; .number == $expected)' <<<"$open_prs" >/dev/null 2>&1; then
    error "selected-pr-mismatch:expected-${expected_pr}"
  fi
}

if [ "$(jq 'length' <<<"$open_prs")" -eq 1 ]; then
  pr_number="$(jq -er '.[0].number' <<<"$open_prs")"
else
  pr_number=""
fi

if [ -z "$pr_number" ]; then
  # Keep enough normalized PR evidence for the checker to explain whether the
  # queue is ambiguous or contains a fork.  No per-PR mutable queries are
  # needed when uniqueness already failed.
  issue_record="$(jq -cn --argjson issue "$candidate" --arg actor "$awaiting_actor" --argjson prs "$open_prs" '$issue + {awaiting_merge_transition_actor:$actor,closing_prs:$prs} | del(._raw)')"
  evidence="$(jq -cn --arg repo "$repo" --arg branch "$protected_branch" --arg reason 'ambiguous-closing-pr' --argjson issue "$issue_record" --argjson issues "$normalized_issue_inventory" --argjson required "$required_checks_json" '{schema_version:1,repository:$repo,protected_branch:$branch,required_checks:$required,selection:{status:"blocked",reason:$reason,issue:$issue.number,pr:null,base_ref:null,head_ref:null,base_sha:null,head_sha:null},issues:([$issue] + ($issues | map(select(.number != $issue.number)) | map(del(._raw))))}' | jq -S -c .)"
  write_output "$evidence"
  exit 0
fi

if [ "$pr_number" != "" ]; then
  selected_pr="$(jq -ce --argjson pr "$pr_number" '.[] | select(.number == $pr)' <<<"$open_prs")" || error 'selected-pr-not-found'
else
  selected_pr='{}'
fi

base_ref="$(jq -r '.base_ref // ""' <<<"$selected_pr")"
head_ref="$(jq -r '.head_ref // ""' <<<"$selected_pr")"
base_sha="$(jq -r '.base_sha // ""' <<<"$selected_pr")"
head_sha="$(jq -r '.head_sha // ""' <<<"$selected_pr")"
[ -z "$expected_base_sha" ] || [ "$base_sha" = "$expected_base_sha" ] || error 'base-sha-changed-during-collection'
[ -z "$expected_head_sha" ] || [ "$head_sha" = "$expected_head_sha" ] || error 'head-sha-changed-during-collection'

[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || error 'base-sha-invalid'
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || error 'head-sha-invalid'

protected_ref_raw="$(gh api -H 'Accept: application/vnd.github+json' "repos/${repo}/git/ref/heads/${protected_branch}" 2>/dev/null)" || error 'protected-ref-read-failed'
protected_ref_sha="$(jq -er '.object.sha | strings | ascii_downcase' <<<"$protected_ref_raw" 2>/dev/null)" || error 'protected-ref-response-invalid'
[[ "$protected_ref_sha" =~ ^[0-9a-f]{40}$ ]] || error 'protected-ref-sha-invalid'
[ "$protected_ref_sha" = "$base_sha" ] || error 'protected-ref-sha-changed'

checks_raw='[]'
if ! checks_raw="$(gh pr checks "$pr_number" --repo "$repo" --json name,bucket 2>/dev/null)"; then
  # gh returns a nonzero status when one check is pending or failed, while
  # still returning the useful JSON.  An empty/malformed response remains a
  # hard evidence error below.
  checks_raw="${checks_raw:-[]}"
fi
if ! jq -e 'type == "array" and all(.[]; type == "object" and (.name | type == "string") and (.bucket | type == "string"))' <<<"$checks_raw" >/dev/null 2>&1; then
  error 'check-evidence-invalid'
fi
# Build required check conclusions in shell so duplicate runs and namespaced
# contexts are handled deterministically.
checks='{}'
while IFS= read -r required; do
  [ -n "$required" ] || continue
  matching="$(jq -c --arg required "$required" '[.[] | select(.name == $required or (.name | endswith("/ " + $required)))]' <<<"$checks_raw")"
  if [ "$(jq 'length' <<<"$matching")" -eq 0 ]; then
    conclusion='pending'
  elif jq -e 'any(.[]; (.bucket | ascii_downcase) | IN("fail","failure","cancelled","timed_out","action_required"))' <<<"$matching" >/dev/null 2>&1; then
    conclusion='failure'
  elif jq -e 'any(.[]; (.bucket | ascii_downcase) | IN("pending","queued","in_progress","neutral","skipping","startup_failure"))' <<<"$matching" >/dev/null 2>&1; then
    conclusion='pending'
  elif jq -e 'all(.[]; (.bucket | ascii_downcase) | IN("pass","success"))' <<<"$matching" >/dev/null 2>&1; then
    conclusion='success'
  else
    error "check-result-invalid:${required}"
  fi
  checks="$(jq -c --arg name "$required" --arg conclusion "$conclusion" '. + {($name):$conclusion}' <<<"$checks")"
done < <(jq -r '.[]' <<<"$required_checks_json")

review_query='
query($owner:String!,$name:String!,$branch:String!,$number:Int!,$threadsAfter:String,$reviewsAfter:String,$includeThreads:Boolean!,$includeReviews:Boolean!) {
  repository(owner:$owner,name:$name) {
    mergeQueue(branch:$branch) { id }
    pullRequest(number:$number) {
      number
      headRefOid
      reviewThreads(first:100,after:$threadsAfter) @include(if:$includeThreads) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          comments(first:100) {
            pageInfo { hasNextPage endCursor }
            nodes { id body createdAt url author { login } }
          }
        }
      }
      reviews(first:100,after:$reviewsAfter) @include(if:$includeReviews) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          state
          body
          submittedAt
          url
          author { login }
          commit { oid }
        }
      }
      mergeQueueEntry { state position }
    }
  }
}'

>"$tmp_dir/threads.jsonl"
>"$tmp_dir/reviews.jsonl"
threads_after=''
reviews_after=''
threads_done=false
reviews_done=false
graphql_page=0
queue_json='null'
repository_queue_json='null'
while [ "$threads_done" != true ] || [ "$reviews_done" != true ]; do
  graphql_page=$((graphql_page + 1))
  [ "$graphql_page" -le "$max_graphql_pages" ] || error 'graphql-pagination-limit-exceeded'
  include_threads=true
  include_reviews=true
  [ "$threads_done" = true ] && include_threads=false
  [ "$reviews_done" = true ] && include_reviews=false
  response="$(graphql_query "$review_query" "$pr_number" "$threads_after" "$reviews_after" "$include_threads" "$include_reviews")" || error 'graphql-read-failed'
  if ! jq -e --argjson expected_pr "$pr_number" --argjson include_threads "$include_threads" --argjson include_reviews "$include_reviews" '
    def valid_page_info:
      type == "object"
      and (.hasNextPage | type == "boolean")
      and ((.endCursor == null) or (.endCursor | type == "string"));
    def valid_sha:
      type == "string" and test("^[0-9a-fA-F]{40}$");
    def valid_author:
      (. == null) or (type == "object" and (.login | type == "string" and length > 0));
    def valid_commit:
      (. == null) or (type == "object" and (.oid | valid_sha));
    def valid_submitted_at:
      type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
    def valid_review:
      type == "object"
      and (.id | type == "string" and length > 0)
      and (.state | type == "string" and IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"))
      and (.body | type == "string")
      and ((.submittedAt == null) or (.submittedAt | valid_submitted_at))
      and (.author | valid_author)
      and (.commit | valid_commit)
      and (
        (.state == "PENDING" and .submittedAt == null)
        or (
          .state != "PENDING"
          and (.submittedAt | valid_submitted_at)
          and (.commit | type == "object" and (.oid | valid_sha))
        )
      );
    type == "object"
    and ((.errors? == null) or (.errors | type == "array" and length == 0))
    and (.data | type == "object")
    and (.data.repository | type == "object")
    and (.data.repository.pullRequest | type == "object")
    and (.data.repository.pullRequest.number | type == "number" and floor == . and . == $expected_pr)
    and (.data.repository.pullRequest.headRefOid | valid_sha)
    and (
      ($include_threads | not)
      or (
        .data.repository.pullRequest.reviewThreads | type == "object"
        and (.pageInfo | valid_page_info)
        and (.nodes | type == "array")
      )
    )
    and (
      ($include_reviews | not)
      or (
        .data.repository.pullRequest.reviews | type == "object"
        and (.pageInfo | valid_page_info)
        and (.nodes | type == "array")
        and all(.nodes[]; valid_review)
      )
    )
  ' <<<"$response" >/dev/null 2>&1; then
    error 'graphql-response-invalid'
  fi
  graphql_head_sha="$(jq -er '.data.repository.pullRequest.headRefOid | ascii_downcase' <<<"$response" 2>/dev/null)" || error 'graphql-head-sha-invalid'
  [ "$graphql_head_sha" = "$head_sha" ] || error 'head-sha-drift-during-review-read'
  if [ "$graphql_page" -eq 1 ]; then
    queue_json="$(jq -c '.data.repository.pullRequest.mergeQueueEntry // null' <<<"$response")"
    repository_queue_json="$(jq -c '.data.repository.mergeQueue // null' <<<"$response")"
    if ! jq -e '(. == null) or (type == "object" and (.id | type == "string" and length > 0))' <<<"$repository_queue_json" >/dev/null 2>&1; then
      error 'repository-merge-queue-evidence-invalid'
    fi
    if ! jq -e '(. == null) or (type == "object" and (.state | type == "string") and (.position | type == "number" and floor == . and . >= 1))' <<<"$queue_json" >/dev/null 2>&1; then
      error 'merge-queue-evidence-invalid'
    fi
  fi

  if [ "$threads_done" != true ]; then
    page_threads="$(jq -c '.data.repository.pullRequest.reviewThreads.nodes' <<<"$response")"
    jq -c '.data.repository.pullRequest.reviewThreads.nodes[]' <<<"$response" >>"$tmp_dir/threads.jsonl"
    validate_page_limit "$(wc -l <"$tmp_dir/threads.jsonl" | tr -d '[:space:]')" "$max_review_threads" 'review-thread'
    if ! jq -e 'all(.[]; type == "object" and (.id | type == "string" and length > 0) and (.isResolved | type == "boolean") and (.isOutdated | type == "boolean") and (.comments | type == "object") and (.comments.pageInfo.hasNextPage == false) and (.comments.nodes | type == "array"))' <<<"$page_threads" >/dev/null 2>&1; then
      error 'review-thread-page-invalid'
    fi
    threads_has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$response")"
    threads_cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<<"$response")"
    [ "$threads_has_next" = true ] || [ "$threads_has_next" = false ] || error 'review-thread-page-info-invalid'
    if [ "$threads_has_next" = true ]; then
      [ -n "$threads_cursor" ] || error 'review-thread-cursor-missing'
      [ "$threads_cursor" != "$threads_after" ] || error 'review-thread-cursor-not-progressing'
      threads_after="$threads_cursor"
    else
      threads_done=true
    fi
  fi

  if [ "$reviews_done" != true ]; then
    page_reviews="$(jq -c '.data.repository.pullRequest.reviews.nodes' <<<"$response")"
    jq -c '.data.repository.pullRequest.reviews.nodes[]' <<<"$response" >>"$tmp_dir/reviews.jsonl"
    validate_page_limit "$(wc -l <"$tmp_dir/reviews.jsonl" | tr -d '[:space:]')" "$max_reviews" 'review'
    if ! jq -e 'all(.[]; type == "object" and (.id | type == "string" and length > 0) and (.state | type == "string") and (.body | type == "string") and ((.author == null) or (.author.login | type == "string")) and ((.commit == null) or (.commit.oid | type == "string")))' <<<"$page_reviews" >/dev/null 2>&1; then
      error 'review-page-invalid'
    fi
    reviews_has_next="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' <<<"$response")"
    reviews_cursor="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor // ""' <<<"$response")"
    [ "$reviews_has_next" = true ] || [ "$reviews_has_next" = false ] || error 'review-page-info-invalid'
    if [ "$reviews_has_next" = true ]; then
      [ -n "$reviews_cursor" ] || error 'review-cursor-missing'
      [ "$reviews_cursor" != "$reviews_after" ] || error 'review-cursor-not-progressing'
      reviews_after="$reviews_cursor"
    else
      reviews_done=true
    fi
  fi
done

# A GraphQL connection can repeat a node when its contents change between
# pages.  Silently collapsing repeated review IDs would let the effective
# review depend on page timing, so reject the snapshot before normalizing it.
if ! jq -s -e '
  all(.[]; type == "object" and (.id | type == "string" and length > 0))
  and (map(.id) | length == (unique | length))
' "$tmp_dir/reviews.jsonl" >/dev/null 2>&1; then
  error 'review-id-duplicate-or-invalid'
fi

review_threads="$(jq -s '
  map({id,is_resolved:.isResolved,is_outdated:.isOutdated,comments:(.comments.nodes | map({id,body:(.body // ""),created_at:(.createdAt // null),url:(.url // null),author:((.author.login // null))}) | sort_by(.id))})
  | unique_by(.id) | sort_by(.id)
' "$tmp_dir/threads.jsonl")"
reviews="$(jq -s '
  map({id,state:(.state | ascii_upcase),body:(.body // ""),submitted_at:(.submittedAt // null),url:(.url // null),author:((.author.login // null)),commit_oid:(if .commit == null then null else (.commit.oid | ascii_downcase) end)})
  | unique_by(.id) | sort_by(.id)
' "$tmp_dir/reviews.jsonl")"

unresolved_threads="$(jq '[.[] | select(.is_resolved != true and .is_outdated != true)] | length' <<<"$review_threads")"
# Branch protection requires all conversations to be resolved.  Keep the
# explicit finding boolean as well because top-level review bodies have no
# ReviewThread object and can contain a P0/P1 heading by themselves.
unresolved_p0_p1="$(jq -r '
  # Keep this marker grammar in step with safe-direct-merge.sh.  Markdown
  # headings may bold the priority itself (`**P1**:`) or the priority plus
  # its delimiter (`**P1:**`).
  def p01: test("\\*{0,2}P[01]\\*{0,2}[[:space:]]*[:—–-]|\\[P[01]\\]|\\*{0,2}P[01]\\*{0,2}[[:space:]]+Badge"; "im");
  any(.[]; ((.is_resolved != true and .is_outdated != true) and any(.comments[]?; (.body | p01))))
' <<<"$review_threads")"
top_level_p0_p1="$(jq -r '
  # Keep this marker grammar in step with safe-direct-merge.sh.  Markdown
  # headings may bold the priority itself (`**P1**:`) or the priority plus
  # its delimiter (`**P1:**`).
  def p01: test("\\*{0,2}P[01]\\*{0,2}[[:space:]]*[:—–-]|\\[P[01]\\]|\\*{0,2}P[01]\\*{0,2}[[:space:]]+Badge"; "im");
  def current_submitted_review:
    .state != "DISMISSED"
    and .state != "PENDING"
    and (.submitted_at | type == "string" and length > 0)
    and .commit_oid == $head_sha;
  # Review IDs are the deterministic tie-breaker for two reviews submitted at
  # the same instant.  GitHub returns submittedAt in UTC RFC3339 form, whose
  # lexical order is chronological.  Grouping by author prevents an older
  # CHANGES_REQUESTED review from surviving a later APPROVED review by the
  # same reviewer, while preserving independent reviewer decisions.
  [ .[] | select(current_submitted_review) ]
  | if any(.[]; (.author | type != "string" or length == 0)) then
      error("current submitted review author is invalid")
    else . end
  | group_by(.author | ascii_downcase)
  | map(sort_by([.submitted_at, .id]) | last)
  | any(.[]; (.state == "CHANGES_REQUESTED") or (.body | p01))
' --arg head_sha "$head_sha" <<<"$reviews")" || error 'effective-review-invalid'
if [ "$unresolved_threads" -gt 0 ] || [ "$top_level_p0_p1" = true ]; then
  unresolved_p0_p1=true
fi

if [ "$repository_queue_json" != null ]; then
  merge_queue='{"present":true,"state":"ENABLED","position":null}'
elif [ "$queue_json" = null ]; then
  merge_queue='{"present":false,"state":null,"position":null}'
else
  merge_queue="$(jq -c '{present:true,state:.state,position:.position}' <<<"$queue_json")"
fi

protection_raw="$(gh api -H 'Accept: application/vnd.github+json' "repos/${repo}/branches/${protected_branch}/protection" 2>/dev/null)" || error 'branch-protection-read-failed'
server_protection="$(jq -ce --arg branch "$protected_branch" '
  def bool_or_null($x): if ($x | type) == "boolean" then $x else null end;
  if type != "object" then error("branch protection must be an object")
  elif (.required_status_checks | type) != "object" then error("required status checks must be an object")
  elif (.required_status_checks.checks | type) != "array" or (.required_status_checks.checks | length) == 0 then error("required status check identities are missing")
  elif any(.required_status_checks.checks[];
    if type != "object" then true
    elif (.context | type) != "string" or (.context | length) == 0 then true
    elif ((.context | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) != .context) then true
    elif (.app_id | type) != "number" then true
    elif ((.app_id | floor) != .app_id) or (.app_id <= 0) then true
    else false end
  ) then error("required status check identity is invalid")
  elif (([.required_status_checks.checks[].context] | length) != ([.required_status_checks.checks[].context] | unique | length)) then error("required status check contexts are duplicated")
  elif (.required_status_checks.contexts | type) != "array" then error("required status check contexts are missing")
  elif any(.required_status_checks.contexts[]; type != "string" or length == 0) then error("required status check context is invalid")
  elif ((.required_status_checks.contexts | sort) != ([.required_status_checks.checks[].context] | sort)) then error("required status check contexts do not match identities")
  else
    {
      branch: $branch,
      enforce_admins: (.enforce_admins.enabled | bool_or_null(.)),
      required_conversation_resolution: (.required_conversation_resolution.enabled | bool_or_null(.)),
      required_status_checks: ([.required_status_checks.checks[] | {context, app_id}] | sort_by(.context)),
      strict_status_checks: (.required_status_checks.strict | bool_or_null(.)),
      allow_force_pushes: (.allow_force_pushes.enabled | bool_or_null(.)),
      allow_deletions: (.allow_deletions.enabled | bool_or_null(.))
    }
  end
' <<<"$protection_raw" 2>/dev/null)" || error 'branch-protection-response-invalid'

issue_record="$(jq -cn --argjson issue "$candidate" --arg actor "$awaiting_actor" --argjson prs "[$selected_pr]" '$issue + {awaiting_merge_transition_actor:$actor,closing_prs:$prs} | del(._raw)')"
pr_record="$(jq -cn \
  --argjson pr "$selected_pr" \
  --argjson checks "$checks" \
  --argjson threads "$review_threads" \
  --argjson reviews "$reviews" \
  --argjson queue "$merge_queue" \
  --argjson protection "$server_protection" \
  --argjson unresolved_threads "$unresolved_threads" \
  --argjson unresolved "$unresolved_p0_p1" \
  --argjson top_level "$top_level_p0_p1" \
  '$pr + {checks:$checks,review_threads:$threads,reviews:$reviews,merge_queue:$queue,server_protection:$protection,unresolved_review_threads:$unresolved_threads,unresolved_p0_p1:$unresolved,top_level_p0_p1:$top_level}')"
issue_record="$(jq -c --argjson pr "$pr_record" '.closing_prs=[$pr]' <<<"$issue_record")"

issues="$(jq -c --argjson issue "$issue_record" --argjson all "$normalized_issue_inventory" '([$issue] + ($all | map(select(.number != $issue.number)) | map(del(._raw)))) | sort_by(.number)' <<<"$candidate")"
selection_status='merge'
selection_reason='gate-evidence-collected'
evidence="$(jq -cn \
  --arg repo "$repo" \
  --arg branch "$protected_branch" \
  --arg status "$selection_status" \
  --arg reason "$selection_reason" \
  --argjson issue "$issue_number" \
  --argjson pr "$pr_number" \
  --arg base_ref "$base_ref" \
  --arg head_ref "$head_ref" \
  --arg base_sha "$base_sha" \
  --arg head_sha "$head_sha" \
  --argjson required "$required_checks_json" \
  --argjson issues "$issues" \
  '{schema_version:1,repository:$repo,protected_branch:$branch,required_checks:$required,selection:{status:$status,reason:$reason,issue:$issue,pr:$pr,base_ref:$base_ref,head_ref:$head_ref,base_sha:$base_sha,head_sha:$head_sha},issues:$issues}' | jq -S -c .)"

write_output "$evidence"
