#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: collect-pr-review-context.sh [<pr-number-or-url>] [--format jsonl|markdown|json]

Collect GitHub PR review context through GraphQL, including inline review
threads that `gh pr view --comments` can omit or flatten too aggressively.

Inputs:
  <pr-number-or-url>       Optional. Defaults to the PR for the current branch.
  --format jsonl           JSON Lines events for agent handoff. Default.
  --format markdown        Human-readable output.
  --format json            Raw aggregated JSON payload.

Output:
  Writes the requested format to stdout. The script does not mutate GitHub state.

Safety limits:
  The collector caps GraphQL pages, returned nodes, and temporary response
  bytes. Tests may request a lower limit with COLLECT_REVIEW_MAX_* variables;
  values above the hard cap are rejected.
USAGE
}

format="jsonl"
pr_ref=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      if [ "$#" -lt 2 ]; then
        printf 'review_context.error=missing-format-value\n' >&2
        exit 2
      fi
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -n "${pr_ref}" ]; then
        printf 'review_context.error=too-many-pr-refs\n' >&2
        exit 2
      fi
      pr_ref="$1"
      shift
      ;;
  esac
done

if [ "${format}" != "jsonl" ] && [ "${format}" != "markdown" ] && [ "${format}" != "json" ]; then
  printf 'review_context.error=invalid-format:%s\n' "${format}" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'review_context.error=missing-gh\n' >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'review_context.error=missing-jq\n' >&2
  exit 127
fi

read_limit() {
  local variable="$1" default="$2" hard_cap="$3" value
  value="${!variable-}"
  if [ -z "${value}" ]; then
    printf '%s\n' "${default}"
    return 0
  fi
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]] || [ "${value}" -gt "${hard_cap}" ]; then
    printf 'review_context.error=invalid-limit:%s\n' "${variable}" >&2
    return 2
  fi
  printf '%s\n' "${value}"
}

# The defaults are intentionally finite. Environment overrides are useful for
# deterministic fixture tests and can only lower these hard limits.
max_pages="$(read_limit COLLECT_REVIEW_MAX_PAGES 100 100)"
max_nodes="$(read_limit COLLECT_REVIEW_MAX_NODES 10000 10000)"
max_page_bytes="$(read_limit COLLECT_REVIEW_MAX_PAGE_BYTES $((4 * 1024 * 1024)) $((4 * 1024 * 1024)))"
max_total_bytes="$(read_limit COLLECT_REVIEW_MAX_TOTAL_BYTES $((16 * 1024 * 1024)) $((16 * 1024 * 1024)))"

collector_error() {
  printf 'review_context.error=%s\n' "$1" >&2
  exit 1
}

repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"
owner="${repo%%/*}"
name="${repo#*/}"

if [ -z "${pr_ref}" ]; then
  pr_number="$(gh pr view --json number --jq '.number')"
elif printf '%s' "${pr_ref}" | grep -Eq '^[0-9]+$'; then
  pr_number="${pr_ref}"
else
  pr_number="$(printf '%s\n' "${pr_ref}" | sed -E 's#^.*/pull/([0-9]+).*#\1#')"
  if ! printf '%s' "${pr_number}" | grep -Eq '^[0-9]+$'; then
    printf 'review_context.error=invalid-pr-ref:%s\n' "${pr_ref}" >&2
    exit 2
  fi
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  if [ -n "${tmp_dir:-}" ] && [ -d "${tmp_dir}" ]; then
    rm -rf -- "${tmp_dir}"
  fi
}
trap cleanup EXIT

query='
query($owner: String!, $name: String!, $number: Int!, $commentsAfter: String, $reviewsAfter: String, $reviewThreadsAfter: String, $includeComments: Boolean!, $includeReviews: Boolean!, $includeReviewThreads: Boolean!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      title
      url
      state
      isDraft
      baseRefOid
      headRefOid
      comments(first: 100, after: $commentsAfter) @include(if: $includeComments) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          author { login }
          createdAt
          body
          url
        }
      }
      reviews(first: 100, after: $reviewsAfter) @include(if: $includeReviews) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          author { login }
          submittedAt
          state
          body
          url
        }
      }
      reviewThreads(first: 50, after: $reviewThreadsAfter) @include(if: $includeReviewThreads) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          originalLine
          originalStartLine
          diffSide
          startDiffSide
          comments(first: 50) {
            pageInfo {
              hasNextPage
            }
            nodes {
              id
              author { login }
              createdAt
              body
              url
              path
              line
              startLine
              originalLine
              originalStartLine
              diffHunk
              outdated
            }
          }
        }
      }
    }
  }
}'

