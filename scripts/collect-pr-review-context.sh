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
              endCursor
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
  local page_file="$1" include_comments="$2" include_reviews="$3" include_review_threads="$4"
  jq -er \
    --argjson include_comments "${include_comments}" \
    --argjson include_reviews "${include_reviews}" \
    --argjson include_review_threads "${include_review_threads}" '
    # Selected GraphQL fields are checked at the node boundary. Actor authors,
    # review submittedAt, line fields, and startDiffSide are nullable; every
    # other selected scalar field is required when its node is present.
    def required_type($node; $field; $expected):
      if ($node | type) != "object" then
        false
      elif (($node | has($field)) | not) then
        false
      else
        ($node[$field] | type) == $expected
      end;
    def required_integer($node; $field):
      if required_type($node; $field; "number") then
        (($node[$field] | floor) == $node[$field])
      else
        false
      end;
    def nullable_type($node; $field; $expected):
      if ($node | type) != "object" then
        false
      elif (($node | has($field)) | not) then
        false
      elif $node[$field] == null then
        true
      else
        ($node[$field] | type) == $expected
      end;
    def nullable_integer($node; $field):
      if ($node | type) != "object" or (($node | has($field)) | not) then
        false
      elif $node[$field] == null then
        true
      elif ($node[$field] | type) != "number" then
        false
      else
        (($node[$field] | floor) == $node[$field])
      end;
    def nullable_author($node):
      if ($node | type) != "object" then
        false
      elif (($node | has("author")) | not) then
        false
      elif $node.author == null then
        true
      elif ($node.author | type) != "object" then
        false
      else
        required_type($node.author; "login"; "string")
      end;
    def issue_comment_node($node):
      ($node | type) == "object"
      and nullable_author($node)
      and required_type($node; "createdAt"; "string")
      and required_type($node; "body"; "string")
      and required_type($node; "url"; "string");
    def review_node($node):
      ($node | type) == "object"
      and nullable_author($node)
      and nullable_type($node; "submittedAt"; "string")
      and required_type($node; "state"; "string")
      and required_type($node; "body"; "string")
      and required_type($node; "url"; "string");
    def review_thread_node($node):
      ($node | type) == "object"
      and required_type($node; "id"; "string")
      and required_type($node; "isResolved"; "boolean")
      and required_type($node; "isOutdated"; "boolean")
      and required_type($node; "path"; "string")
      and nullable_integer($node; "line")
      and nullable_integer($node; "startLine")
      and nullable_integer($node; "originalLine")
      and nullable_integer($node; "originalStartLine")
      and required_type($node; "diffSide"; "string")
      and nullable_type($node; "startDiffSide"; "string")
      and required_type($node; "comments"; "object");
    def review_thread_comment_node($node):
      ($node | type) == "object"
      and required_type($node; "id"; "string")
      and nullable_author($node)
      and required_type($node; "createdAt"; "string")
      and required_type($node; "body"; "string")
      and required_type($node; "url"; "string")
      and required_type($node; "path"; "string")
      and nullable_integer($node; "line")
      and nullable_integer($node; "startLine")
      and nullable_integer($node; "originalLine")
      and nullable_integer($node; "originalStartLine")
      and required_type($node; "diffHunk"; "string")
      and required_type($node; "outdated"; "boolean");
    def node_matches($node; $kind):
      if $kind == "comments" then
        issue_comment_node($node)
      elif $kind == "reviews" then
        review_node($node)
      elif $kind == "review-threads" then
        review_thread_node($node)
      elif $kind == "thread-comments" then
        review_thread_comment_node($node)
      else
        false
      end;
    def page_info($connection; $label):
      ($connection.pageInfo) as $page_info |
      if ($page_info | type) != "object" then
        error($label + "-page-info-shape")
      elif (($page_info.hasNextPage | type) != "boolean") then
        error($label + "-has-next-shape")
      elif ($page_info.endCursor != null and (($page_info.endCursor | type) != "string")) then
        error($label + "-cursor-shape")
      else
        $page_info
      end;
    def object_nodes($connection; $label; $kind):
      ($connection.nodes) as $nodes |
      if ($nodes | type) != "array" then
        error($label + "-nodes-shape")
      elif any($nodes[]?; (node_matches(.; $kind) | not)) then
        error($label + "-node-shape")
      else
        $nodes
      end;
    def connection_nodes($connection; $label):
      if ($connection | type) != "object" then
        error($label + "-connection-shape")
      else
        page_info($connection; $label) | object_nodes($connection; $label; $label) | length
      end;
    def thread_comments($thread):
      ($thread.comments) as $comments |
      if ($comments | type) != "object" then
        error("thread-comments-connection-shape")
      else
        page_info($comments; "thread-comments") as $page_info |
        if $page_info.hasNextPage then
          error("thread-comments-truncated")
        else
          object_nodes($comments; "thread-comments"; "thread-comments") | length
        end
      end;
    def review_thread_nodes($connection):
      if ($connection | type) != "object" then
        error("review-threads-connection-shape")
      else
        page_info($connection; "review-threads") |
        object_nodes($connection; "review-threads"; "review-threads") as $threads |
        reduce $threads[] as $thread (0;
          . + 1 + thread_comments($thread)
        )
      end;
    .data.repository.pullRequest as $pr |
    [
      (if $include_comments then connection_nodes($pr.comments; "comments") else 0 end),
      (if $include_reviews then connection_nodes($pr.reviews; "reviews") else 0 end),
      (if $include_review_threads then review_thread_nodes($pr.reviewThreads) else 0 end)
    ] | add
  ' "${page_file}" 2>/dev/null
}

