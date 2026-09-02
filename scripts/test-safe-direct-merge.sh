#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-safe-direct-merge-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

scenario="${SAFE_DIRECT_MERGE_TEST_SCENARIO:-empty}"
head_oid="${SAFE_DIRECT_MERGE_HEAD_OID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
command_name="${1:-} ${2:-}"
merge_oid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

increment_file_counter() {
  local counter_file="$1" count=0
  if [ -n "$counter_file" ] && [ -f "$counter_file" ]; then
    count="$(<"$counter_file")"
  fi
  count=$((count + 1))
  if [ -n "$counter_file" ]; then
    printf '%s\n' "$count" > "$counter_file"
  fi
  printf '%s\n' "$count"
}

emit_native_stack() {
  local selected_position=2 stack_size=3
  local selected_base="feature/base" selected_head="feature/mock"
  local bottom_number=214 bottom_branch="feature/base" bottom_head="cccccccccccccccccccccccccccccccccccccccc"
  local bottom_state="MERGED" bottom_merged=true
  local top_number=218 top_branch="feature/above" top_head="dddddddddddddddddddddddddddddddddddddddd"
  local top_state="OPEN" top_merged=false

  if [ "$scenario" = "non-bottom-stack" ]; then
    bottom_number=218
    bottom_branch="feature/base"
    bottom_head="cccccccccccccccccccccccccccccccccccccccc"
    bottom_state="OPEN"
    bottom_merged=false
    top_number=220
    top_branch="feature/above"
    top_head="dddddddddddddddddddddddddddddddddddddddd"
  fi

  printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"stack\":{\"id\":\"stack-1\",\"number\":1,\"size\":$stack_size,\"baseRefName\":\"main\",\"entries\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"stack-entry-1\",\"position\":1,\"pullRequest\":{\"number\":$bottom_number,\"state\":\"$bottom_state\",\"merged\":$bottom_merged,\"headRefName\":\"$bottom_branch\",\"headRefOid\":\"$bottom_head\",\"baseRefName\":\"main\"}},{\"id\":\"stack-entry-2\",\"position\":2,\"pullRequest\":{\"number\":42,\"state\":\"OPEN\",\"merged\":false,\"headRefName\":\"$selected_head\",\"headRefOid\":\"$head_oid\",\"baseRefName\":\"$selected_base\"}},{\"id\":\"stack-entry-3\",\"position\":3,\"pullRequest\":{\"number\":$top_number,\"state\":\"$top_state\",\"merged\":$top_merged,\"headRefName\":\"$top_branch\",\"headRefOid\":\"$top_head\",\"baseRefName\":\"feature/mock\"}}]}},\"stackEntry\":{\"id\":\"stack-entry-$selected_position\",\"position\":$selected_position,\"pullRequest\":{\"number\":42,\"state\":\"OPEN\",\"merged\":false,\"headRefName\":\"$selected_head\",\"headRefOid\":\"$head_oid\",\"baseRefName\":\"$selected_base\"}}}}}}"
}

