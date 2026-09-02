#!/usr/bin/env bash
set -euo pipefail

# Deterministic regression tests for the bounded, read-only review collector.
# The fake gh command only serves fixture JSON and never contacts GitHub.

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
collector="${repo_root}/scripts/collect-pr-review-context.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-context-test.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

fake_bin="${test_root}/bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${RPM_COLLECT_FIXTURE:?missing fixture directory}"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  printf 'owner/repo\n'
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  count_file="${fixture}/.count"
  count=0
  if [ -f "${count_file}" ]; then
    count="$(<"${count_file}")"
  fi
  count=$((count + 1))
  printf '%s\n' "${count}" >"${count_file}"
  if [ -f "${fixture}/page-${count}.json" ]; then
    cat "${fixture}/page-${count}.json"
  else
    cat "${fixture}/page-last.json"
  fi
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  if [ -f "${fixture}/sibling-failure" ]; then
    printf 'fixture sibling lookup failed\n' >&2
    exit 42
  fi
  if [ -f "${fixture}/siblings.json" ]; then
    cat "${fixture}/siblings.json"
  else
    printf '[]\n'
  fi
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 99
GH
chmod +x "${fake_bin}/gh"

new_fixture() {
  local fixture
  fixture="$(mktemp -d "${test_root}/fixture.XXXXXX")"
  printf '%s\n' "${fixture}"
}

write_page() {
  local fixture="$1" page="$2" comments_next="$3" comments_cursor="$4" comment_body="$5"
  jq -n \
    --argjson page_number 1 \
    --arg comments_next "${comments_next}" \
    --arg comments_cursor "${comments_cursor}" \
    --arg comment_body "${comment_body}" \
    '{
      data: {repository: {pullRequest: {
        number: $page_number,
        title: "Fixture PR",
        url: "https://example.test/pr/1",
        state: "OPEN",
        isDraft: false,
        comments: {
          pageInfo: {hasNextPage: ($comments_next == "true"), endCursor: $comments_cursor},
          nodes: [{author: {login: "octocat"}, createdAt: "2026-01-01T00:00:01Z", body: $comment_body, url: "https://example.test/comment/1"}]
        },
        reviews: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []},
        reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}
      }}}
    }' >"${fixture}/page-${page}.json"
}

write_review_thread() {
  local fixture="$1"
  jq '.data.repository.pullRequest.reviewThreads.nodes = [{
    id: "thread-1",
    isResolved: false,
    isOutdated: false,
    path: "src/lib.rs",
    line: 5,
    startLine: null,
    originalLine: 5,
    originalStartLine: null,
    diffSide: "RIGHT",
    startDiffSide: null,
    comments: {
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [{
        id: "comment-1",
        author: {login: "octocat"},
        createdAt: "2026-01-01T00:00:02Z",
        body: "review comment",
        url: "https://example.test/review-comment/1",
        path: "src/lib.rs",
        line: 5,
        startLine: null,
        originalLine: 5,
        originalStartLine: null,
        diffHunk: "@@ -5 +5 @@",
        outdated: false
      }]
    }
  }]' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
}

run_collector() {
  local fixture="$1"
  shift
  local collector_format="json"
  if [ "${1:-}" = "--format" ]; then
    collector_format="$2"
    shift 2
  fi
  PATH="${fake_bin}:${PATH}" \
    RPM_COLLECT_FIXTURE="${fixture}" \
    TMPDIR="${test_root}/tmp" \
    "$@" "${collector}" 1 --format "${collector_format}"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$($@ 2>&1)"; then
    printf 'FAIL: expected non-zero exit for %s\n' "${expected}" >&2
    return 1
  fi
  printf '%s\n' "${output}" | grep -Fq -- "review_context.error=${expected}" || {
    printf 'FAIL: expected error %s, got:\n%s\n' "${expected}" "${output}" >&2
    return 1
  }
}

expect_invalid_node_filter() {
  local filter="$1" fixture
  fixture="$(new_fixture)"
  write_page "${fixture}" 1 false cursor-1 ignored
  jq "${filter}" "${fixture}/page-1.json" >"${fixture}/shape.tmp"
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
  expect_failure invalid-node-payload run_collector "${fixture}"
}

