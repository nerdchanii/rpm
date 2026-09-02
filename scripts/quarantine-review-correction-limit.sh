#!/usr/bin/env bash
set -euo pipefail

# Move one exhausted review out of the review queue.  The selector passes an
# immutable snapshot, while this helper re-reads every mutable value before
# it writes. It is deliberately separate from the review Cloud job: an invalid
# correction state, including a valid correction-5 state, must never start
# another Cloud task.

usage() {
  cat >&2 <<'EOF'
usage: quarantine-review-correction-limit.sh \
  --issue NUMBER --pr NUMBER --base-ref REF --base-sha SHA \
  --head-ref REF --head-sha SHA [--reason REASON] [--policy PATH]
EOF
}

error() {
  printf 'quarantine_review_correction_limit.FAIL=%s\n' "$1" >&2
  exit 1
}

issue_number=''
pr_number=''
base_ref=''
base_sha=''
head_ref=''
head_sha=''
expected_reason='correction-limit'
policy=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue|--pr|--base-ref|--base-sha|--head-ref|--head-sha|--reason|--policy)
      [ "$#" -ge 2 ] || { usage; error "missing-${1#--}"; }
      case "$1" in
        --issue) issue_number="$2" ;;
        --pr) pr_number="$2" ;;
        --base-ref) base_ref="$2" ;;
        --base-sha) base_sha="$2" ;;
        --head-ref) head_ref="$2" ;;
        --head-sha) head_sha="$2" ;;
        --reason) expected_reason="$2" ;;
        --policy) policy="$2" ;;
      esac
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      error "unknown-argument:$1"
      ;;
  esac
done

for value in "$issue_number" "$pr_number"; do
  case "$value" in
    ''|*[!0-9]*) error 'invalid-number' ;;
  esac
  [ "$value" -gt 0 ] 2>/dev/null || error 'invalid-number'
done
[ -n "${GITHUB_REPOSITORY:-}" ] || error 'missing-repository'
[ "$GITHUB_REPOSITORY" = 'nerdchanii/rpm' ] || error 'repository-mismatch'
[ -n "${GH_TOKEN:-}" ] || error 'missing-gh-token'
[ "$expected_reason" != *$'\n'* ] || error 'invalid-reason'
case "$expected_reason" in
  correction-limit|correction-label-invalid|correction-history-response-invalid|\
  correction-history-malformed|correction-history-untrusted-author|correction-history-duplicate|\
  correction-history-sequence-missing|correction-history-label-lowered|\
  correction-history-sequence-invalid|correction-history-head-mismatch|\
  multiple-closing-references) ;;
  *) error 'invalid-reason' ;;
esac
[ "$base_ref" = main ] || error 'invalid-base-ref'
case "$head_ref" in
  ''|main|master|develop|release|HEAD|refs/*|*'..'*|*'//'*) error 'invalid-head-ref' ;;
esac
[[ "$head_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || error 'invalid-head-ref'
[[ "$head_ref" != */ && "$head_ref" != /* && "$head_ref" != -* ]] || error 'invalid-head-ref'
git check-ref-format --branch "$head_ref" >/dev/null 2>&1 || error 'invalid-head-ref'

is_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

is_sha "$base_sha" || error 'invalid-base-sha'
is_sha "$head_sha" || error 'invalid-head-sha'
base_sha="$(printf '%s' "$base_sha" | tr '[:upper:]' '[:lower:]')"
head_sha="$(printf '%s' "$head_sha" | tr '[:upper:]' '[:lower:]')"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -z "$policy" ]; then
  policy="${script_dir}/../.agents/workflows/backlog-policy.json"
fi
[ -r "$policy" ] || error 'policy-unreadable'

review_pending_label="$(jq -er '.labels["review-pending"] | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-review-pending-label-invalid'
blocked_label="$(jq -er '.labels.blocked | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-blocked-label-invalid'
correction5_label="$(jq -er '.review_correction.counter_labels["5"] | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-correction-5-label-invalid'
[ "$review_pending_label" != "$blocked_label" ] || error 'policy-lifecycle-labels-conflict'
[ "$correction5_label" = agent:correction-5 ] || error 'policy-correction-5-label-invalid'
for correction_counter in 0 1 2 3 4 5; do
  correction_label="$(jq -er --arg counter "$correction_counter" \
    '.review_correction.counter_labels[$counter] | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
    error "policy-correction-${correction_counter}-label-invalid"
  [ "$correction_label" = "agent:correction-${correction_counter}" ] ||
    error "policy-correction-${correction_counter}-label-invalid"
done
lifecycle_json="$(jq -ce '
  .labels |
  select(type == "object") |
  [to_entries[].value] |
  select(length > 0 and all(.[]; type == "string" and length > 0) and
    (length == (unique | length)))
' "$policy" 2>/dev/null)" || error 'policy-lifecycle-labels-invalid'
readonly correction_history_marker_prefix='<!-- rpm-agent-correction-history:'
readonly trusted_publisher_actor_bot='github-actions[bot]'
readonly trusted_publisher_actor_login='nerdchanii'
readonly max_graphql_pages=100
readonly max_graphql_comments=10000
readonly max_graphql_references=10000
readonly repository_owner="${GITHUB_REPOSITORY%%/*}"
readonly repository_name="${GITHUB_REPOSITORY#*/}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-review-correction-limit.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

