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

repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"
repo="${repo,,}"
owner="${repo%%/*}"
name="${repo#*/}"

if [ -z "${pr_ref}" ]; then
  pr_number="$(gh pr view --json number --jq '.number')"
elif printf '%s' "${pr_ref}" | grep -Eq '^[0-9]+$'; then
  pr_number="${pr_ref}"
else
  normalized_pr_ref="${pr_ref,,}"
  if [[ "${normalized_pr_ref}" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
    requested_repo="${BASH_REMATCH[1],,}/${BASH_REMATCH[2],,}"
    if [ "${requested_repo}" != "${repo}" ]; then
      printf 'review_context.error=pr-repository-mismatch:%s\n' "${requested_repo}" >&2
      exit 1
    fi
    pr_number="${BASH_REMATCH[3]}"
  else
    printf 'review_context.error=invalid-pr-ref:%s\n' "${pr_ref}" >&2
    exit 2
  fi
fi

expected_pr_url="https://github.com/${repo}/pull/${pr_number}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

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
>"${tmp_dir}/issue-comments.jsonl"
>"${tmp_dir}/reviews.jsonl"
>"${tmp_dir}/review-threads.jsonl"
while :; do
  page=$((page + 1))
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

  if ! gh "${gh_args[@]}" > "${tmp_dir}/page-${page}.json"; then
    printf 'review_context.error=graphql-request-failed:page-%s\n' "${page}" >&2
    exit 1
  fi

  if ! jq -e \
    --argjson number "${pr_number}" \
    --arg expected_url "${expected_pr_url}" \
    --argjson include_comments "${include_comments}" \
    --argjson include_reviews "${include_reviews}" \
    --argjson include_review_threads "${include_review_threads}" '
      def connection_ok($name; $enabled):
        if ($enabled | not) then
          true
        else
          (.data.repository.pullRequest[$name]) as $connection |
          if ($connection | type) != "object"
             or ($connection.nodes | type) != "array"
             or ($connection.pageInfo | type) != "object"
             or ($connection.pageInfo.hasNextPage | type) != "boolean" then
            false
          elif $connection.pageInfo.hasNextPage then
            (($connection.pageInfo.endCursor | type) == "string"
             and ($connection.pageInfo.endCursor | length) > 0)
          else
            true
          end
        end;
      ((has("errors") | not)
       or ((.errors | type) == "array" and (.errors | length) == 0))
      and (.data | type == "object")
      and (.data.repository | type == "object")
      and (.data.repository.pullRequest | type == "object")
      and (.data.repository.pullRequest.number == $number)
      and ((.data.repository.pullRequest.url | type == "string")
           and ((.data.repository.pullRequest.url | sub("/$"; "") | ascii_downcase)
                == ($expected_url | ascii_downcase)))
      and connection_ok("comments"; $include_comments)
      and connection_ok("reviews"; $include_reviews)
      and connection_ok("reviewThreads"; $include_review_threads)
    ' "${tmp_dir}/page-${page}.json" >/dev/null; then
    printf 'review_context.error=graphql-payload-invalid:page-%s\n' "${page}" >&2
    exit 1
  fi

  if [ "${comments_done}" != "true" ]; then
    jq -c '.data.repository.pullRequest.comments.nodes[]?' "${tmp_dir}/page-${page}.json" >> "${tmp_dir}/issue-comments.jsonl"
    comments_has_next="$(jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage' "${tmp_dir}/page-${page}.json")"
    comments_after="$(jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor // ""' "${tmp_dir}/page-${page}.json")"
    if [ "${comments_has_next}" != "true" ]; then
      comments_done="true"
    fi
  fi

  if [ "${reviews_done}" != "true" ]; then
    jq -c '.data.repository.pullRequest.reviews.nodes[]?' "${tmp_dir}/page-${page}.json" >> "${tmp_dir}/reviews.jsonl"
    reviews_has_next="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' "${tmp_dir}/page-${page}.json")"
    reviews_after="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor // ""' "${tmp_dir}/page-${page}.json")"
    if [ "${reviews_has_next}" != "true" ]; then
      reviews_done="true"
    fi
  fi

  if [ "${review_threads_done}" != "true" ]; then
    jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?' "${tmp_dir}/page-${page}.json" >> "${tmp_dir}/review-threads.jsonl"
    review_threads_has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' "${tmp_dir}/page-${page}.json")"
    review_threads_after="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' "${tmp_dir}/page-${page}.json")"
    if [ "${review_threads_has_next}" != "true" ]; then
      review_threads_done="true"
    fi
  fi

  if [ "${comments_done}" = "true" ] && [ "${reviews_done}" = "true" ] && [ "${review_threads_done}" = "true" ]; then
    break
  fi
done

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
gh pr list --repo "${repo}" --state open --json number,title,headRefName,baseRefName,files,body 2>/dev/null \
  | jq --argjson self "${pr_number}" \
       '[.[] | select(.number != $self)
              | {number,title,headRefName,baseRefName,
                 files:[.files[].path],
                 body:((.body // "")[:600])}]' \
  > "${tmp_dir}/sibling-prs.json" 2>/dev/null || printf '[]' > "${tmp_dir}/sibling-prs.json"

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