expect_invalid_thread_filter() {
  local filter="$1" fixture
  fixture="$(new_fixture)"
  write_page "${fixture}" 1 false cursor-1 ignored
  write_review_thread "${fixture}"
  jq "${filter}" "${fixture}/page-1.json" >"${fixture}/shape.tmp"
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
  expect_failure invalid-node-payload run_collector "${fixture}"
}

expect_invalid_metadata_filter() {
  local filter="$1" fixture
  fixture="$(new_fixture)"
  write_page "${fixture}" 1 false cursor-1 ignored
  jq "${filter}" "${fixture}/page-1.json" >"${fixture}/shape.tmp"
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
  expect_failure invalid-graphql-payload run_collector "${fixture}"
}

mkdir -p "${test_root}/tmp"

# Normal pagination remains compatible with the existing JSON contract.
fixture="$(new_fixture)"
write_page "${fixture}" 1 true cursor-1 first
write_page "${fixture}" 2 false cursor-2 second
cp "${fixture}/page-2.json" "${fixture}/page-last.json"
output="$(run_collector "${fixture}")"
printf '%s\n' "${output}" | jq -e '.pullRequest.number == 1 and (.issueComments | length) == 2' >/dev/null
[ "$(<"${fixture}/.count")" = 2 ]

# Sibling PRs are included in the JSONL handoff when the lookup is complete.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq -n '[
  {number: 2, title: "Sibling PR", headRefName: "feature/sibling", baseRefName: "main",
   files: [{path: "src/lib.rs"}], body: "lands a related change"},
  {number: 1, title: "Current PR", headRefName: "feature/current", baseRefName: "main",
   files: [], body: "current pull request"}
]' >"${fixture}/siblings.json"
output="$(run_collector "${fixture}" --format jsonl)"
printf '%s\n' "${output}" | jq -s -e '
  any(.[]; .type == "pr_sibling_pr" and .data.number == 2)
  and (all(.[]; .type != "pr_sibling_pr" or .data.number != 1))
' >/dev/null

# A sibling lookup is required review context and API failure is fatal.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
: >"${fixture}/sibling-failure"
expect_failure sibling-query-failed run_collector "${fixture}"

# Malformed sibling data is fatal instead of silently becoming an empty list.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
printf '{"number": 2}\n' >"${fixture}/siblings.json"
expect_failure invalid-sibling-payload run_collector "${fixture}"

# The --limit 100 result is potentially truncated, so exactly 100 entries fail.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq -n '[range(0; 100) | {
  number: (. + 2),
  title: ("Sibling PR " + tostring),
  headRefName: ("feature/sibling-" + tostring),
  baseRefName: "main",
  files: [{path: "src/lib.rs"}],
  body: "related change"
}]' >"${fixture}/siblings.json"
expect_failure sibling-truncated run_collector "${fixture}"

# GraphQL errors are a hard failure even when data is also present.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.errors = [{message: "fixture GraphQL failure"}]' "${fixture}/page-1.json" >"${fixture}/graphql.tmp"
mv -- "${fixture}/graphql.tmp" "${fixture}/page-1.json"
expect_failure graphql-errors run_collector "${fixture}"

# A missing pull request object is an invalid GraphQL payload.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.data.repository.pullRequest = null' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
expect_failure invalid-graphql-payload run_collector "${fixture}"

# Pull request metadata fields are required GraphQL scalars.
expect_invalid_metadata_filter '.data.repository.pullRequest.title = 7'
expect_invalid_metadata_filter '.data.repository.pullRequest.number = "1"'

# A malformed connection shape must fail before jq silently drops data.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.data.repository.pullRequest.comments.nodes = {}' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
expect_failure invalid-node-payload run_collector "${fixture}"

