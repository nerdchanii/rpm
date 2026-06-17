#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: watch-codex-review.sh <pr-number-or-url> [--request-review] [--start-time <iso8601>] [--timeout <seconds>] [--max-polls <count>] [--format jsonl|text]

Poll for Codex/GitHub PR review feedback.

Behavior:
  - If --request-review is set, post "@codex review" and use that time as start.
  - Poll every 15 seconds until review activity starts.
  - After review activity starts, poll every 180 seconds until review output is available.
  - Exit 30 when timeout or max-polls is reached before a terminal review signal.
  - Print JSONL progress events by default.
  - Exit 0 when review threads or submitted review output are found.
  - Exit 20 when no actionable review appears but a Codex thumbs-up reaction indicates no findings.

This script does not resolve threads or modify code.
USAGE
}

pr_ref=""
request_review="false"
start_time=""
initial_interval=15
started_interval=180
timeout_seconds=1800
max_polls=""
format="jsonl"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-review)
      request_review="true"
      shift
      ;;
    --start-time)
      if [ "$#" -lt 2 ]; then
        printf 'review_watch.error=missing-start-time-value\n' >&2
        exit 2
      fi
      start_time="$2"
      shift 2
      ;;
    --format)
      if [ "$#" -lt 2 ]; then
        printf 'review_watch.error=missing-format-value\n' >&2
        exit 2
      fi
      format="$2"
      shift 2
      ;;
    --timeout)
      if [ "$#" -lt 2 ]; then
        printf 'review_watch.error=missing-timeout-value\n' >&2
        exit 2
      fi
      timeout_seconds="$2"
      shift 2
      ;;
    --timeout=*)
      timeout_seconds="${1#--timeout=}"
      shift
      ;;
    --max-polls)
      if [ "$#" -lt 2 ]; then
        printf 'review_watch.error=missing-max-polls-value\n' >&2
        exit 2
      fi
      max_polls="$2"
      shift 2
      ;;
    --max-polls=*)
      max_polls="${1#--max-polls=}"
      shift
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
        printf 'review_watch.error=too-many-pr-refs\n' >&2
        exit 2
      fi
      pr_ref="$1"
      shift
      ;;
  esac
done

if [ "${format}" != "jsonl" ] && [ "${format}" != "text" ]; then
  printf 'review_watch.error=invalid-format:%s\n' "${format}" >&2
  exit 2
fi

case "${timeout_seconds}" in
  ''|*[!0-9]*)
    printf 'review_watch.error=invalid-timeout:%s\n' "${timeout_seconds}" >&2
    exit 2
    ;;
esac

if [ -n "${max_polls}" ]; then
  case "${max_polls}" in
    ''|*[!0-9]*)
      printf 'review_watch.error=invalid-max-polls:%s\n' "${max_polls}" >&2
      exit 2
      ;;
  esac
fi

if [ -z "${pr_ref}" ]; then
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'review_watch.error=missing-gh\n' >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'review_watch.error=missing-jq\n' >&2
  exit 127
fi

emit() {
  local event="$1"
  shift
  if [ "${format}" = "jsonl" ]; then
    jq -nc --arg type "${event}" "$@" '{type:$type, data:($ARGS.named | del(.type))}'
  else
    local name value
    while [ "$#" -gt 0 ]; do
      name="${2#--arg }"
      name="$2"
      value="$3"
      printf 'review_watch.%s=%s\n' "${name}" "${value}"
      shift 3
    done
  fi
}

if printf '%s' "${pr_ref}" | grep -Eq '^[0-9]+$'; then
  pr_number="${pr_ref}"
else
  pr_number="$(printf '%s\n' "${pr_ref}" | sed -E 's#^.*/pull/([0-9]+).*#\1#')"
  if ! printf '%s' "${pr_number}" | grep -Eq '^[0-9]+$'; then
    printf 'review_watch.error=invalid-pr-ref:%s\n' "${pr_ref}" >&2
    exit 2
  fi
fi

repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"
owner="${repo%%/*}"
name="${repo#*/}"

if [ "${request_review}" = "true" ]; then
  start_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  gh pr comment "${pr_number}" --body "@codex review" >/dev/null
  emit "review_watch_request" --arg requested "true"
else
  emit "review_watch_request" --arg requested "false"
  if [ -z "${start_time}" ]; then
    start_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
fi

emit "review_watch_config" \
  --arg pr "${pr_number}" \
  --arg start_time "${start_time}" \
  --arg initial_poll_seconds "${initial_interval}" \
  --arg started_poll_seconds "${started_interval}" \
  --arg timeout_seconds "${timeout_seconds}" \
  --arg max_polls "${max_polls}"

query='
query($owner: String!, $name: String!, $number: Int!, $reviewThreadsAfter: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      comments(last: 30) {
        nodes {
          author { login }
          createdAt
          body
          reactionGroups {
            content
            users(first: 20) {
              totalCount
              nodes {
                login
              }
            }
          }
        }
      }
      reviews(last: 30) {
        nodes {
          author { login }
          submittedAt
          state
          body
        }
      }
      reviewThreads(first: 100, after: $reviewThreadsAfter) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 20) {
            nodes {
              author { login }
              createdAt
              body
              url
            }
          }
        }
      }
    }
  }
}'