# Read every issue comment through the GraphQL connection. The helper is also
# used after its lifecycle transition, so no state write occurs until all
# pages, cursors, and comment IDs have been validated.
read_issue_comments() {
  local target_issue="$1" comments_file="$2"
  local pages_file="${tmp_dir}/correction-history-pages.jsonl"
  local cursors_file="${tmp_dir}/correction-history-cursors.txt"
  local query response page_count=0 comment_count=0 page_comment_count has_next next_cursor
  local cursor=''
  local -a gh_args

  [[ "$target_issue" =~ ^[1-9][0-9]*$ ]] || error 'correction-history-issue-invalid'
  : >"$pages_file"
  : >"$cursors_file"
  query='query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){nameWithOwner,issue(number:$number){number,repository{nameWithOwner},comments(first:100,after:$after){pageInfo{hasNextPage,endCursor},nodes{id,body,author{login}}}}}}'
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le "$max_graphql_pages" ] || error 'correction-history-pagination-limit'
    if [ -n "$cursor" ]; then
      if grep -Fqx -- "$cursor" "$cursors_file"; then
        error 'correction-history-pagination-cursor-repeat'
      fi
      case "$cursor" in *$'\n'*|*$'\r'*) error 'correction-history-pagination-cursor-invalid' ;; esac
      printf '%s\n' "$cursor" >>"$cursors_file"
    fi

    gh_args=(api graphql -f query="$query" \
      -f owner="$repository_owner" -f name="$repository_name" -F number="$target_issue")
    [ -z "$cursor" ] || gh_args+=(-f after="$cursor")
    if ! response="$(GH_REPO="$GITHUB_REPOSITORY" gh "${gh_args[@]}")"; then
      error 'correction-history-read-failed'
    fi
    jq -e --arg repo "$GITHUB_REPOSITORY" --argjson issue "$target_issue" '
      type == "object" and
      (.errors? == null) and
      (.data | type == "object") and
      (.data.repository | type == "object") and
      (.data.repository.nameWithOwner == $repo) and
      (.data.repository.issue | type == "object") and
      (.data.repository.issue.number == $issue) and
      (.data.repository.issue.repository | type == "object") and
      (.data.repository.issue.repository.nameWithOwner == $repo) and
      (.data.repository.issue.comments | type == "object") and
      (.data.repository.issue.comments.pageInfo | type == "object") and
      (.data.repository.issue.comments.pageInfo.hasNextPage | type == "boolean") and
      (.data.repository.issue.comments.pageInfo | has("endCursor")) and
      ((.data.repository.issue.comments.pageInfo.endCursor == null) or
       (.data.repository.issue.comments.pageInfo.endCursor | type == "string" and length > 0)) and
      (.data.repository.issue.comments.nodes | type == "array" and length <= 100 and all(.[];
        type == "object" and
        (.id | type == "string" and length > 0) and
        (.body | type == "string") and
        (has("author") and ((.author == null) or
         (.author | type == "object" and
          (.login | type == "string" and length > 0))))
      ))
    ' <<<"$response" >/dev/null 2>&1 || error 'correction-history-response-invalid'
    printf '%s\n' "$response" >>"$pages_file"
    page_comment_count="$(jq -er '.data.repository.issue.comments.nodes | length' <<<"$response")" ||
      error 'correction-history-response-invalid'
    comment_count=$((comment_count + page_comment_count))
    [ "$comment_count" -le "$max_graphql_comments" ] || error 'correction-history-comment-limit'
    jq -s -e '[.[].data.repository.issue.comments.nodes[].id] as $ids | ($ids | length) == ($ids | unique | length)' \
      "$pages_file" >/dev/null 2>&1 || error 'correction-history-pagination-duplicate-id'
    has_next="$(jq -r '.data.repository.issue.comments.pageInfo.hasNextPage' <<<"$response")" ||
      error 'correction-history-response-invalid'
    case "$has_next" in true|false) ;; *) error 'correction-history-response-invalid' ;; esac
    next_cursor="$(jq -r '.data.repository.issue.comments.pageInfo.endCursor // empty' <<<"$response")" ||
      error 'correction-history-response-invalid'
    if [ "$has_next" = true ]; then
      [ -n "$next_cursor" ] || error 'correction-history-pagination-cursor-invalid'
      [ "$next_cursor" != "$cursor" ] || error 'correction-history-pagination-cursor-stalled'
      cursor="$next_cursor"
    else
      break
    fi
  done
  jq -s -c '{comments:[.[].data.repository.issue.comments.nodes[] | {id,body,author:(if .author == null then null else {login:(.author.login // null)} end)}]}' \
    "$pages_file" >"$comments_file" 2>/dev/null || error 'correction-history-normalization-failed'
  jq -e '.comments | type == "array" and all(.[]; type == "object" and (.id | type == "string" and length > 0) and (.body | type == "string") and ((.author == null) or (.author | type == "object" and (.login | type == "string" and length > 0))))' \
    "$comments_file" >/dev/null 2>&1 || error 'correction-history-normalization-failed'
}