# A requested connection cannot be null, missing, or contain scalar nodes.
for malformed in null scalar missing; do
  fixture="$(new_fixture)"
  write_page "${fixture}" 1 false cursor-1 ignored
  case "${malformed}" in
    null)
      jq '.data.repository.pullRequest.reviews = null' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
      ;;
    scalar)
      jq '.data.repository.pullRequest.reviews.nodes = ["review-node"]' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
      ;;
    missing)
      jq 'del(.data.repository.pullRequest.reviews.pageInfo)' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
      ;;
  esac
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
  expect_failure invalid-node-payload run_collector "${fixture}"
done

# Every connection rejects null, scalar, and empty object nodes. An empty
# object used to pass the generic object check and emit null fields.
expect_invalid_node_filter '.data.repository.pullRequest.comments.nodes = [null]'
expect_invalid_node_filter '.data.repository.pullRequest.comments.nodes = ["comment-node"]'
expect_invalid_node_filter '.data.repository.pullRequest.comments.nodes = [{}]'
expect_invalid_node_filter '.data.repository.pullRequest.reviews.nodes = [null]'
expect_invalid_node_filter '.data.repository.pullRequest.reviews.nodes = ["review-node"]'
expect_invalid_node_filter '.data.repository.pullRequest.reviews.nodes = [{}]'
expect_invalid_node_filter '.data.repository.pullRequest.reviewThreads.nodes = [null]'
expect_invalid_node_filter '.data.repository.pullRequest.reviewThreads.nodes = ["thread-node"]'
expect_invalid_node_filter '.data.repository.pullRequest.reviewThreads.nodes = [{}]'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes = [null]'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes = ["comment-node"]'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes = [{}]'

# Required fields on otherwise object-shaped nodes retain their GraphQL types.
expect_invalid_node_filter '.data.repository.pullRequest.comments.nodes[0].body = 7'
expect_invalid_node_filter '.data.repository.pullRequest.comments.nodes[0].body = null'
expect_invalid_node_filter '.data.repository.pullRequest.reviews.nodes = [{author: null, submittedAt: null, state: 7, body: "review", url: "https://example.test/review/1"}]'
expect_invalid_node_filter '.data.repository.pullRequest.reviews.nodes = [{author: null, submittedAt: null, state: null, body: "review", url: "https://example.test/review/1"}]'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].id = 7'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].id = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved = "false"'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].path = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].diffSide = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].id = 7'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].id = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].path = null'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].outdated = "false"'
expect_invalid_thread_filter '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].outdated = null'

# PageInfo fields must retain their GraphQL scalar types.
for malformed in has-next cursor; do
  fixture="$(new_fixture)"
  write_page "${fixture}" 1 false cursor-1 ignored
  case "${malformed}" in
    has-next)
      jq '.data.repository.pullRequest.comments.pageInfo.hasNextPage = "false"' \
        "${fixture}/page-1.json" >"${fixture}/shape.tmp"
      ;;
    cursor)
      jq '.data.repository.pullRequest.comments.pageInfo.endCursor = 7' \
        "${fixture}/page-1.json" >"${fixture}/shape.tmp"
      ;;
  esac
  mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
  expect_failure invalid-node-payload run_collector "${fixture}"
done

# Every inline review thread must contain a complete comments connection.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.data.repository.pullRequest.reviewThreads.nodes = [{id: "thread-1", comments: null}]' \
  "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
expect_failure invalid-node-payload run_collector "${fixture}"

fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.data.repository.pullRequest.reviewThreads.nodes = [{id: "thread-1", comments: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: ["comment-node"]}}]' \
  "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
expect_failure invalid-node-payload run_collector "${fixture}"

fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
jq '.data.repository.pullRequest.reviewThreads.nodes = [{id: "thread-1", comments: {pageInfo: {hasNextPage: true, endCursor: "comment-1"}, nodes: []}}]' \
  "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
expect_failure invalid-node-payload run_collector "${fixture}"