case "$command_name" in
  "repo view")
    if [[ "$*" = *"-q .nameWithOwner"* ]]; then
      printf '%s\n' 'nerdchanii/rpm'
    else
      printf '%s\n' '{"nameWithOwner":"nerdchanii/rpm","defaultBranchRef":{"name":"main"}}'
    fi
    ;;
  "api repos/nerdchanii/rpm/branches/main/protection")
    if [ "$scenario" = "final-protection-changed" ] && \
       [ "$(increment_file_counter "${SAFE_DIRECT_MERGE_PROTECTION_COUNT_FILE:-}")" -gt 1 ]; then
      printf '%s\n' '{"enforce_admins":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_status_checks":{"strict":false,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    elif [ "$scenario" = "server-protection-invalid" ]; then
      printf '%s\n' '{"enforce_admins":{"enabled":false},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    elif [ "$scenario" = "server-protection-wrong-app-id" ]; then
      printf '%s\n' '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":99999},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    else
      printf '%s\n' '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    fi
    ;;
  "pr view")
    query=""
    for ((index = 1; index <= $#; index += 1)); do
      if [ "${!index}" = "-q" ] && [ "$((index + 1))" -le "$#" ]; then
        next=$((index + 1))
        query="${!next}"
      fi
    done
    json_fields=""
    for ((index = 1; index <= $#; index += 1)); do
      if [ "${!index}" = "--json" ] && [ "$((index + 1))" -le "$#" ]; then
        next=$((index + 1))
        json_fields="${!next}"
      fi
    done
    if [ "$scenario" = "native-stack-async-success" ]; then
      view_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_PR_VIEW_COUNT_FILE:-}")"
      if [[ "$json_fields" = *"mergeCommit"* ]] && [ "$view_count" -gt 1 ]; then
        printf '%s\n' "{\"number\":42,\"state\":\"MERGED\",\"mergedAt\":\"2026-09-01T00:00:00Z\",\"headRefOid\":\"$head_oid\",\"mergeCommit\":{\"oid\":\"$merge_oid\"}}"
        exit 0
      fi
    elif [[ "$json_fields" = *"mergeCommit"* ]]; then
      if [ "$scenario" = "post-open" ]; then
        printf '%s\n' "{\"number\":42,\"state\":\"OPEN\",\"mergedAt\":null,\"headRefOid\":\"$head_oid\",\"mergeCommit\":null}"
      elif [ "$scenario" = "post-missing-commit" ]; then
        printf '%s\n' "{\"number\":42,\"state\":\"MERGED\",\"mergedAt\":\"2026-09-01T00:00:00Z\",\"headRefOid\":\"$head_oid\",\"mergeCommit\":null}"
      else
        printf '%s\n' "{\"number\":42,\"state\":\"MERGED\",\"mergedAt\":\"2026-09-01T00:00:00Z\",\"headRefOid\":\"$head_oid\",\"mergeCommit\":{\"oid\":\"$merge_oid\"}}"
      fi
      exit 0
    fi
    case "$query" in
      "")
        review_decision="null"
        head_repository="nerdchanii/rpm"
        cross_repository=false
        metadata_head_oid="$head_oid"
        if [ "$scenario" = "final-head-changed" ]; then
          view_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_PR_VIEW_COUNT_FILE:-}")"
          if [ "$view_count" -gt 1 ]; then
            metadata_head_oid="ffffffffffffffffffffffffffffffffffffffff"
          fi
        fi
        if [ "$scenario" = "changes-requested" ]; then
          review_decision="\"CHANGES_REQUESTED\""
        elif [ "$scenario" = "review-decision-empty" ]; then
          review_decision="\"\""
        fi
        if [ "$scenario" = "cross-repo" ] || [ "$scenario" = "cross-repo-metadata-mismatch" ]; then
          head_repository="fork-owner/rpm"
          if [ "$scenario" = "cross-repo" ]; then
            cross_repository=true
          fi
        fi
        head_ref="feature/mock"
        base_ref="main"
        if [ "$scenario" = "base-non-protected" ]; then
          head_ref="main"
          base_ref="release"
        elif [ "$scenario" = "default-head" ]; then
          head_ref="main"
        fi
        printf '%s\n' "{\"state\":\"OPEN\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"headRefName\":\"$head_ref\",\"baseRefName\":\"$base_ref\",\"headRefOid\":\"$metadata_head_oid\",\"reviewDecision\":$review_decision,\"headRepository\":{\"nameWithOwner\":\"$head_repository\"},\"isCrossRepository\":$cross_repository}"
        ;;
      .state) printf 'OPEN\n' ;;
      .isDraft) printf 'false\n' ;;
      .mergeable) printf 'MERGEABLE\n' ;;
      .mergeStateStatus) printf 'CLEAN\n' ;;
      .headRefName) printf 'feature/mock\n' ;;
      *)
        printf 'unsupported pr view query: %s\n' "$query" >&2
        exit 97
        ;;
    esac
    ;;
  "pr checks")
    if [ "$scenario" = "duplicate-required-check" ]; then
      printf '%s\n' '[{"name":"metadata","bucket":"pass"},{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
    elif [ "$scenario" = "duplicate-required-check-fail" ]; then
      printf '%s\n' '[{"name":"metadata","bucket":"pass"},{"name":"metadata","bucket":"failure"},{"name":"verify","bucket":"pass"}]'
    elif [ "$scenario" = "final-check-changed" ]; then
      check_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_CHECK_COUNT_FILE:-}")"
      if [ "$check_count" -gt 1 ]; then
        printf '%s\n' '[{"name":"metadata","bucket":"pass"},{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
      else
        printf '%s\n' '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
      fi
    else
      printf '%s\n' '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
    fi
    ;;
  "pr list")
    if [ "$scenario" = "base-query" ] && [[ "$*" != *"--base feature/mock"* ]]; then
      printf '%s\n' 'missing --base filter' >&2
      exit 90
    fi
    if [ "$scenario" = "dependent-truncated" ]; then
      printf '['
      for ((index = 1; index <= 1000; index += 1)); do
        [ "$index" -eq 1 ] || printf ','
        printf '{"number":%s,"baseRefName":"feature/mock"}' "$index"
      done
      printf ']\n'
    elif [ "$scenario" = "final-dependent-changed" ]; then
      dependent_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_DEPENDENT_COUNT_FILE:-}")"
      if [ "$dependent_count" -gt 1 ]; then
        printf '%s\n' '[{"number":218,"baseRefName":"feature/mock"}]'
      else
        printf '%s\n' '[]'
      fi
    elif [ "$scenario" = "dependent" ] || [ "$scenario" = "native-stack-async-success" ]; then
      printf '%s\n' '[{"number":218,"baseRefName":"feature/mock"}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  "pr merge")
    if [ -n "${SAFE_DIRECT_MERGE_GH_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$SAFE_DIRECT_MERGE_GH_LOG"
    fi
    case "$scenario" in
      head-changed)
        printf '%s\n' 'head branch changed after gate checks' >&2
        exit 1
        ;;
      native-stack-async-success|native-stack-async-failure|native-stack-async-timeout|non-bottom-stack)
        printf '%s\n' 'part of a stack and must be merged using the asynchronous merge REST API' >&2
        exit 1
        ;;
      non-stack-failure)
        printf '%s\n' 'merge failed for an unrelated reason' >&2
        exit 1
        ;;
      late-p1-server-block)
        printf '%s\n' 'Required conversation resolution has not been satisfied' >&2
        exit 1
        ;;
      *)
        case "$*" in
          *"--match-head-commit $head_oid"*) printf '%s\n' 'merged' ;;
          *) printf '%s\n' 'missing --match-head-commit' >&2; exit 96 ;;
        esac
        ;;
    esac
    ;;
  "api --method")
    request_body="$(cat)"
    if [ -n "${SAFE_DIRECT_MERGE_GH_LOG:-}" ]; then
      printf '%s\n' "api:$*" >> "$SAFE_DIRECT_MERGE_GH_LOG"
      printf '%s\n' "body:$request_body" >> "$SAFE_DIRECT_MERGE_GH_LOG"
    fi
    case "$scenario" in
      native-stack-async-success|native-stack-async-failure|native-stack-async-timeout)
        printf '%s\n' "{\"status\":\"pending\",\"details\":{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"merge_method\":\"squash\",\"merge_action\":\"default\",\"expected_head_sha\":\"$head_oid\"}}"
        ;;
      *)
        printf '%s\n' 'unexpected async submission' >&2
        exit 95
        ;;
    esac
    ;;
  "api repos/"*)
    if [[ "$*" = *"/git/ref/heads/"* ]]; then
      case "$scenario" in
        remote-branch-read-failure)
          printf '%s\n' 'branch lookup failed' >&2
          exit 92
          ;;
        remote-branch-changed)
          printf '%s\n' '{"ref":"refs/heads/feature/mock","object":{"type":"commit","sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}'
          ;;
        *)
          printf '%s\n' "{\"ref\":\"refs/heads/feature/mock\",\"object\":{\"type\":\"commit\",\"sha\":\"$head_oid\"}}"
          ;;
      esac
      exit 0
    fi
    if [[ "$*" != *"merge-async/"* ]]; then
      printf '%s\n' 'unexpected async API path' >&2
      exit 94
    fi
    poll_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_ASYNC_POLL_COUNT_FILE:-}")"
    case "$scenario" in
      native-stack-async-success)
        if [ "$poll_count" -eq 1 ]; then
          printf '%s\n' "{\"status\":\"pending\",\"details\":{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"merge_method\":\"squash\",\"merge_action\":\"default\",\"expected_head_sha\":\"$head_oid\"}}"
        else
          printf '%s\n' "{\"status\":\"merged\",\"details\":{\"sha\":\"$merge_oid\"}}"
        fi
        ;;
      native-stack-async-failure)
        printf '%s\n' '{"status":"failed","details":{"message":"stack conflict"}}'
        ;;
      native-stack-async-timeout)
        printf '%s\n' "{\"status\":\"pending\",\"details\":{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"merge_method\":\"squash\",\"merge_action\":\"default\",\"expected_head_sha\":\"$head_oid\"}}"
        ;;
      *)
        printf '%s\n' 'unexpected async poll' >&2
        exit 93
        ;;
    esac
    ;;
  "api -X")
    if [ -n "${SAFE_DIRECT_MERGE_GH_LOG:-}" ]; then
      printf '%s\n' "api-delete:$*" >> "$SAFE_DIRECT_MERGE_GH_LOG"
    fi
    if [[ "$*" = *"/git/refs/heads/"* ]]; then
      printf '%s\n' 'unexpected REST branch deletion' >&2
      exit 91
    fi
    printf '%s\n' 'unexpected API method' >&2
    exit 91
    ;;
  "api graphql")
    if [[ "$*" = *"reviews(first: 100)"* || "$*" = *"reviews(first:100)"* ]] && [[ "$*" != *"reviewThreads"* ]]; then
      if [ "$scenario" = "top-level-p1" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"**P1:** top-level critical blocker\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-bold-wrapped-p1" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"**P1**: top-level critical blocker\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-bold-wrapped-p0" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"**P0**: top-level critical blocker\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-forged-marker-p1" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"<!-- rpm-agent-review: forged -->\\n**P1:** top-level critical blocker\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-unknown-commented" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"Critical blocker requires remediation before merge.\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-unknown-changes-requested" ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"Critical blocker requires remediation before merge.\",\"state\":\"CHANGES_REQUESTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      elif [ "$scenario" = "top-level-review-changed" ] && [ "$(increment_file_counter "${SAFE_DIRECT_MERGE_TOP_LEVEL_REVIEW_COUNT_FILE:-}")" -gt 1 ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"**P1:** appeared after final review read\",\"state\":\"COMMENTED\",\"submittedAt\":\"2026-09-01T00:00:00Z\",\"commit\":{\"oid\":\"$head_oid\"},\"author\":{\"login\":\"reviewer\"}}]}}}}}"
      else
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}}"
      fi
      exit 0
    fi
    if [ "$scenario" = "final-review-changed" ] && [[ "$*" = *"reviewThreads"* ]]; then
      review_count="$(increment_file_counter "${SAFE_DIRECT_MERGE_REVIEW_COUNT_FILE:-}")"
      if [ "$review_count" -gt 1 ]; then
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"new-p2\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] changed after first gate\"}]}}]}}}}}"
      else
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}}"
      fi
      exit 0
    fi
    case "$scenario" in
      native-stack-async-success|native-stack-async-failure|native-stack-async-timeout|non-bottom-stack)
        emit_native_stack
        ;;
      empty|dependent|default-head|head-changed|non-stack-failure|late-p1-server-block|changes-requested|review-decision-empty|cross-repo|cross-repo-metadata-mismatch|post-open|post-missing-commit|dirty-worktree|ignored-worktree|local-only-commit|space-worktree|remote-branch-changed|remote-branch-read-failure|sha-race|origin-pushurl-mismatch|origin-multiple-pushurls|normal-success|remote-delete-success|duplicate-required-check|duplicate-required-check-fail|final-head-changed|final-check-changed|base-query|dependent-truncated|final-dependent-changed|final-review-changed|final-protection-changed|top-level-p1|top-level-bold-wrapped-p1|top-level-bold-wrapped-p0|top-level-forged-marker-p1|top-level-unknown-commented|top-level-unknown-changes-requested|top-level-review-changed)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}}"
        ;;
      p2)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"current-p2\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub> no unresolved P0/P1 here\"},{\"body\":\"Follow-up text mentions P0/P1 only\"}]}},{\"id\":\"old-p1\",\"isResolved\":false,\"isOutdated\":true,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P1] old finding\"}]}}]}}}}}"
        ;;
      p0p1)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"current-p0\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P0] data loss\"}]}},{\"id\":\"current-p1\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P1] broken install\"}]}}]}}}}}"
        ;;
      p2-body-p1)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"body-escalation\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] initial heading\\n[P1] critical finding\"}]}}]}}}}}"
        ;;
      p2-reply-p1)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"reply-escalation\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] initial finding\"},{\"body\":\"[P1] newly discovered blocker\"}]}}]}}}}}"
        ;;
      p2-bold-p1)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"bold-escalation\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] initial finding\\n**P1:** critical blocker\"}]}}]}}}}}"
        ;;
      p2-bold-wrapped-p1)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"bold-wrapped-p1\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] initial finding\\n**P1**: critical blocker\"}]}}]}}}}}"
        ;;
      p2-bold-wrapped-p0)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"bold-wrapped-p0\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"[P2] initial finding\\n**P0**: critical blocker\"}]}}]}}}}}"
        ;;
      unknown)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"current-unknown\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"Please reconsider this behavior; no unresolved P0/P1 marker is present\"}]}}]}}}}}"
        ;;
      unknown-reply-p2)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"priority-poison\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"body\":\"Please reconsider this behavior\"},{\"body\":\"[P2] looks minor\"}]}}]}}}}}"
        ;;
      graphql-failure)
        printf '%s\n' 'authentication failed' >&2
        exit 42
        ;;
      graphql-errors)
        printf '%s\n' '{"errors":[{"message":"rate limit exceeded"}],"data":null}'
        ;;
      page-overrun)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":null},\"nodes\":[]}}}}}"
        ;;
      comments-page-overrun)
        printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"$head_oid\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"id\":\"too-many-comments\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"comment-cursor\"},\"nodes\":[{\"body\":\"[P2] more than one page\"}]}}]}}}}}"
        ;;
      *)
        printf 'unsupported scenario: %s\n' "$scenario" >&2
        exit 98
        ;;
    esac
    ;;
  *)
    printf 'unsupported gh invocation: %s\n' "$*" >&2
    exit 99
    ;;