fetch_review_payload() {
  local temp_dir
  local after=""
  local page=0
  local page_file
  local has_next
  local merged

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-watch-review.XXXXXX")"

  while :; do
    page=$((page + 1))
    printf -v page_file '%s/page-%06d.json' "${temp_dir}" "${page}"
    if [ -n "${after}" ]; then
      gh api graphql \
        -f query="${query}" \
        -f owner="${owner}" \
        -f name="${name}" \
        -F number="${pr_number}" \
        -f reviewThreadsAfter="${after}" > "${page_file}"
    else
      gh api graphql \
        -f query="${query}" \
        -f owner="${owner}" \
        -f name="${name}" \
        -F number="${pr_number}" > "${page_file}"
    fi

    has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' "${page_file}")"
    after="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' "${page_file}")"
    if [ "${has_next}" != "true" ]; then
      break
    fi
  done

  merged="$(jq -s '
    . as $pages |
    $pages[0] as $first |
    $first
    | .data.repository.pullRequest.reviewThreads.nodes = ([$pages[].data.repository.pullRequest.reviewThreads.nodes[]?])
    | .data.repository.pullRequest.reviewThreads.pageInfo = {
        hasNextPage: false,
        endCursor: ($pages[-1].data.repository.pullRequest.reviewThreads.pageInfo.endCursor // null)
      }
  ' "${temp_dir}"/page-*.json)"
  rm -rf "${temp_dir}"
  printf '%s\n' "${merged}"
}

watch_started_at="$(date -u '+%s')"
review_started="false"
poll_count=0

while :; do
  poll_count=$((poll_count + 1))
  payload="$(fetch_review_payload)"

  review_count="$(printf '%s' "${payload}" | jq --arg start "${start_time}" '
    [.data.repository.pullRequest.reviews.nodes[]
      | select((.submittedAt // "") >= $start)
      | select((.author.login // "") == "chatgpt-codex-connector")
    ] | length
  ')"

  thread_count="$(printf '%s' "${payload}" | jq --arg start "${start_time}" '
    [.data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | .comments.nodes[]
      | select((.createdAt // "") >= $start)
      | select((.author.login // "") == "chatgpt-codex-connector")
    ] | length
  ')"

  codex_comment_count="$(printf '%s' "${payload}" | jq --arg start "${start_time}" '
    [.data.repository.pullRequest.comments.nodes[]
      | select((.createdAt // "") >= $start)
      | select((.author.login // "") == "chatgpt-codex-connector")
    ] | length
  ')"

  thumbs_up_count="$(printf '%s' "${payload}" | jq --arg start "${start_time}" '
    [.data.repository.pullRequest.comments.nodes[]
      | select((.createdAt // "") >= $start)
      | select((.body // "") == "@codex review")
      | .reactionGroups[]
      | select(.content == "THUMBS_UP")
      | .users.nodes[]
      | select((.login // "") == "chatgpt-codex-connector")
    ] | length
  ')"

  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  now_epoch="$(date -u '+%s')"
  elapsed_seconds=$((now_epoch - watch_started_at))

  if [ "${review_started}" = "false" ]; then
    if [ "${thread_count}" -gt 0 ] || [ "${review_count}" -gt 0 ] || [ "${thumbs_up_count}" -gt 0 ] || [ "${codex_comment_count}" -gt 0 ]; then
      review_started="true"
      emit "review_watch_status" \
        --arg status "review_activity_started" \
        --arg checked_at "${now}" \
        --arg poll_count "${poll_count}" \
        --arg review_count "${review_count}" \
        --arg thread_count "${thread_count}" \
        --arg codex_comment_count "${codex_comment_count}" \
        --arg thumbs_up_count "${thumbs_up_count}"
    fi
  fi

  if [ "${thread_count}" -gt 0 ]; then
    emit "review_watch_status" \
      --arg status "review_threads_ready" \
      --arg completed_at "${now}" \
      --arg poll_count "${poll_count}" \
      --arg review_count "${review_count}" \
      --arg thread_count "${thread_count}"
    exit 0
  fi

  if [ "${review_count}" -gt 0 ]; then
    emit "review_watch_status" \
      --arg status "review_output_ready" \
      --arg completed_at "${now}" \
      --arg poll_count "${poll_count}" \
      --arg review_count "${review_count}" \
      --arg thread_count "${thread_count}"
    exit 0
  fi

  if [ "${thumbs_up_count}" -gt 0 ]; then
    emit "review_watch_status" \
      --arg status "no_findings_reaction" \
      --arg completed_at "${now}" \
      --arg poll_count "${poll_count}" \
      --arg thumbs_up_count "${thumbs_up_count}"
    exit 20
  fi

  if [ "${elapsed_seconds}" -ge "${timeout_seconds}" ]; then
    emit "review_watch_status" \
      --arg status "timeout" \
      --arg completed_at "${now}" \
      --arg poll_count "${poll_count}" \
      --arg elapsed_seconds "${elapsed_seconds}" \
      --arg review_started "${review_started}"
    exit 30
  fi

  if [ -n "${max_polls}" ] && [ "${poll_count}" -ge "${max_polls}" ]; then
    emit "review_watch_status" \
      --arg status "max_polls_exceeded" \
      --arg completed_at "${now}" \
      --arg poll_count "${poll_count}" \
      --arg elapsed_seconds "${elapsed_seconds}" \
      --arg review_started "${review_started}"
    exit 30
  fi

  if [ "${review_started}" = "true" ]; then
    emit "review_watch_status" \
      --arg status "waiting_for_review_output" \
      --arg checked_at "${now}" \
      --arg poll_count "${poll_count}"
    sleep "${started_interval}"
  else
    emit "review_watch_status" \
      --arg status "waiting_for_review_start" \
      --arg checked_at "${now}" \
      --arg poll_count "${poll_count}"
    sleep "${initial_interval}"
  fi
done