comments_after=""
reviews_after=""
review_threads_after=""
comments_done="false"
reviews_done="false"
review_threads_done="false"
page=0
node_total=0
response_bytes_total=0
>"${tmp_dir}/issue-comments.jsonl"
>"${tmp_dir}/reviews.jsonl"
>"${tmp_dir}/review-threads.jsonl"

ensure_cursor_progress() {
  local stream="$1" previous="$2" has_next="$3" next="$4"
  if [ "${has_next}" != "true" ] && [ "${has_next}" != "false" ]; then
    collector_error "invalid-page-info:${stream}"
  fi
  if [ "${next}" = "__invalid__" ]; then
    collector_error "invalid-cursor:${stream}"
  fi
  if [ "${has_next}" = "true" ]; then
    if [ -z "${next}" ]; then
      collector_error "missing-cursor:${stream}"
    fi
    if [ "${next}" = "${previous}" ]; then
      collector_error "cursor-not-progressing:${stream}"
    fi
  fi
}

count_page_nodes() {
  jq -er '
    def connection_nodes($connection; $label):
      if $connection == null then 0
      elif ($connection | type) != "object" then error($label + "-connection-shape")
      elif (($connection.nodes // []) | type) != "array" then error($label + "-nodes-shape")
      else ($connection.nodes // [] | length)
      end;
    def thread_comments($connection):
      if $connection == null then 0
      elif ($connection | type) != "object" then error("thread-connection-shape")
      elif (($connection.nodes // []) | type) != "array" then error("thread-nodes-shape")
      else reduce ($connection.nodes // [])[] as $thread (0;
        . + (
          if ($thread.comments // null) == null then 0
          elif ($thread.comments | type) != "object" then error("thread-comments-shape")
          elif (($thread.comments.nodes // []) | type) != "array" then error("thread-comment-nodes-shape")
          else ($thread.comments.nodes // [] | length)
          end
        )
      )
      end;
    .data.repository.pullRequest as $pr |
    [
      connection_nodes($pr.comments; "comments"),
      connection_nodes($pr.reviews; "reviews"),
      connection_nodes($pr.reviewThreads; "review-threads"),
      thread_comments($pr.reviewThreads)
    ] | add
  ' "$1" 2>/dev/null
}

validate_thread_comment_page_info() {
  local page_file="$1"
  if ! jq -e '
    all(
      (.data.repository.pullRequest.reviewThreads.nodes // [])[]?;
      (.comments | type) == "object" and
      (.comments.pageInfo | type) == "object" and
      (.comments.pageInfo.hasNextPage | type) == "boolean"
    )
  ' "${page_file}" >/dev/null 2>&1; then
    collector_error "invalid-page-info:review-thread-comments"
  fi
  if jq -e '
    any(
      (.data.repository.pullRequest.reviewThreads.nodes // [])[]?;
      .comments.pageInfo.hasNextPage == true
    )
  ' "${page_file}" >/dev/null 2>&1; then
    collector_error "thread-comments-truncated"
  fi
}

check_aggregate_bytes() {
  local aggregate_bytes file
  aggregate_bytes=0
  for file in \
    "${tmp_dir}/issue-comments.jsonl" \
    "${tmp_dir}/reviews.jsonl" \
    "${tmp_dir}/review-threads.jsonl"; do
    local file_bytes
    file_bytes="$(wc -c <"${file}" | tr -d '[:space:]')"
    if ! printf '%s\n' "${file_bytes}" | grep -Eq '^[0-9]+$'; then
      collector_error "invalid-temporary-size"
    fi
    aggregate_bytes=$((aggregate_bytes + file_bytes))
  done
  if [ "${aggregate_bytes}" -gt "${max_total_bytes}" ]; then
    collector_error "aggregate-size-exceeded"
  fi
}

while :; do
  page=$((page + 1))
  if [ "${page}" -gt "${max_pages}" ]; then
    collector_error "max-pages-exceeded"
  fi
  include_comments="true"
  include_reviews="true"
  include_review_threads="true"
  if [ "${comments_done}" = "true" ]; then
    include_comments="false"
  fi
  if [ "${reviews_done}" = "true" ]; then
    include_reviews="false"
  fi
  if [ "${review_threads_done}" = "true" ]; then
    include_review_threads="false"
  fi

  gh_args=(
    api graphql
    -f query="${query}"
    -f owner="${owner}"
    -f name="${name}"
    -F number="${pr_number}"
    -F includeComments="${include_comments}"
    -F includeReviews="${include_reviews}"
    -F includeReviewThreads="${include_review_threads}"
  )
  if [ "${comments_done}" != "true" ] && [ -n "${comments_after}" ]; then
    gh_args+=(-f commentsAfter="${comments_after}")
  fi
  if [ "${reviews_done}" != "true" ] && [ -n "${reviews_after}" ]; then
    gh_args+=(-f reviewsAfter="${reviews_after}")
  fi
  if [ "${review_threads_done}" != "true" ] && [ -n "${review_threads_after}" ]; then
    gh_args+=(-f reviewThreadsAfter="${review_threads_after}")
  fi

  page_file="${tmp_dir}/page-${page}.json"
  if ! gh "${gh_args[@]}" >"${page_file}"; then
    collector_error "github-query-failed"
  fi
  page_bytes="$(wc -c <"${page_file}" | tr -d '[:space:]')"
  if ! printf '%s\n' "${page_bytes}" | grep -Eq '^[0-9]+$' || [ "${page_bytes}" -gt "${max_page_bytes}" ]; then
    collector_error "page-size-exceeded"
  fi
  response_bytes_total=$((response_bytes_total + page_bytes))
  if [ "${response_bytes_total}" -gt "${max_total_bytes}" ]; then
    collector_error "response-size-exceeded"
  fi
  if ! jq -e '(.errors // []) | (type == "array" and length == 0)' "${page_file}" >/dev/null 2>&1; then
    collector_error "graphql-errors"
  fi
  if ! jq -e '.data.repository.pullRequest | type == "object"' "${page_file}" >/dev/null 2>&1; then
    collector_error "invalid-graphql-payload"
  fi
  if ! page_nodes="$(count_page_nodes "${page_file}")"; then
    collector_error "invalid-node-payload"
  fi
  if [ "${page_nodes}" -gt "${max_nodes}" ]; then
    collector_error "page-node-count-exceeded"
  fi
  node_total=$((node_total + page_nodes))
  if [ "${node_total}" -gt "${max_nodes}" ]; then
    collector_error "node-count-exceeded"
  fi

  if [ "${comments_done}" != "true" ]; then
    jq -c '.data.repository.pullRequest.comments.nodes[]?' "${tmp_dir}/page-${page}.json" >> "${tmp_dir}/issue-comments.jsonl"
    comments_has_next="$(jq -r '
      .data.repository.pullRequest.comments.pageInfo.hasNextPage as $value |
      if ($value | type) == "boolean" then ($value | tostring) else "__invalid__" end
    ' "${page_file}")"
    comments_next="$(jq -r '
      .data.repository.pullRequest.comments.pageInfo.endCursor as $value |
      if $value == null then ""
      elif ($value | type) == "string" then $value
      else "__invalid__"
      end
    ' "${page_file}")"
    ensure_cursor_progress "comments" "${comments_after}" "${comments_has_next}" "${comments_next}"
    comments_after="${comments_next}"
    if [ "${comments_has_next}" != "true" ]; then
      comments_done="true"
    fi
  fi

  if [ "${reviews_done}" != "true" ]; then
    jq -c '.data.repository.pullRequest.reviews.nodes[]?' "${page_file}" >> "${tmp_dir}/reviews.jsonl"
    reviews_has_next="$(jq -r '
      .data.repository.pullRequest.reviews.pageInfo.hasNextPage as $value |
      if ($value | type) == "boolean" then ($value | tostring) else "__invalid__" end
    ' "${page_file}")"
    reviews_next="$(jq -r '
      .data.repository.pullRequest.reviews.pageInfo.endCursor as $value |
      if $value == null then ""
      elif ($value | type) == "string" then $value
      else "__invalid__"
      end
    ' "${page_file}")"
    ensure_cursor_progress "reviews" "${reviews_after}" "${reviews_has_next}" "${reviews_next}"
    reviews_after="${reviews_next}"
    if [ "${reviews_has_next}" != "true" ]; then
      reviews_done="true"
    fi
  fi

  if [ "${review_threads_done}" != "true" ]; then
    validate_thread_comment_page_info "${page_file}"
    jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?' "${page_file}" >> "${tmp_dir}/review-threads.jsonl"
    review_threads_has_next="$(jq -r '
      .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage as $value |
      if ($value | type) == "boolean" then ($value | tostring) else "__invalid__" end
    ' "${page_file}")"
    review_threads_next="$(jq -r '
      .data.repository.pullRequest.reviewThreads.pageInfo.endCursor as $value |
      if $value == null then ""
      elif ($value | type) == "string" then $value
      else "__invalid__"
      end
    ' "${page_file}")"
    ensure_cursor_progress "review-threads" "${review_threads_after}" "${review_threads_has_next}" "${review_threads_next}"
    review_threads_after="${review_threads_next}"
    if [ "${review_threads_has_next}" != "true" ]; then
      review_threads_done="true"
    fi
  fi

  check_aggregate_bytes
  if [ "${page}" -gt 1 ]; then
    rm -f -- "${page_file}"
  fi

  if [ "${comments_done}" = "true" ] && [ "${reviews_done}" = "true" ] && [ "${review_threads_done}" = "true" ]; then
    break
  fi
done

check_aggregate_bytes

jq -n \
  --slurpfile first_page "${tmp_dir}/page-1.json" \
  --slurpfile issue_comments "${tmp_dir}/issue-comments.jsonl" \
  --slurpfile reviews "${tmp_dir}/reviews.jsonl" \
  --slurpfile review_threads "${tmp_dir}/review-threads.jsonl" '
  $first_page[0].data.repository.pullRequest as $pr |
  {
    pullRequest: {
      number: $pr.number,
      title: $pr.title,
      url: $pr.url,
      state: $pr.state,
      isDraft: $pr.isDraft,
      baseRefOid: $pr.baseRefOid,
      headRefOid: $pr.headRefOid
    },
    issueComments: $issue_comments,
    reviews: $reviews,
    reviewThreads: $review_threads
  }
' > "${tmp_dir}/review-context.json"

# Sibling open PRs (cross-PR dependency context). Excludes this PR itself.
# Lets a resolver/reviewer see what other still-open PRs introduce or cite,
# e.g. a counter that "does not exist yet" because it lands in another PR.
sibling_raw="${tmp_dir}/sibling-prs.raw.json"
if gh pr list --state open --limit 101 --json number,title,headRefName,baseRefName,files,body >"${sibling_raw}" 2>/dev/null; then
  sibling_bytes="$(wc -c <"${sibling_raw}" | tr -d '[:space:]')"
  if ! printf '%s\n' "${sibling_bytes}" | grep -Eq '^[0-9]+$' || [ "${sibling_bytes}" -gt "${max_page_bytes}" ]; then
    collector_error "sibling-size-exceeded"
  fi
  if ! jq -e 'type == "array"' "${sibling_raw}" >/dev/null 2>&1; then
    collector_error "invalid-sibling-payload"
  fi
  sibling_count="$(jq -er 'length' "${sibling_raw}" 2>/dev/null)" || collector_error "invalid-sibling-payload"
  if [ "${sibling_count}" -gt 100 ]; then
    collector_error "sibling-prs-truncated"
  fi
  if ! jq --argjson self "${pr_number}" \
       '[.[] | select(.number != $self)
              | {number,title,headRefName,baseRefName,
                 files:[.files[].path],
                 body:((.body // "")[:600])}]
        | .[:100]' \
       "${sibling_raw}" >"${tmp_dir}/sibling-prs.json" 2>/dev/null; then
    collector_error "invalid-sibling-payload"
  fi
else
  collector_error "sibling-query-failed"
fi

if ! jq -e 'type == "array"' "${tmp_dir}/sibling-prs.json" >/dev/null 2>&1; then
  collector_error "invalid-sibling-payload"
fi
if ! jq --slurpfile sibling_prs "${tmp_dir}/sibling-prs.json" \
  '. + {siblingPullRequests: ($sibling_prs[0] // [])}' \
  "${tmp_dir}/review-context.json" >"${tmp_dir}/review-context.with-siblings.json"; then
  collector_error "invalid-review-context"
fi
mv -- "${tmp_dir}/review-context.with-siblings.json" "${tmp_dir}/review-context.json"

if [ "${format}" = "json" ]; then
  cat "${tmp_dir}/review-context.json"
  exit 0
fi

if [ "${format}" = "jsonl" ]; then
  jq -c '
    {type:"pr_review_context", data:.pullRequest},
    (.issueComments[]? | {type:"pr_issue_comment", data:.}),
    (.reviews[]? | {type:"pr_review", data:.}),
    (.reviewThreads[]? | {type:"pr_review_thread", data:{
      id,
      isResolved,
      isOutdated,
      path,
      line,
      startLine,
      originalLine,
      originalStartLine,
      diffSide,
      startDiffSide
    }}),
    (.reviewThreads[]? as $thread | $thread.comments.nodes[]? | {type:"pr_review_thread_comment", thread_id:$thread.id, data:.})
  ' "${tmp_dir}/review-context.json"
  jq -c '.[] | {type:"pr_sibling_pr", data:.}' "${tmp_dir}/sibling-prs.json" 2>/dev/null || true
  exit 0
fi

jq -r '
  def user($node): ($node.author.login // "unknown");
  def body($node): (($node.body // "") | split("\n") | map("> " + .) | join("\n"));
  def loc($node):
    [
      ("path=" + (($node.path // "") | tostring)),
      ("line=" + (($node.line // $node.originalLine // "") | tostring)),
      ("startLine=" + (($node.startLine // $node.originalStartLine // "") | tostring))
    ] | join(" ");

  "# PR Review Context",
  "",
  ("review_context.pr=#" + (.pullRequest.number | tostring)),
  ("review_context.title=" + .pullRequest.title),
  ("review_context.url=" + .pullRequest.url),
  ("review_context.state=" + .pullRequest.state),
  ("review_context.is_draft=" + (.pullRequest.isDraft | tostring)),
  ("review_context.issue_comments=" + (.issueComments | length | tostring)),
  ("review_context.reviews=" + (.reviews | length | tostring)),
  ("review_context.review_threads=" + (.reviewThreads | length | tostring)),
  "",
  "## Issue Comments",
  (
    if (.issueComments | length) == 0 then
      "none"
    else
      (.issueComments[] |
        "### issue-comment by " + user(.) + " at " + (.createdAt // "") + "\n" +
        "url=" + (.url // "") + "\n" +
        body(.)
      )
    end
  ),
  "",
  "## Reviews",
  (
    if (.reviews | length) == 0 then
      "none"
    else
      (.reviews[] |
        "### review " + (.state // "UNKNOWN") + " by " + user(.) + " at " + (.submittedAt // "") + "\n" +
        "url=" + (.url // "") + "\n" +
        body(.)
      )
    end
  ),
  "",
  "## Inline Review Threads",
  (
    if (.reviewThreads | length) == 0 then
      "none"
    else
      (.reviewThreads[] |
        "### thread " + (.id // "") + "\n" +
        "status=" + (if .isResolved then "resolved" else "open" end) +
        " outdated=" + (.isOutdated | tostring) +
        " " + loc(.) + "\n" +
        (
          if ((.comments.nodes // []) | length) == 0 then
            "comments=none"
          else
            (.comments.nodes[] |
              "#### comment " + (.id // "") + " by " + user(.) + " at " + (.createdAt // "") + "\n" +
              "url=" + (.url // "") + "\n" +
              "location=" + loc(.) + "\n" +
              "diff_hunk:\n```diff\n" + (.diffHunk // "") + "\n```\n" +
              body(.)
            )
          end
        )
      )
    end
  )
' "${tmp_dir}/review-context.json"

echo ""
echo "## Sibling Open PRs (cross-PR dependency context)"
if [ -s "${tmp_dir}/sibling-prs.json" ] \
  && [ "$(jq 'length' "${tmp_dir}/sibling-prs.json" 2>/dev/null || echo 0)" -gt 0 ]; then
  jq -r '.[] | "### #\(.number) \(.title)\nbranch=\(.headRefName) base=\(.baseRefName)\nfiles: \(.files | join(", "))\nbody: \(.body)\n"' \
    "${tmp_dir}/sibling-prs.json"
else
  echo "none"
fi