esac
MOCK
chmod +x "$mock_bin/gh"

real_git="$(command -v git)"
cat > "$mock_bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then
  worktree_path="${2:-}"
  operation="${3:-} ${4:-}"
  case "$operation" in
    "branch --show-current")
      if [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "dirty-worktree" ] \
        || [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "ignored-worktree" ] \
        || [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "local-only-commit" ] \
        || [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "space-worktree" ]; then
        printf '%s\n' 'feature/mock'
        exit 0
      fi
      ;;
    "status --porcelain=v1")
      if [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "dirty-worktree" ]; then
        printf '%s\n' ' M changed.txt'
      elif [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "ignored-worktree" ]; then
        printf '%s\n' '!! ignored.txt'
      elif [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "local-only-commit" ]; then
        printf '%s\n' 'local-only commit fixture'
      fi
      exit 0
      ;;
  esac
fi

case "$*" in
  "worktree list --porcelain")
    case "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" in
      dirty-worktree|ignored-worktree|local-only-commit|space-worktree)
        printf '%s\n' 'worktree /tmp/rpm dirty worktree'
        printf '%s\n' 'HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        printf '%s\n' 'branch refs/heads/feature/mock'
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  "worktree "*)
    if [ -n "${SAFE_DIRECT_MERGE_GIT_LOG:-}" ]; then
      printf '%s\n' "worktree:$*" >> "$SAFE_DIRECT_MERGE_GIT_LOG"
    fi
    exit 0
    ;;
  "remote get-url --all origin")
    if [ -n "${SAFE_DIRECT_MERGE_GIT_LOG:-}" ]; then
      printf '%s\n' "remote-fetch:$*" >> "$SAFE_DIRECT_MERGE_GIT_LOG"
    fi
    printf '%s\n' 'git@github.com:nerdchanii/rpm.git'
    exit 0
    ;;
  "remote get-url --push --all origin")
    if [ -n "${SAFE_DIRECT_MERGE_GIT_LOG:-}" ]; then
      printf '%s\n' "remote-push:$*" >> "$SAFE_DIRECT_MERGE_GIT_LOG"
    fi
    if [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "origin-pushurl-mismatch" ]; then
      printf '%s\n' 'git@github.com:other-owner/other-repo.git'
    elif [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "origin-multiple-pushurls" ]; then
      printf '%s\n' 'git@github.com:nerdchanii/rpm.git'
      printf '%s\n' 'git@github.com:other-owner/other-repo.git'
    else
      printf '%s\n' 'git@github.com:nerdchanii/rpm.git'
    fi
    exit 0
    ;;
  "push --force-with-lease="*)
    if [ -n "${SAFE_DIRECT_MERGE_GIT_LOG:-}" ]; then
      printf '%s\n' "push:$*" >> "$SAFE_DIRECT_MERGE_GIT_LOG"
    fi
    if [ "${SAFE_DIRECT_MERGE_TEST_SCENARIO:-}" = "remote-delete-success" ]; then
      exit 0
    fi
    exit 1
    ;;
  "branch -D "*)
    if [ -n "${SAFE_DIRECT_MERGE_GIT_LOG:-}" ]; then
      printf '%s\n' "branch-delete:$*" >> "$SAFE_DIRECT_MERGE_GIT_LOG"
    fi
    exit 0
    ;;
  *)
    exec "${SAFE_DIRECT_MERGE_REAL_GIT:?}" "$@"
    ;;