validate_pull_request_page() {
  local page_file="$1"
  jq -e '
    def required_type($node; $field; $expected):
      if ($node | type) != "object" then
        false
      elif (($node | has($field)) | not) then
        false
      else
        ($node[$field] | type) == $expected
      end;
    def required_integer($node; $field):
      if required_type($node; $field; "number") then
        (($node[$field] | floor) == $node[$field])
      else
        false
      end;
    .data.repository.pullRequest as $pr |
    ($pr | type) == "object"
    and required_integer($pr; "number")
    and (($pr.number > 0))
    and required_type($pr; "title"; "string")
    and required_type($pr; "url"; "string")
    and required_type($pr; "state"; "string")
    and required_type($pr; "isDraft"; "boolean")
  ' "${page_file}" >/dev/null 2>&1
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
  if ! validate_pull_request_page "${page_file}"; then
    collector_error "invalid-graphql-payload"
  fi
  if ! page_nodes="$(count_page_nodes "${page_file}" "${include_comments}" "${include_reviews}" "${include_review_threads}")"; then
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
      isDraft: $pr.isDraft
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
if ! gh pr list --state open --limit 100 --json number,title,headRefName,baseRefName,files,body >"${sibling_raw}" 2>/dev/null; then
  collector_error "sibling-query-failed"
fi
sibling_bytes="$(wc -c <"${sibling_raw}" | tr -d '[:space:]')"
if ! printf '%s\n' "${sibling_bytes}" | grep -Eq '^[0-9]+$' || [ "${sibling_bytes}" -gt "${max_page_bytes}" ]; then
  collector_error "sibling-size-exceeded"
fi
response_bytes_total=$((response_bytes_total + sibling_bytes))
if [ "${response_bytes_total}" -gt "${max_total_bytes}" ]; then
  collector_error "response-size-exceeded"
fi
if ! sibling_count="$(jq -er 'if type == "array" then length else error("array-required") end' "${sibling_raw}" 2>/dev/null)"; then
  collector_error "invalid-sibling-payload"
fi
if [ "${sibling_count}" -ge 100 ]; then
  collector_error "sibling-truncated"
fi
if ! jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.number | type == "number") and
      (.title | type == "string") and
      (.headRefName | type == "string") and
      (.baseRefName | type == "string") and
      (.files | type == "array") and
      all(.files[]; type == "object" and (.path | type == "string")) and
      ((.body == null) or (.body | type == "string"))
    )
  ' "${sibling_raw}" >/dev/null 2>&1; then
  collector_error "invalid-sibling-payload"
fi
if ! jq --argjson self "${pr_number}" \
     '[.[] | select(.number != $self)
            | {number,title,headRefName,baseRefName,
               files:[.files[].path],
               body:((.body // "")[:600])}]' \
     "${sibling_raw}" >"${tmp_dir}/sibling-prs.json" 2>/dev/null; then
  collector_error "invalid-sibling-payload"
fi

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