closing_issue_references_json=''
read_closing_issue_references() {
  local pages_file="${tmp_dir}/closing-reference-pages.jsonl"
  local cursors_file="${tmp_dir}/closing-reference-cursors.txt"
  local query response page_count=0 reference_count=0 page_reference_count has_next next_cursor
  local cursor=''
  local -a gh_args
  closing_issue_references_json=''
  : >"$pages_file"
  : >"$cursors_file"
  query='query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){nameWithOwner,pullRequest(number:$number){number,repository{nameWithOwner},closingIssuesReferences(first:100,after:$after){pageInfo{hasNextPage,endCursor},nodes{id,number,repository{nameWithOwner}}}}}}'
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 100 ] || error 'closing-reference-pagination-limit'
    if [ -n "$cursor" ]; then
      if grep -Fqx -- "$cursor" "$cursors_file"; then
        error 'closing-reference-pagination-cursor-repeat'
      fi
      case "$cursor" in *$'\n'*|*$'\r'*) error 'closing-reference-pagination-cursor-invalid' ;; esac
      printf '%s\n' "$cursor" >>"$cursors_file"
    fi

    gh_args=(api graphql -f query="$query" \
      -f owner="$repository_owner" -f name="$repository_name" -F number="$pr_number")
    [ -z "$cursor" ] || gh_args+=(-f after="$cursor")
    if ! response="$(GH_REPO="$GITHUB_REPOSITORY" gh "${gh_args[@]}")"; then
      error 'closing-reference-read-failed'
    fi
    jq -e --arg repo "$GITHUB_REPOSITORY" --argjson pr "$pr_number" '
      type == "object" and
      (.errors? == null) and
      (.data | type == "object") and
      (.data.repository | type == "object") and
      (.data.repository.nameWithOwner == $repo) and
      (.data.repository.pullRequest | type == "object") and
      (.data.repository.pullRequest.number == $pr) and
      (.data.repository.pullRequest.repository | type == "object") and
      (.data.repository.pullRequest.repository.nameWithOwner == $repo) and
      (.data.repository.pullRequest.closingIssuesReferences | type == "object") and
      (.data.repository.pullRequest.closingIssuesReferences.pageInfo | type == "object") and
      (.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage | type == "boolean") and
      (.data.repository.pullRequest.closingIssuesReferences.pageInfo | has("endCursor")) and
      ((.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor == null) or
       (.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor | type == "string" and length > 0)) and
      (.data.repository.pullRequest.closingIssuesReferences.nodes | type == "array" and length <= 100 and all(.[];
        type == "object" and
        (.id | type == "string" and length > 0) and
        (.number | type == "number" and floor == . and . > 0) and
        (.repository | type == "object") and
        (.repository.nameWithOwner | type == "string" and test("^[^/]+/[^/]+$"))
      ))
    ' <<<"$response" >/dev/null 2>&1 || error 'closing-reference-response-invalid'
    printf '%s\n' "$response" >>"$pages_file"
    page_reference_count="$(jq -er '.data.repository.pullRequest.closingIssuesReferences.nodes | length' <<<"$response")" ||
      error 'closing-reference-response-invalid'
    reference_count=$((reference_count + page_reference_count))
    [ "$reference_count" -le "$max_graphql_references" ] || error 'closing-reference-reference-limit'
    jq -s -e '
      [.[].data.repository.pullRequest.closingIssuesReferences.nodes[]] as $nodes |
      ([ $nodes[].id ] | length) == ([ $nodes[].id ] | unique | length) and
      ([ $nodes[] | (.repository.nameWithOwner + "#" + (.number | tostring)) ] | length) ==
        ([ $nodes[] | (.repository.nameWithOwner + "#" + (.number | tostring)) ] | unique | length)
    ' "$pages_file" >/dev/null 2>&1 || error 'closing-reference-pagination-duplicate-id'
    has_next="$(jq -r '.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage' <<<"$response")" ||
      error 'closing-reference-response-invalid'
    case "$has_next" in true|false) ;; *) error 'closing-reference-response-invalid' ;; esac
    next_cursor="$(jq -r '.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor // empty' <<<"$response")" ||
      error 'closing-reference-response-invalid'
    if [ "$has_next" = true ]; then
      [ -n "$next_cursor" ] || error 'closing-reference-pagination-cursor-invalid'
      [ "$next_cursor" != "$cursor" ] || error 'closing-reference-pagination-cursor-stalled'
      cursor="$next_cursor"
    else
      break
    fi
  done
  closing_issue_references_json="$(jq -s -c '[.[].data.repository.pullRequest.closingIssuesReferences.nodes[] | {id,number,repository:{nameWithOwner:.repository.nameWithOwner}}]' "$pages_file" 2>/dev/null)" ||
    error 'closing-reference-normalization-failed'
  jq -e 'type == "array" and all(.[]; type == "object" and (.id | type == "string" and length > 0) and (.number | type == "number" and floor == . and . > 0) and (.repository.nameWithOwner | type == "string" and test("^[^/]+/[^/]+$")))' \
    <<<"$closing_issue_references_json" >/dev/null 2>&1 || error 'closing-reference-normalization-failed'
}