esac
MOCK
chmod +x "$mock_bin/git"

delete_policy_file="$tmp_dir/delete-branch-policy.json"
jq '.merge_gate.delete_branch = true' \
  "$script_dir/../.agents/workflows/backlog-policy.json" > "$delete_policy_file"

run_case() {
  local name="$1" scenario="$2" expected_status="$3" expected_text="$4"
  local output status

  set +e
  output="$(PATH="$mock_bin:$PATH" SAFE_DIRECT_MERGE_TEST_SCENARIO="$scenario" \
    bash "$script_dir/safe-direct-merge.sh" --dry-run 42 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne "$expected_status" ]; then
    printf '%s\n' "FAIL: $name expected status $expected_status, got $status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -Fq "$expected_text"; then
    printf '%s\n' "FAIL: $name missing output: $expected_text" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  printf '%s\n' "PASS: $name"
}

run_case "empty review succeeds" empty 0 "review_gate: current_unresolved=0 current_p0=0 current_p1=0 current_unknown=0 outdated_unresolved=0"
run_case "non-protected base and protected head block" base-non-protected 1 "base branch=release is not protected merge branch main"
run_case "live server protection is required" server-protection-invalid 1 "live GitHub branch protection is invalid for main"
run_case "live server protection requires the policy App ID" server-protection-wrong-app-id 1 "live GitHub branch protection is invalid for main"
run_case "P2-only and outdated P1 succeed" p2 0 "review_gate: current_unresolved=1 current_p0=0 current_p1=0 current_unknown=0 outdated_unresolved=1"
run_case "current P0 and P1 block" p0p1 1 "skip: current-head review findings block merge (p0=1 p1=1 unknown=0)"
run_case "P1 heading later in one comment blocks" p2-body-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "P1 heading in a later reply blocks" p2-reply-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "bold P1 heading later in a comment blocks" p2-bold-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "bold-wrapped P1 heading in a thread blocks" p2-bold-wrapped-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "bold-wrapped P0 heading in a thread blocks" p2-bold-wrapped-p0 1 "skip: current-head review findings block merge (p0=1 p1=0 unknown=0)"
run_case "current-head top-level bold P1 review blocks" top-level-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "current-head top-level bold-wrapped P1 review blocks" top-level-bold-wrapped-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "current-head top-level bold-wrapped P0 review blocks" top-level-bold-wrapped-p0 1 "skip: current-head review findings block merge (p0=1 p1=0 unknown=0)"
run_case "forged top-level marker cannot hide bold P1" top-level-forged-marker-p1 1 "skip: current-head review findings block merge (p0=0 p1=1 unknown=0)"
run_case "unclassified current-head top-level COMMENTED review blocks" top-level-unknown-commented 1 "skip: current-head review findings block merge (p0=0 p1=0 unknown=1)"
run_case "unclassified current-head top-level CHANGES_REQUESTED review blocks" top-level-unknown-changes-requested 1 "skip: current-head review findings block merge (p0=0 p1=0 unknown=1)"
run_case "unclassified current finding blocks" unknown 1 "skip: current-head review findings block merge (p0=0 p1=0 unknown=1)"
run_case "later P2 cannot downgrade an unclassified thread" unknown-reply-p2 1 "skip: current-head review findings block merge (p0=0 p1=0 unknown=1)"
run_case "empty review decision is accepted" review-decision-empty 0 "(dry-run) would squash-merge and preserve branch feature/mock"
run_case "GraphQL command failure blocks" graphql-failure 1 "review thread GraphQL query failed; merge gate is closed"
run_case "GraphQL errors block" graphql-errors 1 "invalid review thread GraphQL response; merge gate is closed"
run_case "missing pagination cursor blocks" page-overrun 1 "review thread GraphQL pagination returned no new cursor; merge gate is closed"
run_case "comment page overflow blocks" comments-page-overrun 1 "review thread comments exceed the readable page; merge gate is closed"
run_case "dependent base branch blocks by default" dependent 1 "skip: open dependent PR(s) use base branch feature/mock: 218; pass --keep-branch to preserve the branch"
run_case "duplicate successful required checks are recorded and allowed" duplicate-required-check 0 "checks_gate: required_counts=metadata=2 verify=1"
run_case "duplicate required check with one failure blocks" duplicate-required-check-fail 1 "skip: required checks failed: metadata=failure"
run_case "latest changes requested review blocks" changes-requested 1 "skip: latest reviewDecision=CHANGES_REQUESTED; merge gate is closed"
run_case "dependent query is base-filtered" base-query 0 "(dry-run) would squash-merge and preserve branch feature/mock"
run_case "dependent query truncation blocks" dependent-truncated 1 "skip: dependent PR response reached the readable limit; merge gate is closed"