# Legitimate nullable author, submittedAt, and line fields are preserved.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
write_review_thread "${fixture}"
jq '
  .data.repository.pullRequest.comments.nodes = [{
    author: null,
    createdAt: "2026-01-01T00:00:01Z",
    body: "issue comment",
    url: "https://example.test/comment/nullable"
  }]
  | .data.repository.pullRequest.reviews.nodes = [{
    author: null,
    submittedAt: null,
    state: "COMMENTED",
    body: "review",
    url: "https://example.test/review/nullable"
  }]
  | .data.repository.pullRequest.reviewThreads.nodes[0] |= (
    .line = null
    | .startLine = null
    | .originalLine = null
    | .originalStartLine = null
    | .comments.nodes[0].author = null
    | .comments.nodes[0].line = null
    | .comments.nodes[0].startLine = null
    | .comments.nodes[0].originalLine = null
    | .comments.nodes[0].originalStartLine = null
  )
' "${fixture}/page-1.json" >"${fixture}/shape.tmp"
mv -- "${fixture}/shape.tmp" "${fixture}/page-1.json"
output="$(run_collector "${fixture}")"
printf '%s\n' "${output}" | jq -e '
  .issueComments[0].author == null
  and .reviews[0].author == null
  and .reviews[0].submittedAt == null
  and .reviewThreads[0].line == null
  and .reviewThreads[0].startLine == null
  and .reviewThreads[0].originalLine == null
  and .reviewThreads[0].originalStartLine == null
  and .reviewThreads[0].comments.nodes[0].author == null
  and .reviewThreads[0].comments.nodes[0].line == null
  and .reviewThreads[0].comments.nodes[0].startLine == null
  and .reviewThreads[0].comments.nodes[0].originalLine == null
  and .reviewThreads[0].comments.nodes[0].originalStartLine == null
' >/dev/null

# A complete review-thread comments connection remains part of the output.
fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 ignored
write_review_thread "${fixture}"
output="$(run_collector "${fixture}")"
printf '%s\n' "${output}" | jq -e '
  (.reviewThreads | length) == 1
  and (.reviewThreads[0].comments.nodes | length) == 1
' >/dev/null

# A repeated cursor cannot spin indefinitely.
fixture="$(new_fixture)"
write_page "${fixture}" 1 true cursor-1 first
write_page "${fixture}" 2 true cursor-1 repeated
cp "${fixture}/page-2.json" "${fixture}/page-last.json"
expect_failure cursor-not-progressing:comments run_collector "${fixture}"
[ "$(<"${fixture}/.count")" = 2 ]

# Each finite resource limit is independently exercised with a lower test cap.
fixture="$(new_fixture)"
write_page "${fixture}" 1 true cursor-1 first
COLLECT_REVIEW_MAX_PAGES=1 expect_failure max-pages-exceeded run_collector "${fixture}"

fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 first
jq '.data.repository.pullRequest.comments.nodes += [{author: {login: "octocat"}, createdAt: "2026-01-01T00:00:02Z", body: "second", url: "https://example.test/comment/2"}]' \
  "${fixture}/page-1.json" >"${fixture}/nodes.tmp"
mv -- "${fixture}/nodes.tmp" "${fixture}/page-1.json"
COLLECT_REVIEW_MAX_NODES=1 expect_failure page-node-count-exceeded run_collector "${fixture}"

fixture="$(new_fixture)"
write_page "${fixture}" 1 false cursor-1 "$(printf '%2048s' x)"
COLLECT_REVIEW_MAX_PAGE_BYTES=1024 expect_failure page-size-exceeded run_collector "${fixture}"

fixture="$(new_fixture)"
write_page "${fixture}" 1 true cursor-1 "$(printf '%700s' x)"
write_page "${fixture}" 2 false cursor-2 "$(printf '%700s' x)"
cp "${fixture}/page-2.json" "${fixture}/page-last.json"
COLLECT_REVIEW_MAX_TOTAL_BYTES=2048 expect_failure response-size-exceeded run_collector "${fixture}"

# Successful and failed runs leave no collector-owned temporary directories.
if find "${test_root}/tmp" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
  printf 'FAIL: collector temporary directory was not cleaned\n' >&2
  exit 1
fi

printf 'collect_pr_review_context_test.PASS=bounded pagination, GraphQL errors, cursor progress, and cleanup\n'