issue_state_json() {
  local metadata comments_file
  metadata="$(gh issue view "$issue_number" --repo "$GITHUB_REPOSITORY" --json number,state,labels)" || return 1
  comments_file="${tmp_dir}/issue-comments.json"
  read_issue_comments "$issue_number" "$comments_file" || return 1
  jq -c --slurpfile comments "$comments_file" '. + {comments:$comments[0].comments}' <<<"$metadata"
}

pr_state_json() {
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}"
}

validate_issue_json() {
  local value="$1"
  jq -e --argjson issue "$issue_number" '
    type == "object" and
    .number == $issue and
    (.state | type == "string") and
    (.labels | type == "array" and
      all(.[]; type == "object" and (.name | type == "string"))) and
    (.comments | type == "array" and
      all(.[]; type == "object" and
        (.id | type == "string" and length > 0) and
        (.body | type == "string") and
        ((.author == null) or
         (.author | type == "object" and
          (.login | type == "string" and length > 0)))))
  ' <<<"$value" >/dev/null 2>&1 || error 'invalid-issue-response'
}

validate_pr_json() {
  local value="$1"
  jq -e --argjson pr "$pr_number" --arg repo "$GITHUB_REPOSITORY" \
    --arg base "$base_ref" --arg base_sha "$base_sha" \
    --arg head "$head_ref" --arg head_sha "$head_sha" '
    type == "object" and
    .number == $pr and .state == "open" and
    (.base | type == "object") and (.head | type == "object") and
    (.base.ref == $base and (.base.sha | type == "string" and ascii_downcase == $base_sha)) and
    (.head.ref == $head and (.head.sha | type == "string" and ascii_downcase == $head_sha)) and
    .base.repo.full_name == $repo and .head.repo.full_name == $repo and
    (.labels | type == "array" and
      all(.[]; type == "object" and (.name | type == "string")))
  ' <<<"$value" >/dev/null 2>&1 || return 1
}