legacy_protection_policy_file="$tmp_dir/legacy-protection-policy.json"
jq '.merge_gate.server_protection.required_status_checks = ["metadata", "verify"]' \
  "$script_dir/../.agents/workflows/backlog-policy.json" > "$legacy_protection_policy_file"
set +e
legacy_protection_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_POLICY_FILE="$legacy_protection_policy_file" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=empty \
  bash "$script_dir/safe-direct-merge.sh" --dry-run 42 2>&1)"
legacy_protection_status=$?
set -e
if [ "$legacy_protection_status" -ne 2 ] \
  || ! printf '%s\n' "$legacy_protection_output" | grep -Fq 'invalid-server-protection-policy'; then
  printf '%s\n' 'FAIL: legacy string status-check policy must be rejected' >&2
  printf '%s\n' "$legacy_protection_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: legacy string status-check policy is rejected'

wrong_policy_app_id_file="$tmp_dir/wrong-policy-app-id.json"
jq '.merge_gate.server_protection.required_status_checks[0].app_id = 99999' \
  "$script_dir/../.agents/workflows/backlog-policy.json" > "$wrong_policy_app_id_file"
set +e
wrong_policy_app_id_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_POLICY_FILE="$wrong_policy_app_id_file" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=empty \
  bash "$script_dir/safe-direct-merge.sh" --dry-run 42 2>&1)"
wrong_policy_app_id_status=$?
set -e
if [ "$wrong_policy_app_id_status" -ne 2 ] \
  || ! printf '%s\n' "$wrong_policy_app_id_output" | grep -Fq 'invalid-server-protection-policy'; then
  printf '%s\n' 'FAIL: a policy status check with the wrong App ID must be rejected' >&2
  printf '%s\n' "$wrong_policy_app_id_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: policy status checks require App ID 15368'

set +e
legacy_findings_output="$(PATH="$mock_bin:$PATH" SAFE_DIRECT_MERGE_TEST_SCENARIO=p0p1 \
  bash "$script_dir/safe-direct-merge.sh" --dry-run --allow-findings 42 2>&1)"
legacy_findings_status=$?
set -e
if [ "$legacy_findings_status" -ne 2 ] \
  || ! printf '%s\n' "$legacy_findings_output" | grep -Fq 'unknown option: --allow-findings'; then
  printf '%s\n' 'FAIL: the legacy --allow-findings option must be rejected' >&2
  printf '%s\n' "$legacy_findings_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: legacy --allow-findings option is rejected'

set +e
cross_repo_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=cross-repo \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/cross-repo-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/cross-repo-gh.log" \
  SAFE_DIRECT_MERGE_LOG_BRANCH_DELETE=1 \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
cross_repo_status=$?
set -e
if [ "$cross_repo_status" -eq 0 ] \
  || ! printf '%s\n' "$cross_repo_output" | grep -Fq 'is not the exact trusted repository nerdchanii/rpm' \
  || [ -e "$tmp_dir/cross-repo-git.log" ] \
  || grep -Fq -- 'git/ref/heads' "$tmp_dir/cross-repo-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: cross-repository head branch must never be deleted from the base repository' >&2
  printf '%s\n' "$cross_repo_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: cross-repository head is rejected before merge'

set +e
cross_repo_mismatch_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=cross-repo-metadata-mismatch \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/cross-repo-mismatch-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/cross-repo-mismatch-gh.log" \
  SAFE_DIRECT_MERGE_LOG_BRANCH_DELETE=1 \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
cross_repo_mismatch_status=$?
set -e
if [ "$cross_repo_mismatch_status" -eq 0 ] \
  || ! printf '%s\n' "$cross_repo_mismatch_output" | grep -Fq 'is not the exact trusted repository nerdchanii/rpm' \
  || [ -e "$tmp_dir/cross-repo-mismatch-git.log" ] \
  || grep -Fq -- 'git/ref/heads' "$tmp_dir/cross-repo-mismatch-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a mismatched head repository must also preserve the base repository branch' >&2
  printf '%s\n' "$cross_repo_mismatch_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: head repository mismatch is rejected before merge'

set +e
repository_identity_output="$(PATH="$mock_bin:$PATH" \
  GITHUB_REPOSITORY=other-owner/rpm \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=empty \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/repository-identity-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/repository-identity-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
repository_identity_status=$?
set -e
if [ "$repository_identity_status" -eq 0 ] \
  || ! printf '%s\n' "$repository_identity_output" | grep -Fq 'does not match GITHUB_REPOSITORY=other-owner/rpm' \
  || [ -e "$tmp_dir/repository-identity-git.log" ] \
  || grep -Fq -- 'pr merge' "$tmp_dir/repository-identity-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: safe-direct must bind the trusted head repository to GITHUB_REPOSITORY' >&2
  printf '%s\n' "$repository_identity_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: GITHUB_REPOSITORY mismatch is rejected before merge'

set +e
default_head_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=default-head \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/default-head-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/default-head-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
default_head_status=$?
set -e
if [ "$default_head_status" -ne 0 ] \
  || ! printf '%s\n' "$default_head_output" | grep -Fq 'protected/default branch main is never eligible for cleanup' \
  || grep -Fq -- 'push:--force-with-lease' "$tmp_dir/default-head-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: safe-direct must never clean up the protected/default head branch' >&2
  printf '%s\n' "$default_head_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: protected/default head branch cleanup is disabled'

set +e
post_open_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=post-open \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/post-open-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/post-open-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
post_open_status=$?
set -e
if [ "$post_open_status" -eq 0 ] \
  || ! printf '%s\n' "$post_open_output" | grep -Fq 'synchronous merge did not produce a live MERGED PR state' \
  || [ -e "$tmp_dir/post-open-git.log" ]; then
  printf '%s\n' 'FAIL: a queue-like OPEN post-state must block cleanup and success reporting' >&2
  printf '%s\n' "$post_open_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: synchronous post-state is required before cleanup'

set +e
post_missing_commit_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=post-missing-commit \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/post-missing-commit-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/post-missing-commit-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
post_missing_commit_status=$?
set -e
if [ "$post_missing_commit_status" -eq 0 ] \
  || ! printf '%s\n' "$post_missing_commit_output" | grep -Fq 'synchronous merge did not produce a live MERGED PR state' \
  || [ -e "$tmp_dir/post-missing-commit-git.log" ]; then
  printf '%s\n' 'FAIL: a merged PR without mergeCommit must block cleanup and success reporting' >&2
  printf '%s\n' "$post_missing_commit_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: synchronous mergeCommit is required before cleanup'