validate_pr_shape() {
  local value="$1"
  jq -e '
    type == "object" and
    (.number | type == "number" and floor == . and . > 0) and
    (.state | type == "string") and
    (.base | type == "object") and (.head | type == "object") and
    (.base.ref | type == "string") and (.base.sha | type == "string") and
    (.head.ref | type == "string") and (.head.sha | type == "string") and
    (.base.repo.full_name | type == "string") and
    (.head.repo.full_name | type == "string") and
    (.labels | type == "array" and
      all(.[]; type == "object" and (.name | type == "string")))
  ' <<<"$value" >/dev/null 2>&1
}

correction_state_reason=''
correction_state_counter=''
correction_state_label=''

# Classify the current visible correction label and its durable issue-comment
# history.  The function always returns success and places a terminal reason
# in correction_state_reason.  An empty reason means a valid counter 0-4;
# correction-limit means a valid counter-5 history.
classify_correction_state() {
  local issue_json="$1" pr_json="$2"
  local comment_json marker_data marker_pr counter head author
  local marker_re='^<!-- rpm-agent-correction-history: pr=(?<pr>[1-9][0-9]*); counter=(?<counter>agent:correction-[0-5]); head=(?<head>[0-9a-f]{40}) -->\n?$'
  local history_json='[]'
  local correction_names_json correction_name correction_count
  correction_state_reason=''
  correction_state_counter=''
  correction_state_label=''

  if ! jq -e '
    type == "object" and
    (.comments | type == "array" and all(.[];
      type == "object" and
      (.id | type == "string" and length > 0) and
      (.body | type == "string") and
      ((.author == null) or
       (.author | type == "object" and (.login | type == "string" and length > 0)))
    ))
  ' <<<"$issue_json" >/dev/null 2>&1; then
    correction_state_reason='correction-history-response-invalid'
    return 0
  fi

  correction_names_json="$(jq -c '[.labels[]?.name | select(startswith("agent:correction-"))]' <<<"$pr_json" 2>/dev/null)" || {
    correction_state_reason='correction-label-invalid'
    return 0
  }
  correction_count="$(jq 'length' <<<"$correction_names_json")"
  while IFS= read -r correction_name; do
    case "$correction_name" in
      agent:correction-0|agent:correction-1|agent:correction-2|agent:correction-3|agent:correction-4|agent:correction-5) ;;
      *)
        correction_state_reason='correction-label-invalid'
        return 0
        ;;
    esac
  done < <(jq -r '.[]' <<<"$correction_names_json")
  if [ "$correction_count" -ne 1 ]; then
    correction_state_reason='correction-label-invalid'
    return 0
  fi
  correction_state_label="$(jq -r '.[0]' <<<"$correction_names_json")"
  correction_state_counter="${correction_state_label##*-}"

  while IFS= read -r comment_json || [ -n "$comment_json" ]; do
    author="$(jq -r '.author.login // ""' <<<"$comment_json")" || {
      correction_state_reason='correction-history-response-invalid'
      return 0
    }
    case "$author" in
      "$trusted_publisher_actor_bot"|"$trusted_publisher_actor_login") ;;
      *) continue ;;
    esac
    if ! jq -e --arg prefix "$correction_history_marker_prefix" '.body | type == "string" and contains($prefix)' <<<"$comment_json" >/dev/null 2>&1; then
      continue
    fi
    marker_data="$(jq -r --arg prefix "$correction_history_marker_prefix" --arg re "$marker_re" '
      if ((.body | contains($prefix)) | not) then "NONE"
      elif (.body | test($re)) then
        (.body | capture($re)) as $match |
        [$match.pr, $match.counter, $match.head, (.author.login // "")] | @tsv
      else "MALFORMED" end
    ' <<<"$comment_json")" || {
      correction_state_reason='correction-history-response-invalid'
      return 0
    }
    [ "$marker_data" = NONE ] && continue
    if [ "$marker_data" = MALFORMED ]; then
      correction_state_reason='correction-history-malformed'
      return 0
    fi
    IFS=$'\t' read -r marker_pr counter head author <<<"$marker_data"
    [ "$marker_pr" = "$pr_number" ] || continue
    counter="${counter##*-}"
    if [ "$(jq --argjson counter "$counter" '[.[] | select(.counter == $counter)] | length' <<<"$history_json")" -ne 0 ]; then
      correction_state_reason='correction-history-duplicate'
      return 0
    fi
    history_json="$(jq -c --argjson counter "$counter" --arg head "${head,,}" '. + [{counter:$counter,head:$head}]' <<<"$history_json")"
  done < <(jq -c '.comments[]' <<<"$issue_json")

  if [ "$(jq --argjson current "$correction_state_counter" '[.[] | select(.counter > $current)] | length' <<<"$history_json")" -gt 0 ]; then
    correction_state_reason='correction-history-label-lowered'
    return 0
  fi
  for counter in $(seq 0 "$correction_state_counter"); do
    if [ "$(jq --argjson counter "$counter" '[.[] | select(.counter == $counter)] | length' <<<"$history_json")" -ne 1 ]; then
      correction_state_reason='correction-history-sequence-missing'
      return 0
    fi
  done
  if [ "$(jq 'length' <<<"$history_json")" -ne $((correction_state_counter + 1)) ]; then
    correction_state_reason='correction-history-sequence-invalid'
    return 0
  fi
  head="$(jq --argjson current "$correction_state_counter" -r '[.[] | select(.counter == $current) | .head][0] // empty' <<<"$history_json")"
  if [ "$head" != "$head_sha" ]; then
    correction_state_reason='correction-history-head-mismatch'
    return 0
  fi
  if [ "$correction_state_counter" -eq 5 ]; then
    correction_state_reason='correction-limit'
  fi
}

validate_closing_issue_binding() {
  read_closing_issue_references
  if [ "$expected_reason" = multiple-closing-references ]; then
    if ! jq -e --arg repo "$GITHUB_REPOSITORY" --argjson issue "$issue_number" '
      length >= 2 and any(.[]; .number == $issue and .repository.nameWithOwner == $repo)
    ' <<<"$closing_issue_references_json" >/dev/null 2>&1; then
      printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=closing-reference-state-changed\n' \
        "$issue_number" "$pr_number"
      exit 0
    fi
    return 0
  fi
  jq -e --argjson issue "$issue_number" --arg repo "$GITHUB_REPOSITORY" '
    type == "array" and length == 1 and
    .[0].number == $issue and .[0].repository.nameWithOwner == $repo
  ' <<<"$closing_issue_references_json" >/dev/null 2>&1 || error 'closing-issue-binding-missing'
}

issue_labels() {
  jq -r '.labels[].name' <<<"$1"
}

label_count() {
  local labels="$1" wanted="$2"
  printf '%s\n' "$labels" | awk -v wanted="$wanted" '$0 == wanted { count++ } END { print count + 0 }'
}

ordinary_labels() {
  jq -r --argjson lifecycle "$lifecycle_json" '
    [.labels[].name |
      . as $label |
      select(($lifecycle | index($label)) == null)] |
    sort | .[]
  ' <<<"$1"
}