set +e
dirty_worktree_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=dirty-worktree \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/dirty-worktree-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/dirty-worktree-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
dirty_worktree_status=$?
set -e
if [ "$dirty_worktree_status" -ne 0 ] \
  || ! printf '%s\n' "$dirty_worktree_output" | grep -Fq 'merged #42; branch-preserved' \
  || ! printf '%s\n' "$dirty_worktree_output" | grep -Fq 'merge_gate.delete_branch=false' \
  || grep -Fq 'worktree:' "$tmp_dir/dirty-worktree-git.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/dirty-worktree-git.log" 2>/dev/null \
  || grep -Fq 'git/ref/heads' "$tmp_dir/dirty-worktree-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: dirty worktree must remain untouched after a verified merge' >&2
  printf '%s\n' "$dirty_worktree_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: dirty worktree is preserved'

set +e
ignored_worktree_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=ignored-worktree \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/ignored-worktree-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/ignored-worktree-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
ignored_worktree_status=$?
set -e
if [ "$ignored_worktree_status" -ne 0 ] \
  || ! printf '%s\n' "$ignored_worktree_output" | grep -Fq 'merged #42; branch-preserved' \
  || grep -Fq 'worktree:' "$tmp_dir/ignored-worktree-git.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/ignored-worktree-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: ignored worktree must remain untouched after a verified merge' >&2
  printf '%s\n' "$ignored_worktree_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: ignored worktree is preserved'

set +e
local_only_commit_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=local-only-commit \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/local-only-commit-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/local-only-commit-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
local_only_commit_status=$?
set -e
if [ "$local_only_commit_status" -ne 0 ] \
  || ! printf '%s\n' "$local_only_commit_output" | grep -Fq 'merged #42; branch-preserved' \
  || grep -Fq 'worktree:' "$tmp_dir/local-only-commit-git.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/local-only-commit-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: local-only worktree commits must remain untouched after a verified merge' >&2
  printf '%s\n' "$local_only_commit_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: local-only worktree commit is preserved'

set +e
space_worktree_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=space-worktree \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/space-worktree-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/space-worktree-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
space_worktree_status=$?
set -e
if [ "$space_worktree_status" -ne 0 ] \
  || ! printf '%s\n' "$space_worktree_output" | grep -Fq 'merged #42; branch-preserved' \
  || grep -Fq 'worktree:' "$tmp_dir/space-worktree-git.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/space-worktree-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a worktree path containing spaces must remain untouched' >&2
  printf '%s\n' "$space_worktree_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: worktree path containing spaces is preserved'

set +e
final_protection_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=final-protection-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_PROTECTION_COUNT_FILE="$tmp_dir/final-protection-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-protection-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_protection_status=$?
set -e
if [ "$final_protection_status" -eq 0 ] \
  || ! printf '%s\n' "$final_protection_output" | grep -Fq 'live GitHub branch protection changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-protection-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: changed server protection must block before the merge command' >&2
  printf '%s\n' "$final_protection_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final server-protection recheck blocks policy drift'

set +e
final_head_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=final-head-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_PR_VIEW_COUNT_FILE="$tmp_dir/final-head-view-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-head-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_head_status=$?
set -e
if [ "$final_head_status" -eq 0 ] \
  || ! printf '%s\n' "$final_head_output" | grep -Fq 'PR metadata changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-head-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a changed head in the final gate recheck must block merge' >&2
  printf '%s\n' "$final_head_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final head recheck blocks TOCTOU'

set +e
final_check_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=final-check-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_CHECK_COUNT_FILE="$tmp_dir/final-check-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-check-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_check_status=$?
set -e
if [ "$final_check_status" -eq 0 ] \
  || ! printf '%s\n' "$final_check_output" | grep -Fq 'required checks changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-check-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a changed required-check snapshot must block merge' >&2
  printf '%s\n' "$final_check_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final required-check recheck blocks TOCTOU'

set +e
final_review_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=final-review-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_REVIEW_COUNT_FILE="$tmp_dir/final-review-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-review-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_review_status=$?
set -e
if [ "$final_review_status" -eq 0 ] \
  || ! printf '%s\n' "$final_review_output" | grep -Fq 'review findings changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-review-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a changed review snapshot must block merge' >&2
  printf '%s\n' "$final_review_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final review recheck blocks TOCTOU'

set +e
final_top_level_review_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=top-level-review-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_TOP_LEVEL_REVIEW_COUNT_FILE="$tmp_dir/final-top-level-review-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-top-level-review-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_top_level_review_status=$?
set -e
if [ "$final_top_level_review_status" -eq 0 ] \
  || ! printf '%s\n' "$final_top_level_review_output" | grep -Fq 'review findings changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-top-level-review-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a changed top-level review snapshot must block merge' >&2
  printf '%s\n' "$final_top_level_review_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final top-level review recheck blocks TOCTOU'

set +e
late_p1_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=late-p1-server-block \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/late-p1-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" --keep-branch 42 2>&1)"
late_p1_status=$?
set -e
if [ "$late_p1_status" -eq 0 ] \
  || ! printf '%s\n' "$late_p1_output" | grep -Fq 'Required conversation resolution has not been satisfied' \
  || printf '%s\n' "$late_p1_output" | grep -Fq 'merged #42'; then
  printf '%s\n' 'FAIL: server conversation protection must stop a P1 added after the final local review read' >&2
  printf '%s\n' "$late_p1_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: server conversation protection closes the final review race'

set +e
final_dependent_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=final-dependent-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_DEPENDENT_COUNT_FILE="$tmp_dir/final-dependent-count" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/final-dependent-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
final_dependent_status=$?
set -e
if [ "$final_dependent_status" -eq 0 ] \
  || ! printf '%s\n' "$final_dependent_output" | grep -Fq 'dependent PR set changed before merge' \
  || grep -Fq 'pr merge' "$tmp_dir/final-dependent-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a changed dependent-PR snapshot must block merge' >&2
  printf '%s\n' "$final_dependent_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: final dependent PR recheck blocks TOCTOU'

set +e
remote_changed_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=remote-branch-changed \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/remote-changed-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/remote-changed-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
remote_changed_status=$?
set -e
if [ "$remote_changed_status" -ne 0 ] \
  || ! printf '%s\n' "$remote_changed_output" | grep -Fq 'remote SHA changed from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
  || [ -e "$tmp_dir/remote-changed-git.log" ]; then
  printf '%s\n' 'FAIL: a remote branch moved after merge must be preserved' >&2
  printf '%s\n' "$remote_changed_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: changed remote branch SHA is preserved'

set +e
remote_read_failure_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=remote-branch-read-failure \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/remote-read-failure-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/remote-read-failure-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
remote_read_failure_status=$?
set -e
if [ "$remote_read_failure_status" -ne 0 ] \
  || ! printf '%s\n' "$remote_read_failure_output" | grep -Fq 'unable to read remote branch feature/mock SHA; preserving the branch' \
  || [ -e "$tmp_dir/remote-read-failure-git.log" ]; then
  printf '%s\n' 'FAIL: an unreadable remote branch SHA must preserve the branch' >&2
  printf '%s\n' "$remote_read_failure_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: unreadable remote branch SHA is preserved'

set +e
normal_merge_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=normal-success \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/normal-merge-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/normal-merge-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
normal_merge_status=$?
set -e
if [ "$normal_merge_status" -ne 0 ] \
  || ! printf '%s\n' "$normal_merge_output" | grep -Fq 'CAS deletion failed; preserving the branch' \
  || ! printf '%s\n' "$normal_merge_output" | grep -Fq 'merged #42; branch-preserved' \
  || ! grep -Fq -- 'push:push --force-with-lease=refs/heads/feature/mock:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa git@github.com:nerdchanii/rpm.git :refs/heads/feature/mock' "$tmp_dir/normal-merge-git.log" 2>/dev/null \
  || grep -Fq 'api-delete:' "$tmp_dir/normal-merge-gh.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/normal-merge-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a failed remote CAS must preserve the branch without REST fallback' >&2
  printf '%s\n' "$normal_merge_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: failed remote CAS preserves the branch without REST fallback'

set +e
remote_delete_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=remote-delete-success \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/remote-delete-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/remote-delete-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
remote_delete_status=$?
set -e
if [ "$remote_delete_status" -ne 0 ] \
  || ! printf '%s\n' "$remote_delete_output" | grep -Fq 'deleted remote branch feature/mock with SHA-guarded CAS' \
  || ! printf '%s\n' "$remote_delete_output" | grep -Fq 'merged #42; branch-deleted' \
  || ! grep -Fq -- 'push:push --force-with-lease=refs/heads/feature/mock:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa git@github.com:nerdchanii/rpm.git :refs/heads/feature/mock' "$tmp_dir/remote-delete-git.log" 2>/dev/null \
  || grep -Fq 'api-delete:' "$tmp_dir/remote-delete-gh.log" 2>/dev/null \
  || grep -Fq 'branch-delete:' "$tmp_dir/remote-delete-git.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: remote deletion must use the exact SHA-guarded CAS push' >&2
  printf '%s\n' "$remote_delete_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: matching remote branch SHA permits only the verified CAS deletion'

set +e
sha_race_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=sha-race \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/sha-race-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/sha-race-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
sha_race_status=$?
set -e
if [ "$sha_race_status" -ne 0 ] \
  || ! printf '%s\n' "$sha_race_output" | grep -Fq 'CAS deletion failed; preserving the branch' \
  || ! printf '%s\n' "$sha_race_output" | grep -Fq 'merged #42; branch-preserved' \
  || ! grep -Fq -- 'push:push --force-with-lease=refs/heads/feature/mock:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa git@github.com:nerdchanii/rpm.git :refs/heads/feature/mock' "$tmp_dir/sha-race-git.log" 2>/dev/null \
  || grep -Fq 'api-delete:' "$tmp_dir/sha-race-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a SHA race at the CAS push must preserve the verified merge' >&2
  printf '%s\n' "$sha_race_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: remote SHA race preserves the branch after CAS failure'

set +e
pushurl_mismatch_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=origin-pushurl-mismatch \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/origin-pushurl-mismatch-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/origin-pushurl-mismatch-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
pushurl_mismatch_status=$?
set -e
if [ "$pushurl_mismatch_status" -ne 0 ] \
  || ! printf '%s\n' "$pushurl_mismatch_output" | grep -Fq 'URLs do not match GitHub repository nerdchanii/rpm; preserving the remote branch' \
  || ! printf '%s\n' "$pushurl_mismatch_output" | grep -Fq 'merged #42; branch-preserved' \
  || grep -Fq '^push:' "$tmp_dir/origin-pushurl-mismatch-git.log" 2>/dev/null \
  || grep -Fq 'api-delete:' "$tmp_dir/origin-pushurl-mismatch-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: an origin pushurl mismatch must block remote deletion' >&2
  printf '%s\n' "$pushurl_mismatch_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: origin pushurl mismatch preserves the branch'

set +e
multiple_pushurls_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=origin-multiple-pushurls \
  SAFE_DIRECT_MERGE_POLICY_FILE="$delete_policy_file" \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/origin-multiple-pushurls-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/origin-multiple-pushurls-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
multiple_pushurls_status=$?
set -e
if [ "$multiple_pushurls_status" -ne 0 ] \
  || ! printf '%s\n' "$multiple_pushurls_output" | grep -Fq 'must have exactly one push URL; preserving the remote branch' \
  || ! printf '%s\n' "$multiple_pushurls_output" | grep -Fq 'merged #42; branch-preserved' \
  || grep -Fq '^push:' "$tmp_dir/origin-multiple-pushurls-git.log" 2>/dev/null \
  || grep -Fq 'api-delete:' "$tmp_dir/origin-multiple-pushurls-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: multiple origin push URLs must block remote deletion before any push' >&2
  printf '%s\n' "$multiple_pushurls_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: multiple origin push URLs preserve the branch before any push'

set +e
non_stack_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=non-stack-failure \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/non-stack-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" --keep-branch 42 2>&1)"
non_stack_status=$?
set -e
if [ "$non_stack_status" -eq 0 ] \
  || ! printf '%s\n' "$non_stack_output" | grep -Fq 'FAIL: gh pr merge returned non-zero' \
  || grep -Fq 'merge-async' "$tmp_dir/non-stack-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: a non-stack merge failure must not fall back to async API' >&2
  printf '%s\n' "$non_stack_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: non-stack merge failure has no async fallback'

stack_git_log="$tmp_dir/stack-git.log"
stack_gh_log="$tmp_dir/stack-gh.log"
stack_view_count="$tmp_dir/stack-view-count"
stack_poll_count="$tmp_dir/stack-poll-count"
set +e
stack_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=native-stack-async-success \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$stack_git_log" \
  SAFE_DIRECT_MERGE_GH_LOG="$stack_gh_log" \
  SAFE_DIRECT_MERGE_PR_VIEW_COUNT_FILE="$stack_view_count" \
  SAFE_DIRECT_MERGE_ASYNC_POLL_COUNT_FILE="$stack_poll_count" \
  SAFE_DIRECT_MERGE_ASYNC_POLL_INTERVAL_SECONDS=0 \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