validate_lifecycle_state() {
  local value="$1" expected="$2" labels lifecycle count
  labels="$(issue_labels "$value")"
  while IFS= read -r lifecycle; do
    [ -n "$lifecycle" ] || continue
    count="$(label_count "$labels" "$lifecycle")"
    [ "$count" -le 1 ] || error 'duplicate-lifecycle-label'
    if [ "$lifecycle" = "$expected" ]; then
      [ "$count" -eq 1 ] || error 'issue-state-mismatch'
    else
      [ "$count" -eq 0 ] || error 'conflicting-lifecycle-label'
    fi
  done <<<"$(jq -r '.[]' <<<"$lifecycle_json")"
}

marker="<!-- rpm-agent-correction-limit-block: issue=${issue_number};pr=${pr_number} -->"
marker_count() {
  local value="$1"
  jq -r --arg marker "$marker" '[.comments[] | select(.body | startswith($marker))] | length' <<<"$value"
}

write_comment() {
  if [ "$expected_reason" = correction-limit ]; then
    cat >"$tmp_dir/comment.md" <<EOF
$marker

자동 검토를 멈췄습니다.

PR #${pr_number}가 수정 시도 5회에 도달했습니다. 추가 수정 작업은 시작하지 않았습니다.
이슈를 수동으로 확인한 뒤 필요한 경우 상태를 다시 정해 주세요.
EOF
  elif [ "$expected_reason" = multiple-closing-references ]; then
    cat >"$tmp_dir/comment.md" <<EOF
$marker

자동 검토를 멈췄습니다.

PR #${pr_number}가 선택된 이슈 #${issue_number} 외의 이슈도 함께 닫도록 연결되어 있습니다. 자동 검토를 시작하지 않고 이슈를 blocked로 옮겼습니다.
사유: multiple-closing-references
PR이 선택된 이슈 하나만 닫도록 정리한 뒤 이슈를 다시 검토 대기 상태로 옮겨 주세요.
EOF
  else
    cat >"$tmp_dir/comment.md" <<EOF
$marker

자동 검토를 멈췄습니다.

PR #${pr_number}의 수정 횟수 라벨과 신뢰할 수 있는 기록이 일치하지 않습니다(${expected_reason}). 기록을 자동으로 고치지 않고 추가 수정 작업을 시작하지 않았습니다.
이슈를 수동으로 확인한 뒤 기록과 라벨을 정리해 주세요.
EOF
  fi
}

verify_exact_pr() {
  local stale_is_no_work="${1:-true}"
  local value
  value="$(pr_state_json 2>/dev/null)" || error 'pr-read-failed'
  validate_pr_shape "$value" || error 'invalid-pr-response'
  if ! validate_pr_json "$value"; then
    if jq -e --argjson pr "$pr_number" 'type == "object" and .number == $pr' <<<"$value" >/dev/null 2>&1; then
      [ "$stale_is_no_work" = true ] || error 'pr-state-changed-after-transition'
      printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=pr-state-changed\n' \
        "$issue_number" "$pr_number"
      exit 0
    fi
    error 'invalid-pr-response'
  fi
  pr_json_current="$value"
  validate_closing_issue_binding
}

# The selected protected SHA must still be the current main tip. This keeps a
# delayed writer from changing an unrelated issue after the selector snapshot
# has gone stale.
current_base_sha="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/heads/${base_ref}" --jq '.object.sha' 2>/dev/null)" ||
  error 'base-ref-read-failed'
is_sha "$current_base_sha" || error 'invalid-current-base-sha'
current_base_sha="$(printf '%s' "$current_base_sha" | tr '[:upper:]' '[:lower:]')"
[ "$current_base_sha" = "$base_sha" ] || {
  printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=base-state-changed\n' \
    "$issue_number" "$pr_number"
  exit 0
}

issue_before="$(issue_state_json 2>/dev/null)" || error 'issue-read-failed'
validate_issue_json "$issue_before"
[ "$(jq -r '.state | ascii_upcase' <<<"$issue_before")" = OPEN ] || {
  printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=issue-state-changed\n' \
    "$issue_number" "$pr_number"
  exit 0
}
labels="$(issue_labels "$issue_before")"
issue_lifecycle=''
if [ "$(label_count "$labels" "$review_pending_label")" -eq 1 ]; then
  validate_lifecycle_state "$issue_before" "$review_pending_label"
  issue_lifecycle=review-pending