stack_status=$?
set -e
if [ "$stack_status" -ne 0 ] \
  || ! printf '%s\n' "$stack_output" | grep -Fq 'merged #42 via async stack merge' \
  || ! printf '%s\n' "$stack_output" | grep -Fq 'preserved native stack branch feature/mock' \
  || [ -e "$stack_git_log" ] \
  || ! grep -Fq -- '--match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$stack_gh_log" \
  || ! grep -Fq -- 'api:api --method PUT repos/nerdchanii/rpm/pulls/42/merge-async' "$stack_gh_log" \
  || ! grep -Fq -- 'X-GitHub-Api-Version: 2026-03-10' "$stack_gh_log" \
  || ! grep -Fq -- '"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$stack_gh_log" \
  || ! grep -Fq -- '"merge_method": "squash"' "$stack_gh_log" \
  || ! grep -Fq -- '"merge_action": "default"' "$stack_gh_log"; then
  printf '%s\n' 'FAIL: native stack async merge should submit and verify a bounded merge' >&2
  printf '%s\n' "$stack_output" >&2
  printf '%s\n' '--- gh log ---' >&2
  [ -f "$stack_gh_log" ] && cat "$stack_gh_log" >&2
  exit 1
fi
printf '%s\n' 'PASS: native stack async merge success uses SHA and API contract'

set +e
stack_failure_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=native-stack-async-failure \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/stack-failure-gh.log" \
  SAFE_DIRECT_MERGE_ASYNC_POLL_COUNT_FILE="$tmp_dir/stack-failure-poll-count" \
  SAFE_DIRECT_MERGE_ASYNC_POLL_INTERVAL_SECONDS=0 \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
stack_failure_status=$?
set -e
if [ "$stack_failure_status" -eq 0 ] \
  || ! printf '%s\n' "$stack_failure_output" | grep -Fq 'status=failed' \
  || printf '%s\n' "$stack_failure_output" | grep -Fq 'merged #42'; then
  printf '%s\n' 'FAIL: async failure must remain nonzero and fail closed' >&2
  printf '%s\n' "$stack_failure_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: native stack async failure blocks'

set +e
stack_timeout_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=native-stack-async-timeout \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/stack-timeout-gh.log" \
  SAFE_DIRECT_MERGE_ASYNC_POLL_COUNT_FILE="$tmp_dir/stack-timeout-poll-count" \
  SAFE_DIRECT_MERGE_ASYNC_MAX_POLLS=2 \
  SAFE_DIRECT_MERGE_ASYNC_POLL_INTERVAL_SECONDS=0 \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
stack_timeout_status=$?
set -e
if [ "$stack_timeout_status" -eq 0 ] \
  || ! printf '%s\n' "$stack_timeout_output" | grep -Fq 'timed out after 2 polls' \
  || printf '%s\n' "$stack_timeout_output" | grep -Fq 'merged #42'; then
  printf '%s\n' 'FAIL: async timeout must remain bounded and nonzero' >&2
  printf '%s\n' "$stack_timeout_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: native stack async timeout is bounded'

set +e
non_bottom_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=non-bottom-stack \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/non-bottom-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" 42 2>&1)"
non_bottom_status=$?
set -e
if [ "$non_bottom_status" -eq 0 ] \
  || ! printf '%s\n' "$non_bottom_output" | grep -Fq 'selected PR is not the native stack bottom' \
  || grep -Fq 'merge-async' "$tmp_dir/non-bottom-gh.log" 2>/dev/null; then
  printf '%s\n' 'FAIL: non-bottom native stack PR must be blocked before async merge' >&2
  printf '%s\n' "$non_bottom_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: non-bottom native stack PR is blocked'

set +e
keep_output="$(PATH="$mock_bin:$PATH" SAFE_DIRECT_MERGE_TEST_SCENARIO=dependent \
  bash "$script_dir/safe-direct-merge.sh" --dry-run --keep-branch 42 2>&1)"
keep_status=$?
set -e
if [ "$keep_status" -ne 0 ] || ! printf '%s\n' "$keep_output" | grep -Fq "(dry-run) would squash-merge and preserve branch feature/mock"; then
  printf '%s\n' 'FAIL: --keep-branch should permit a dependent-base dry run' >&2
  printf '%s\n' "$keep_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: --keep-branch preserves dependent base branch'

git_log="$tmp_dir/git.log"
gh_log="$tmp_dir/gh.log"
set +e
actual_keep_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=dependent \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$git_log" \
  SAFE_DIRECT_MERGE_GH_LOG="$gh_log" \
  bash "$script_dir/safe-direct-merge.sh" --keep-branch 42 2>&1)"
actual_keep_status=$?
set -e
if [ "$actual_keep_status" -ne 0 ] \
  || ! printf '%s\n' "$actual_keep_output" | grep -Fq 'preserved remote branch feature/mock' \
  || [ -e "$git_log" ] \
  || ! grep -Fq -- '--match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$gh_log"; then
  printf '%s\n' 'FAIL: actual --keep-branch merge must preserve the remote branch' >&2
  printf '%s\n' "$actual_keep_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: actual --keep-branch merge skips branch deletion'

set +e
head_change_output="$(PATH="$mock_bin:$PATH" \
  SAFE_DIRECT_MERGE_TEST_SCENARIO=head-changed \
  SAFE_DIRECT_MERGE_REAL_GIT="$real_git" \
  SAFE_DIRECT_MERGE_GIT_LOG="$tmp_dir/head-change-git.log" \
  SAFE_DIRECT_MERGE_GH_LOG="$tmp_dir/head-change-gh.log" \
  bash "$script_dir/safe-direct-merge.sh" --keep-branch 42 2>&1)"
head_change_status=$?
set -e
if [ "$head_change_status" -eq 0 ] \
  || ! printf '%s\n' "$head_change_output" | grep -Fq 'FAIL: gh pr merge returned non-zero' \
  || ! grep -Fq -- '--match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp_dir/head-change-gh.log"; then
  printf '%s\n' 'FAIL: a changed PR head must be rejected by the merge CAS' >&2
  printf '%s\n' "$head_change_output" >&2
  exit 1
fi
printf '%s\n' 'PASS: changed PR head is rejected by merge CAS'

if rg -n 'agent-loop' "$script_dir/safe-direct-merge.sh" >/dev/null; then
  printf '%s\n' 'FAIL: safe direct merge must not depend on the obsolete agent-loop adapter' >&2
  exit 1
fi
printf '%s\n' 'PASS: safe direct merge has no obsolete agent-loop dependency'

if rg -n 'git worktree remove|git branch -D|git push origin --delete|gh api -X DELETE' \
  "$script_dir/safe-direct-merge.sh" >/dev/null; then
  printf '%s\n' 'FAIL: safe direct merge must not perform destructive local cleanup or REST branch deletion' >&2
  exit 1
fi
printf '%s\n' 'PASS: destructive local cleanup and REST branch deletion are absent'

printf '%s\n' 'safe-direct-merge tests: PASS'