elif [ "$(label_count "$labels" "$blocked_label")" -eq 1 ]; then
  validate_lifecycle_state "$issue_before" "$blocked_label"
  issue_lifecycle=blocked
else
  printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=issue-lifecycle-changed\n' \
    "$issue_number" "$pr_number"
  exit 0
fi

verify_exact_pr
if [ "$expected_reason" != multiple-closing-references ]; then
  classify_correction_state "$issue_before" "$pr_json_current"
  if [ -z "$correction_state_reason" ]; then
    printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=state-became-valid\n' \
      "$issue_number" "$pr_number"
    exit 0
  fi
  if [ "$correction_state_reason" != "$expected_reason" ]; then
    printf 'quarantine_review_correction_limit: status=no-work; issue=%s; pr=%s; reason=inconsistency-changed; current=%s; expected=%s\n' \
      "$issue_number" "$pr_number" "$correction_state_reason" "$expected_reason"
    exit 0
  fi
fi

ordinary_before="$(ordinary_labels "$issue_before")"
if [ "$issue_lifecycle" = review-pending ]; then
  gh issue edit "$issue_number" --repo "$GITHUB_REPOSITORY" \
    --remove-label "$review_pending_label" --add-label "$blocked_label" >/dev/null 2>&1 ||
    error 'state-transition-failed'
  issue_after="$(issue_state_json 2>/dev/null)" || error 'state-refetch-failed'
  validate_issue_json "$issue_after"
  [ "$(jq -r '.state | ascii_upcase' <<<"$issue_after")" = OPEN ] || error 'issue-closed-during-transition'
  validate_lifecycle_state "$issue_after" "$blocked_label"
  ordinary_after="$(ordinary_labels "$issue_after")"
  [ "$ordinary_before" = "$ordinary_after" ] || error 'ordinary-labels-changed'
else
  issue_after="$issue_before"
fi

# Re-check the PR after the issue write. A changed PR leaves the issue safely
# blocked and makes the run fail closed; the next invocation can reconcile it.
verify_exact_pr false

issue_final="$(issue_state_json 2>/dev/null)" || error 'final-issue-refetch-failed'
validate_issue_json "$issue_final"
[ "$(jq -r '.state | ascii_upcase' <<<"$issue_final")" = OPEN ] || error 'final-issue-closed'
validate_lifecycle_state "$issue_final" "$blocked_label"
ordinary_final="$(ordinary_labels "$issue_final")"
[ "$ordinary_before" = "$ordinary_final" ] || error 'final-ordinary-labels-changed'
if [ "$expected_reason" != multiple-closing-references ]; then
  classify_correction_state "$issue_final" "$pr_json_current"
  [ "$correction_state_reason" = "$expected_reason" ] || error 'correction-state-changed-after-transition'
fi

write_comment
comments_before="$(jq -c '{comments:.comments}' <<<"$issue_final")"
case "$(marker_count "$comments_before")" in
  0)
    gh issue comment "$issue_number" --repo "$GITHUB_REPOSITORY" \
      --body-file "$tmp_dir/comment.md" >/dev/null 2>&1 || error 'comment-write-failed'
    ;;
  1)
    ;;
  *)
    error 'duplicate-comment-marker'
    ;;
esac
comments_after="$(issue_state_json 2>/dev/null)" || error 'comment-refetch-failed'
jq -e 'type == "object" and (.comments | type == "array" and all(.[]; type == "object" and (.id | type == "string" and length > 0) and (.body | type == "string")))' \
  <<<"$comments_after" >/dev/null 2>&1 || error 'invalid-comment-response'
[ "$(marker_count "$comments_after")" -eq 1 ] || error 'comment-not-verified'

printf 'quarantine_review_correction_limit: status=blocked; issue=%s; pr=%s; reason=%s\n' \
  "$issue_number" "$pr_number" "$expected_reason"
