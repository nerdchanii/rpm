#!/usr/bin/env bash
set -euo pipefail

# Trusted GitHub Action handoff for one Cloud merge result.  Cloud only
# supplies a result; this publisher independently re-collects the complete
# gate twice and owns guarded merge plus terminal issue-state writes.

usage() {
  cat <<'USAGE'
usage: publish-cloud-merge.sh --result FILE [options]

Required trusted Action inputs:
  --expected-issue NUMBER
  --expected-pr NUMBER
  --expected-base-sha SHA
  --expected-head-sha SHA

Options:
  --repo OWNER/REPO             Repository (default: GITHUB_REPOSITORY)
  --policy FILE                 Backlog policy (default: repository policy)
  --expected-base-ref BRANCH    Expected protected base branch (default: main)
  --expected-head-ref BRANCH    Expected PR head branch
  --dry-run                     Run both gates but do not merge
  -h, --help                    Show this help

The result may be `merge`, `no-work`, or `blocked`.  Only a fully matching
`merge` result can reach the single GraphQL `mergePullRequest` mutation;
blocked/no-work results use the issue label and comment handoff.  All
malformed or uncertain inputs fail closed.
USAGE
}

error() {
  printf 'publish_cloud_merge.error=%s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'publish_cloud_merge.error=%s\n' "$1" >&2
  exit 2
}

repo="${GITHUB_REPOSITORY:-}"
policy=""
result_path=""
expected_issue="${ISSUE_NUMBER:-}"
expected_pr="${PR_NUMBER:-}"
expected_base_sha="${BASE_SHA:-}"
expected_head_sha="${HEAD_SHA:-}"
expected_base_ref="${BASE_REF:-main}"
expected_head_ref="${HEAD_REF:-}"
dry_run=false

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
    --result|--cloud-result)
      [ "$#" -ge 2 ] || usage_error 'missing-result-value'
      result_path="$2"
      shift 2
      ;;
    --result=*|--cloud-result=*) result_path="${1#*=}"; shift ;;
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
    --expected-base-ref|--base-ref)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-base-ref-value'
      expected_base_ref="$2"
      shift 2
      ;;
    --expected-base-ref=*|--base-ref=*) expected_base_ref="${1#*=}"; shift ;;
    --expected-head-ref|--head-ref)
      [ "$#" -ge 2 ] || usage_error 'missing-expected-head-ref-value'
      expected_head_ref="$2"
      shift 2
      ;;
    --expected-head-ref=*|--head-ref=*) expected_head_ref="${1#*=}"; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown-option:$1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || error 'missing-gh'
command -v jq >/dev/null 2>&1 || error 'missing-jq'
command -v python3 >/dev/null 2>&1 || error 'missing-python3'

if [ -z "$policy" ]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  policy="${script_dir}/../.agents/workflows/backlog-policy.json"
else
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi
[ -r "$policy" ] || error 'policy-not-readable'

[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || error 'invalid-repository'
[[ "$expected_issue" =~ ^[1-9][0-9]*$ ]] || usage_error 'invalid-expected-issue'
[[ "$expected_pr" =~ ^[1-9][0-9]*$ ]] || usage_error 'invalid-expected-pr'
[[ "$expected_base_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error 'invalid-expected-base-sha'
[[ "$expected_head_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error 'invalid-expected-head-sha'
expected_base_sha="${expected_base_sha,,}"
expected_head_sha="${expected_head_sha,,}"
[ "$expected_base_sha" != "$expected_head_sha" ] || usage_error 'base-and-head-must-differ'
[ -n "$expected_base_ref" ] || usage_error 'missing-expected-base-ref'
[ -n "$expected_head_ref" ] || usage_error 'missing-expected-head-ref'
[ "$expected_head_ref" != "$expected_base_ref" ] || usage_error 'protected-head-ref'
[ -r "$result_path" ] || usage_error 'result-not-readable'

protected_branch="$(jq -er '.merge_gate.server_protection.branch | strings' "$policy" 2>/dev/null)" || error 'policy-protected-branch-invalid'
policy_repository="$(jq -er '.repository | strings' "$policy" 2>/dev/null)" || error 'policy-repository-invalid'
[ "$policy_repository" = "$repo" ] || error 'policy-repository-mismatch'
required_checks_json="$(jq -ce '.merge_gate.required_checks | select(type == "array" and length > 0) | unique | sort' "$policy" 2>/dev/null)" || error 'policy-required-checks-invalid'
awaiting_merge_label="$(jq -er '.labels["awaiting-merge"] | strings' "$policy" 2>/dev/null)" || error 'policy-awaiting-merge-label-invalid'
blocked_label="$(jq -er '.labels.blocked | strings' "$policy" 2>/dev/null)" || error 'policy-blocked-label-invalid'
research_label="$(jq -er '.labels.research | strings' "$policy" 2>/dev/null)" || error 'policy-research-label-invalid'
ready_label="$(jq -er '.labels.ready | strings' "$policy" 2>/dev/null)" || error 'policy-ready-label-invalid'
claimed_label="$(jq -er '.labels.claimed | strings' "$policy" 2>/dev/null)" || error 'policy-claimed-label-invalid'
review_pending_label="$(jq -er '.labels["review-pending"] | strings' "$policy" 2>/dev/null)" || error 'policy-review-pending-label-invalid'
max_no_work_attempts="$(jq -er '.merge_gate.max_no_work_attempts | select(type == "number" and floor == . and . == 5)' "$policy" 2>/dev/null)" || error 'policy-no-work-limit-invalid'
readonly max_graphql_pages=100
readonly max_graphql_comments=10000
if [ "$protected_branch" != "$expected_base_ref" ]; then
  error 'trusted-base-ref-policy-mismatch'
fi
if ! jq -e '
  .merge_gate.enabled == true and
  .merge_gate.method == "squash" and
  .merge_gate.delete_branch == false and
  .merge_gate.source_state == "awaiting-merge" and
  .merge_gate.order == "issue-number-ascending" and
  .merge_gate.batch_limit == 1
' "$policy" >/dev/null 2>&1; then
  error 'merge-policy-invalid'
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-publish-cloud-merge.XXXXXX")" || error 'temporary-directory-failed'
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

validate_result_file() {
  local bytes links
  [ -f "$result_path" ] || error 'result-not-regular'
  [ ! -L "$result_path" ] || error 'result-symlink'
  links="$(stat -c '%h' -- "$result_path" 2>/dev/null || stat -f '%l' -- "$result_path" 2>/dev/null || true)"
  [[ "$links" =~ ^[0-9]+$ ]] || error 'result-link-count-unknown'
  [ "$links" -eq 1 ] || error 'result-hardlink'
  bytes="$(wc -c <"$result_path" | tr -d '[:space:]')" || error 'result-size-read-failed'
  [[ "$bytes" =~ ^[0-9]+$ ]] || error 'result-size-invalid'
  [ "$bytes" -le 1048576 ] || error 'result-too-large'
  cp -- "$result_path" "$tmp_dir/result.json" || error 'result-copy-failed'
  chmod 600 "$tmp_dir/result.json" 2>/dev/null || true
}

validate_result_file
result_json="$(python3 - "$tmp_dir/result.json" "$expected_issue" "$expected_pr" "$expected_base_sha" "$expected_head_sha" <<'PY'
import json
import re
import sys
from pathlib import Path


path, expected_issue_text, expected_pr_text, expected_base, expected_head = sys.argv[1:]
expected_issue = int(expected_issue_text)
expected_pr = int(expected_pr_text)
expected_keys = {
    "version",
    "lane",
    "status",
    "issue",
    "pr",
    "base_sha",
    "head_sha",
    "summary",
    "validation",
    "actionable_findings_remaining",
    "next_state",
    "correction_label",
    "resolved_thread_ids",
    "followups",
}


class Invalid(Exception):
    pass


# The merge publisher consumes Cloud-written text too.  GitHub interprets
# these keywords as closing directives in a PR body, so only the publisher's
# own managed directive may appear in the lifecycle flow.
closing_directive = re.compile(
    r"(?im)(^|[^A-Za-z0-9])"
    r"(?:close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\b"
    r"(?:[^\r\n#]{0,80}#[1-9][0-9]*(?![0-9])|"
    r"[^\r\n]{0,80}https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*(?![0-9]))"
)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid("duplicate-json-key")
        result[key] = value
    return result


def reject_constant(value):
    raise Invalid("invalid-json-number:" + value)


try:
    value = json.loads(
        Path(path).read_text(encoding="utf-8"),
        object_pairs_hook=unique_pairs,
        parse_constant=reject_constant,
    )
    if type(value) is not dict or set(value) != expected_keys:
        raise Invalid("schema-keys-invalid")
    if type(value["version"]) is not int or value["version"] != 1:
        raise Invalid("version-invalid")
    if value["lane"] != "merge":
        raise Invalid("lane-invalid")
    status = value["status"]
    if status not in {"merge", "no-work", "blocked"}:
        raise Invalid("status-invalid")
    issue = value["issue"]
    if type(issue) is not int or issue <= 0 or issue != expected_issue:
        raise Invalid("issue-invalid")
    pr = value["pr"]
    if pr is not None and (type(pr) is not int or pr <= 0):
        raise Invalid("pr-invalid")
    base_sha = value["base_sha"]
    if type(base_sha) is not str or re.fullmatch(r"[0-9a-f]{40}", base_sha) is None:
        raise Invalid("base-sha-invalid")
    if base_sha != expected_base:
        raise Invalid("base-sha-mismatch")
    head_sha = value["head_sha"]
    if head_sha is not None and (
        type(head_sha) is not str or re.fullmatch(r"[0-9a-f]{40}", head_sha) is None
    ):
        raise Invalid("head-sha-invalid")
    summary = value["summary"]
    if type(summary) is not str or len(summary.encode("utf-8")) > 4000:
        raise Invalid("summary-invalid")
    if closing_directive.search(summary):
        raise Invalid("summary-closing-directive-forbidden")
    validation = value["validation"]
    if type(validation) is not list or len(validation) > 50:
        raise Invalid("validation-invalid")
    if any(type(item) is not str or len(item.encode("utf-8")) > 2048 for item in validation):
        raise Invalid("validation-entry-invalid")
    if any(closing_directive.search(item) for item in validation):
        raise Invalid("validation-closing-directive-forbidden")
    if value["actionable_findings_remaining"] is not False:
        raise Invalid("actionable-findings-invalid")
    if value["correction_label"] is not None:
        raise Invalid("correction-label-invalid")
    if value["resolved_thread_ids"] != [] or value["followups"] != []:
        raise Invalid("merge-side-effects-invalid")
    expected_state = {
        "merge": "awaiting-merge",
        "no-work": "unchanged",
        "blocked": "blocked",
    }[status]
    if value["next_state"] != expected_state:
        raise Invalid("next-state-invalid")
    if status == "merge":
        if type(pr) is not int or pr != expected_pr:
            raise Invalid("merge-pr-invalid")
        if type(head_sha) is not str or head_sha != expected_head:
            raise Invalid("merge-head-sha-invalid")
    elif pr is not None and pr != expected_pr:
        raise Invalid("non-merge-pr-mismatch")
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
except Invalid as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
except (OSError, UnicodeError, ValueError, TypeError) as exc:
    print("result-parse-failed:" + type(exc).__name__, file=sys.stderr)
    raise SystemExit(1)
PY
)" || error 'result-envelope-invalid'

result_status="$(jq -er '.status' <<<"$result_json")"
result_summary="$(jq -er '.summary' <<<"$result_json")"

read_issue_comments() {
  local target_issue="$1" comments_file="$2"
  local pages_file="$tmp_dir/merge-issue-comment-pages.jsonl"
  local cursors_file="$tmp_dir/merge-issue-comment-cursors.txt"
  local query response page_count=0 comment_count=0 page_comment_count has_next next_cursor cursor=''
  local -a gh_args

  [[ "$target_issue" =~ ^[1-9][0-9]*$ ]] || error 'merge-comment-issue-invalid'
  : >"$pages_file"
  : >"$cursors_file"
  query='query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){nameWithOwner,issue(number:$number){number,repository{nameWithOwner},comments(first:100,after:$after){pageInfo{hasNextPage,endCursor},nodes{id,body,author{login}}}}}}'

  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le "$max_graphql_pages" ] || error 'merge-comment-pagination-limit'
    if [ -n "$cursor" ]; then
      if grep -Fqx -- "$cursor" "$cursors_file"; then
        error 'merge-comment-pagination-cursor-repeat'
      fi
      case "$cursor" in *$'\n'*|*$'\r'*) error 'merge-comment-pagination-cursor-invalid' ;; esac
      printf '%s\n' "$cursor" >>"$cursors_file"
    fi

    gh_args=(api graphql -f query="$query" \
      -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="$target_issue")
    [ -z "$cursor" ] || gh_args+=(-f after="$cursor")
    if ! response="$(GH_REPO="$repo" gh "${gh_args[@]}")"; then
      error 'merge-comment-read-failed'
    fi
    jq -e --arg expected_repo "$repo" --argjson expected_issue "$target_issue" '
      type == "object" and
      ((.errors? == null) or (.errors | type == "array" and length == 0)) and
      (.data | type == "object") and
      (.data.repository | type == "object") and
      (.data.repository.nameWithOwner == $expected_repo) and
      (.data.repository.issue | type == "object") and
      (.data.repository.issue.number == $expected_issue) and
      (.data.repository.issue.repository | type == "object") and
      (.data.repository.issue.repository.nameWithOwner == $expected_repo) and
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
    ' <<<"$response" >/dev/null 2>&1 || error 'merge-comment-response-invalid'
    printf '%s\n' "$response" >>"$pages_file"

    page_comment_count="$(jq -er '.data.repository.issue.comments.nodes | length' <<<"$response")" ||
      error 'merge-comment-response-invalid'
    comment_count=$((comment_count + page_comment_count))
    [ "$comment_count" -le "$max_graphql_comments" ] || error 'merge-comment-count-limit'
    jq -s -e '
      [.[].data.repository.issue.comments.nodes[].id] as $ids |
      ($ids | length) == ($ids | unique | length)
    ' "$pages_file" >/dev/null 2>&1 || error 'merge-comment-pagination-duplicate-id'

    has_next="$(jq -r '.data.repository.issue.comments.pageInfo.hasNextPage' <<<"$response")" ||
      error 'merge-comment-response-invalid'
    next_cursor="$(jq -r '.data.repository.issue.comments.pageInfo.endCursor // empty' <<<"$response")" ||
      error 'merge-comment-response-invalid'
    if [ "$has_next" = true ]; then
      [ -n "$next_cursor" ] || error 'merge-comment-pagination-cursor-invalid'
      [ "$next_cursor" != "$cursor" ] || error 'merge-comment-pagination-cursor-stalled'
      cursor="$next_cursor"
    elif [ "$has_next" = false ]; then
      break
    else
      error 'merge-comment-response-invalid'
    fi
  done

  jq -s -c '
    {comments: [.[].data.repository.issue.comments.nodes[] |
      {id,body,author:(if .author == null then null else {login:.author.login} end)}]}
  ' "$pages_file" >"$comments_file" 2>/dev/null || error 'merge-comment-normalization-failed'
  jq -e '
    type == "object" and
    (.comments | type == "array" and all(.[];
      type == "object" and (.id | type == "string" and length > 0) and
      (.body | type == "string") and
      ((.author == null) or
       (.author | type == "object" and (.login | type == "string" and length > 0)))
    ))
  ' "$comments_file" >/dev/null 2>&1 || error 'merge-comment-normalization-failed'
}

issue_state_json() {
  local metadata comments_file
  metadata="$(gh issue view "$expected_issue" --repo "$repo" --json number,state,labels)" || return 1
  comments_file="$tmp_dir/merge-issue-comments.json"
  read_issue_comments "$expected_issue" "$comments_file" || return 1
  jq -c --slurpfile comments "$comments_file" '. + {comments:$comments[0].comments}' <<<"$metadata"
}

validate_issue_state_json() {
  local issue_json="$1"
  jq -e --argjson issue "$expected_issue" '
    type == "object" and
    .number == $issue and
    (.state | type == "string") and
    (.labels | type == "array" and all(.[]; ((type == "object" and (.name | type == "string")) or type == "string"))) and
    (.comments | type == "array" and all(.[];
      type == "object" and
      (.id | type == "string" and length > 0) and
      (.body | type == "string") and
      ((.author == null) or
       (.author | type == "object" and (.login | type == "string" and length > 0)))
    ))
  ' <<<"$issue_json" >/dev/null 2>&1 || error 'invalid-merge-issue-response'
}

issue_labels() {
  jq -r '.labels[] | if type == "object" then .name else . end' <<<"$1"
}

label_count() {
  local labels="$1" wanted="$2"
  printf '%s\n' "$labels" | awk -v wanted="$wanted" '$0 == wanted { count++ } END { print count + 0 }'
}

ordinary_issue_labels() {
  issue_labels "$1" |
    grep -Fvx -e "$research_label" -e "$ready_label" -e "$claimed_label" \
      -e "$review_pending_label" -e "$awaiting_merge_label" -e "$blocked_label" | sort || true
}

validate_exact_issue_state() {
  local issue_json="$1" expected_label="$2" labels state_label count
  labels="$(issue_labels "$issue_json")"
  for state_label in \
    "$research_label" "$ready_label" "$claimed_label" \
    "$review_pending_label" "$awaiting_merge_label" "$blocked_label"; do
    count="$(label_count "$labels" "$state_label")"
    [ "$count" -le 1 ] || error 'duplicate-merge-lifecycle-label'
  done
  [ "$(label_count "$labels" "$expected_label")" -eq 1 ] || error 'merge-issue-state-mismatch'
  for state_label in \
    "$research_label" "$ready_label" "$claimed_label" \
    "$review_pending_label" "$awaiting_merge_label" "$blocked_label"; do
    if [ "$state_label" != "$expected_label" ]; then
      [ "$(label_count "$labels" "$state_label")" -eq 0 ] || error 'merge-issue-conflicting-state'
    fi
  done
}

comment_has_marker() {
  local comments_json="$1" marker="$2"
  jq -e --arg marker "$marker" '
    any(.comments[];
      ((.author | type == "object" and (.login == "github-actions[bot]" or .login == "nerdchanii"))) and
      ((.body | split("\n")[0]) == $marker)
    )
  ' <<<"$comments_json" >/dev/null 2>&1
}

friendly_reason() {
  case "$1" in
    checks-failed) printf '필수 검사가 실패했습니다.' ;;
    checks-pending) printf '필수 검사가 아직 끝나지 않았습니다.' ;;
    mergeability-unknown) printf 'GitHub가 아직 병합 가능 여부를 알려주지 않았습니다.' ;;
    merge-state-not-clean) printf 'PR의 병합 준비 상태가 아직 깨끗하지 않습니다.' ;;
    review-findings-remain|unresolved-review-conversations) printf '해결되지 않은 리뷰 대화가 남아 있습니다.' ;;
    merge-queue-active) printf 'PR이 GitHub 병합 대기열에 들어가 있습니다.' ;;
    auto-merge-enabled) printf 'PR에 기존 자동 병합 요청이 남아 있습니다.' ;;
    no-open-closing-pr) printf '이슈를 닫는 열린 PR을 찾지 못했습니다.' ;;
    multiple-open-closing-prs) printf '이슈를 닫는 열린 PR이 여러 개입니다.' ;;
    cross-repository-closing-pr) printf '이슈와 다른 저장소의 PR이 연결되어 있습니다.' ;;
    server-protection-*) printf 'main 브랜치 보호 규칙이 정책과 다릅니다.' ;;
    merge-evidence-drift|merge-verdict-drift) printf '두 번 확인한 GitHub 상태가 서로 달라졌습니다.' ;;
    merge-target-mismatch|merge-verdict-target-mismatch|merge-evidence-target-mismatch) printf '선택한 이슈와 PR의 연결 정보가 달라졌습니다.' ;;
    no-work-retry-limit) printf '병합 대기를 다섯 번 확인했지만 조건이 충족되지 않았습니다.' ;;
    *) printf '병합 조건을 확인하지 못했습니다.' ;;
  esac
}

post_comment_once() {
  local marker="$1" body_file="$2" comments_json comments_after
  local comments_file="$tmp_dir/merge-comment-inventory.json"
  read_issue_comments "$expected_issue" "$comments_file" ||
    error 'merge-comment-inventory-failed'
  comments_json="$(<"$comments_file")"
  if comment_has_marker "$comments_json" "$marker"; then
    return 0
  fi
  gh issue comment "$expected_issue" --repo "$repo" --body-file "$body_file" >/dev/null 2>&1 ||
    error 'merge-comment-write-failed'
  read_issue_comments "$expected_issue" "$comments_file" ||
    error 'merge-comment-refetch-failed'
  comments_after="$(<"$comments_file")"
  comment_has_marker "$comments_after" "$marker" || error 'merge-comment-not-verified'
}

write_block_comment() {
  local reason="$1" details="$2" marker explanation
  explanation="$(friendly_reason "$reason")"
  marker="<!-- rpm-agent-merge-block: issue=${expected_issue};pr=${expected_pr};head=${expected_head_sha} -->"
  {
    printf '%s\n\n' "$marker"
    printf 'Codex Cloud 병합을 안전하게 멈췄습니다.\n\n'
    printf '이슈 상태: `%s`\n' "$blocked_label"
    printf '사유: `%s`\n' "$reason"
    printf '쉽게 말하면: %s\n' "$explanation"
    if [ -n "$details" ]; then
      printf '상세: %s\n' "$details"
    fi
    printf 'Cloud 요약: %s\n\n' "$result_summary"
    printf '다음 단계: 사유를 해결한 뒤 이슈를 `%s` 또는 `%s`로 다시 이동해 주세요.\n' "$ready_label" "$research_label"
  } >"$tmp_dir/merge-block-comment.md"
}

publish_blocked_state() {
  local reason="${1:-cloud-blocked}" details="${2:-}"
  local issue_before issue_after labels ordinary_before ordinary_after marker issue_state
  [ -n "${GH_TOKEN:-}" ] || error 'missing-gh-token-for-merge-state'
  issue_before="$(issue_state_json 2>/dev/null)" || error 'blocked-issue-read-failed'
  validate_issue_state_json "$issue_before"
  issue_state="$(jq -r '.state | ascii_upcase' <<<"$issue_before")"
  [ "$issue_state" = OPEN ] || error 'blocked-issue-not-open'
  labels="$(issue_labels "$issue_before")"
  if [ "$(label_count "$labels" "$blocked_label")" -eq 1 ]; then
    validate_exact_issue_state "$issue_before" "$blocked_label"
  elif [ "$(label_count "$labels" "$awaiting_merge_label")" -eq 1 ]; then
    validate_exact_issue_state "$issue_before" "$awaiting_merge_label"
    ordinary_before="$(ordinary_issue_labels "$issue_before")"
    gh issue edit "$expected_issue" --repo "$repo" \
      --remove-label "$awaiting_merge_label" --add-label "$blocked_label" >/dev/null 2>&1 ||
      error 'blocked-state-transition-failed'
    issue_after="$(issue_state_json 2>/dev/null)" || error 'blocked-state-refetch-failed'
    validate_issue_state_json "$issue_after"
    validate_exact_issue_state "$issue_after" "$blocked_label"
    ordinary_after="$(ordinary_issue_labels "$issue_after")"
    [ "$ordinary_before" = "$ordinary_after" ] || error 'blocked-ordinary-labels-changed'
  else
    error 'blocked-state-cas-mismatch'
  fi

  write_block_comment "$reason" "$details"
  marker="<!-- rpm-agent-merge-block: issue=${expected_issue};pr=${expected_pr};head=${expected_head_sha} -->"
  post_comment_once "$marker" "$tmp_dir/merge-block-comment.md"
}

no_work_retry_count() {
  local comments_json="$1" comment_json body first_line author marker_data
  local marker_re='^<!-- rpm-agent-merge-retry: issue=([1-9][0-9]*);pr=([1-9][0-9]*);head=([0-9a-f]{40});attempt=([1-5]) -->$'
  local attempts_json='[]' marker_issue marker_pr marker_head marker_attempt count attempt

  while IFS= read -r comment_json || [ -n "$comment_json" ]; do
    body="$(jq -r '.body' <<<"$comment_json")" || error 'merge-retry-comment-invalid'
    author="$(jq -r '.author.login // empty' <<<"$comment_json")" || error 'merge-retry-comment-invalid'
    case "$author" in
      'github-actions[bot]'|nerdchanii) ;;
      *) continue ;;
    esac
    [[ "$body" == *'<!-- rpm-agent-merge-retry:'* ]] || continue
    first_line="${body%%$'\n'*}"
    if [[ ! "$first_line" =~ $marker_re ]]; then
      error 'merge-retry-marker-malformed'
    fi
    marker_issue="${BASH_REMATCH[1]}"
    marker_pr="${BASH_REMATCH[2]}"
    marker_head="${BASH_REMATCH[3]}"
    marker_attempt="${BASH_REMATCH[4]}"
    [ "$marker_issue" = "$expected_issue" ] || error 'merge-retry-marker-issue-mismatch'
    # Retry history belongs to one issue/PR/head tuple.  A valid marker for
    # the same issue but an older PR or head is retained as audit history and
    # must not consume attempts for the current head.
    if [ "$marker_pr" != "$expected_pr" ] || [ "$marker_head" != "$expected_head_sha" ]; then
      continue
    fi
    if [ "$(jq --argjson attempt "$marker_attempt" '[.[] | select(. == $attempt)] | length' <<<"$attempts_json")" -ne 0 ]; then
      error 'merge-retry-marker-duplicate'
    fi
    attempts_json="$(jq -c --argjson attempt "$marker_attempt" '. + [$attempt]' <<<"$attempts_json")"
  done < <(jq -c '.comments[]' <<<"$comments_json")

  count="$(jq 'length' <<<"$attempts_json")"
  for ((attempt = 1; attempt <= count; attempt++)); do
    jq -e --argjson attempt "$attempt" 'any(.[]; . == $attempt)' <<<"$attempts_json" >/dev/null 2>&1 ||
      error 'merge-retry-marker-sequence-gap'
  done
  [ "$count" -le "$max_no_work_attempts" ] || error 'merge-retry-marker-attempt-limit'
  printf '%s\n' "$count"
}

write_no_work_comment() {
  local reason="$1" details="$2" attempt="$3" marker explanation
  explanation="$(friendly_reason "$reason")"
  marker="<!-- rpm-agent-merge-retry: issue=${expected_issue};pr=${expected_pr};head=${expected_head_sha};attempt=${attempt} -->"
  {
    printf '%s\n\n' "$marker"
    printf 'Codex Cloud 병합을 기다리는 중입니다. 시도 %s/%s입니다.\n\n' "$attempt" "$max_no_work_attempts"
    printf '사유: `%s`\n' "$reason"
    printf '쉽게 말하면: %s\n' "$explanation"
    if [ -n "$details" ]; then
      printf '상세: %s\n' "$details"
    fi
    printf 'Cloud 요약: %s\n\n' "$result_summary"
    printf '같은 문제가 계속되면 %s회 시도 후 이슈를 `%s`로 이동해 자동 반복을 멈춥니다.\n' "$max_no_work_attempts" "$blocked_label"
  } >"$tmp_dir/merge-no-work-comment.md"
}

publish_no_work_state() {
  local reason="${1:-no-work}" details="${2:-}"
  local issue_before issue_after labels ordinary_before ordinary_after comments_json count next_attempt marker issue_state
  [ -n "${GH_TOKEN:-}" ] || error 'missing-gh-token-for-merge-state'
  issue_before="$(issue_state_json 2>/dev/null)" || error 'no-work-issue-read-failed'
  validate_issue_state_json "$issue_before"
  issue_state="$(jq -r '.state | ascii_upcase' <<<"$issue_before")"
  if [ "$issue_state" != OPEN ]; then
    printf 'publish_cloud_merge: status=no-work; merge=0; reason=issue-not-open\n'
    return 0
  fi
  labels="$(issue_labels "$issue_before")"
  if [ "$(label_count "$labels" "$blocked_label")" -eq 1 ]; then
    validate_exact_issue_state "$issue_before" "$blocked_label"
    printf 'publish_cloud_merge: status=no-work; merge=0; reason=issue-already-blocked\n'
    return 0
  fi
  if [ "$(label_count "$labels" "$awaiting_merge_label")" -ne 1 ]; then
    printf 'publish_cloud_merge: status=no-work; merge=0; reason=issue-state-changed\n'
    return 0
  fi
  validate_exact_issue_state "$issue_before" "$awaiting_merge_label"
  ordinary_before="$(ordinary_issue_labels "$issue_before")"
  comments_json="$(jq -c '{comments:.comments}' <<<"$issue_before")"
  count="$(no_work_retry_count "$comments_json")"
  if [ "$count" -ge $((max_no_work_attempts - 1)) ]; then
    publish_blocked_state 'no-work-retry-limit' "attempt=${max_no_work_attempts}/${max_no_work_attempts}; last_gate=${reason}; ${details}"
    printf 'publish_cloud_merge: status=blocked; merge=0; reason=no-work-retry-limit; issue=%s\n' "$expected_issue"
    return 0
  fi
  next_attempt=$((count + 1))
  write_no_work_comment "$reason" "$details" "$next_attempt"
  marker="<!-- rpm-agent-merge-retry: issue=${expected_issue};pr=${expected_pr};head=${expected_head_sha};attempt=${next_attempt} -->"
  post_comment_once "$marker" "$tmp_dir/merge-no-work-comment.md"
  issue_after="$(issue_state_json 2>/dev/null)" || error 'no-work-issue-refetch-failed'
  validate_issue_state_json "$issue_after"
  validate_exact_issue_state "$issue_after" "$awaiting_merge_label"
  ordinary_after="$(ordinary_issue_labels "$issue_after")"
  [ "$ordinary_before" = "$ordinary_after" ] || error 'no-work-ordinary-labels-changed'
  printf 'publish_cloud_merge: status=no-work; merge=0; reason=retry-recorded; attempt=%s/%s; issue=%s\n' \
    "$next_attempt" "$max_no_work_attempts" "$expected_issue"
}

publish_gate_terminal_state() {
  local status="$1" reason="$2" details="${3:-}"
  if [ "$dry_run" = true ]; then
    printf 'publish_cloud_merge: status=%s; merge=0; dry-run=true; reason=%s\n' "$status" "$reason"
    return 0
  fi
  case "$status" in
    blocked)
      publish_blocked_state "$reason" "$details"
      printf 'publish_cloud_merge: status=blocked; merge=0; reason=%s; issue=%s\n' "$reason" "$expected_issue"
      ;;
    no-work)
      publish_no_work_state "$reason" "$details"
      ;;
    *)
      error 'invalid-terminal-gate-status'
      ;;
  esac
}

if [ "$result_status" = merge ]; then
  jq -e --arg base_sha "$expected_base_sha" --arg head_sha "$expected_head_sha" \
    '(.base_sha | type == "string") and (.head_sha | type == "string") and .base_sha == $base_sha and .head_sha == $head_sha' \
    <<<"$result_json" >/dev/null 2>&1 || error 'result-sha-mismatch'
  jq -e --argjson issue "$expected_issue" --argjson pr "$expected_pr" \
    --arg base_sha "$expected_base_sha" --arg head_sha "$expected_head_sha" '
      .issue == $issue and .pr == $pr and
      .base_sha == $base_sha and .head_sha == $head_sha and
      .lane == "merge" and .status == "merge" and
      .next_state == "awaiting-merge" and
      .actionable_findings_remaining == false and
      .correction_label == null and
      .resolved_thread_ids == [] and .followups == []
    ' <<<"$result_json" >/dev/null 2>&1 || error 'result-target-mismatch'
else
  # A non-merge result is still a stateful terminal handoff.  The publisher
  # records a bounded retry or demotes the same awaiting issue so the scheduler
  # cannot select it forever.
  if ! jq -e --argjson issue "$expected_issue" --argjson pr "$expected_pr" \
    '((.issue? == null) or (.issue == $issue)) and ((.pr? == null) or (.pr == $pr))' \
    <<<"$result_json" >/dev/null 2>&1; then
    error 'non-merge-result-target-mismatch'
  fi
  publish_gate_terminal_state "$result_status" "cloud-result-${result_status}" "$result_summary"
  exit 0
fi

collector="${script_dir}/collect-merge-gate-evidence.sh"
checker="${script_dir}/check-merge-gate.py"
[ -x "$collector" ] || error 'collector-not-executable'
[ -r "$checker" ] || error 'checker-not-readable'

collect_and_check() {
  local label="$1" evidence_path="$2" gate_path="$3" checker_rc=0 gate_json
  if ! "$collector" \
    --repo "$repo" \
    --policy "$policy" \
    --output "$evidence_path" \
    --expected-issue "$expected_issue" \
    --expected-pr "$expected_pr" \
    --expected-base-sha "$expected_base_sha" \
    --expected-head-sha "$expected_head_sha"; then
    error "${label}-collector-failed"
  fi
  [ -s "$evidence_path" ] || error "${label}-evidence-empty"
  if ! jq -e 'type == "object" and (.schema_version == 1) and (.repository | type == "string") and (.issues | type == "array")' "$evidence_path" >/dev/null 2>&1; then
    error "${label}-evidence-invalid"
  fi
  gate_json=""
  if gate_json="$(python3 "$checker" \
    --policy "$policy" \
    --issues-file "$evidence_path" \
    --operation select-merge \
    --expected-head-sha "$expected_head_sha" \
    --expected-base-sha "$expected_base_sha" 2>"$tmp_dir/${label}-checker.stderr")"; then
    checker_rc=0
  else
    checker_rc=$?
  fi
  printf '%s' "$gate_json" >"$gate_path"
  if ! jq -e 'type == "object" and .type == "merge_gate_contract" and (.data | type == "object") and (.data.status | type == "string")' "$gate_path" >/dev/null 2>&1; then
    error "${label}-checker-invalid"
  fi
  # A blocked checker is a valid deterministic verdict.  Runtime/parser
  # failures produce no valid JSON and are rejected above.
  if [ "$checker_rc" -ne 0 ] && [ "$(jq -r '.data.status' "$gate_path")" != blocked ]; then
    error "${label}-checker-failed"
  fi
}

collect_and_check first "$tmp_dir/evidence-first.json" "$tmp_dir/gate-first.json"
first_status="$(jq -er '.data.status' "$tmp_dir/gate-first.json")"
if [ "$first_status" != merge ]; then
  first_reason="$(jq -r '.data.reason // "unknown"' "$tmp_dir/gate-first.json")"
  first_details="$(jq -c '.data' "$tmp_dir/gate-first.json")"
  publish_gate_terminal_state "$first_status" "$first_reason" "$first_details"
  exit 0
fi

collect_and_check second "$tmp_dir/evidence-second.json" "$tmp_dir/gate-second.json"
second_status="$(jq -er '.data.status' "$tmp_dir/gate-second.json")"
if [ "$second_status" != merge ]; then
  second_reason="$(jq -r '.data.reason // "unknown"' "$tmp_dir/gate-second.json")"
  second_details="$(jq -c '.data' "$tmp_dir/gate-second.json")"
  publish_gate_terminal_state "$second_status" "$second_reason" "$second_details"
  exit 0
fi
if ! cmp -s "$tmp_dir/evidence-first.json" "$tmp_dir/evidence-second.json"; then
  publish_gate_terminal_state blocked 'merge-evidence-drift' 'The two live merge-gate snapshots differ.'
  exit 0
fi
first_verdict="$(jq -S -c '.data' "$tmp_dir/gate-first.json")"
second_verdict="$(jq -S -c '.data' "$tmp_dir/gate-second.json")"
if [ "$first_verdict" != "$second_verdict" ]; then
  publish_gate_terminal_state blocked 'merge-verdict-drift' 'The two live merge-gate decisions differ.'
  exit 0
fi

if ! jq -e --argjson issue "$expected_issue" --argjson pr "$expected_pr" \
  --arg head "$expected_head_sha" --arg base "$expected_base_sha" \
  --arg base_ref "$expected_base_ref" --arg head_ref "$expected_head_ref" '
    .status == "merge" and .issue == $issue and .pr == $pr and
    .expected_head_sha == $head
  ' <<<"$second_verdict" >/dev/null 2>&1; then
  publish_gate_terminal_state blocked 'merge-verdict-target-mismatch' 'The live merge-gate result does not match the selected PR or head.'
  exit 0
fi
if ! jq -e --argjson issue "$expected_issue" --argjson pr "$expected_pr" \
  --arg base_ref "$expected_base_ref" --arg head_ref "$expected_head_ref" \
  '.issues | any(.[]; .number == $issue and
    (.closing_prs | type == "array" and length == 1) and
    (.closing_prs[0].number == $pr and .closing_prs[0].base_ref == $base_ref and .closing_prs[0].head_ref == $head_ref) and
    (.closing_prs[0].closing_issue_numbers | type == "array" and length == 1 and .[0] == $issue))' \
  "$tmp_dir/evidence-second.json" >/dev/null 2>&1; then
  publish_gate_terminal_state blocked 'merge-evidence-target-mismatch' 'The live evidence does not bind the selected issue to the selected PR.'
  exit 0
fi

if [ "$dry_run" = true ]; then
  printf 'publish_cloud_merge: status=merge; merge=0; dry-run=true; issue=%s; pr=%s; head=%s\n' "$expected_issue" "$expected_pr" "$expected_head_sha"
  exit 0
fi

# Read the PR node immediately before the mutation.  The node ID is opaque and
# must come from this trusted live read; the number, refs, and both object IDs
# are checked against the two previously verified snapshots.
merge_preflight_query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    pullRequest(number:$number) {
      id
      number
      state
      headRefName
      baseRefName
      headRefOid
      baseRefOid
      repository { nameWithOwner }
      closingIssuesReferences(first:100) {
        pageInfo { hasNextPage endCursor }
        nodes { number repository { nameWithOwner } }
      }
    }
  }
}'
merge_preflight_response="$(GH_REPO="$repo" gh api graphql \
  -f "query=${merge_preflight_query}" \
  -f "owner=${repo%%/*}" \
  -f "name=${repo#*/}" \
  -F "number=${expected_pr}" 2>/dev/null)" || error 'merge-preflight-read-failed'
if ! jq -e \
  --argjson pr "$expected_pr" \
  --arg head "$expected_head_sha" \
  --arg base "$expected_base_sha" \
  --arg base_ref "$expected_base_ref" \
  --arg head_ref "$expected_head_ref" \
  --arg repo "$repo" \
  --argjson issue "$expected_issue" '
    type == "object" and
    ((.errors? == null) or (.errors | type == "array" and length == 0)) and
    (.data.repository | type == "object") and
    (.data.repository.pullRequest | type == "object") and
    (.data.repository.pullRequest.id | type == "string" and length > 0 and test("^[^[:space:]]+$")) and
    (.data.repository.pullRequest.number == $pr) and
    (.data.repository.pullRequest.state == "OPEN") and
    (.data.repository.pullRequest.headRefName == $head_ref) and
    (.data.repository.pullRequest.baseRefName == $base_ref) and
    (.data.repository.pullRequest.headRefOid | type == "string" and ascii_downcase == ($head | ascii_downcase)) and
    (.data.repository.pullRequest.baseRefOid | type == "string" and ascii_downcase == ($base | ascii_downcase)) and
    (.data.repository.pullRequest.repository | type == "object" and .nameWithOwner == $repo) and
    (.data.repository.pullRequest.closingIssuesReferences | type == "object") and
    (.data.repository.pullRequest.closingIssuesReferences.pageInfo | type == "object" and .hasNextPage == false) and
    (.data.repository.pullRequest.closingIssuesReferences.nodes | type == "array" and length == 1) and
    (.data.repository.pullRequest.closingIssuesReferences.nodes[0] | type == "object" and .number == $issue and
      (.repository | type == "object" and .nameWithOwner == $repo))
  ' <<<"$merge_preflight_response" >/dev/null 2>&1; then
  error 'merge-preflight-response-invalid'
fi
merge_pr_node_id="$(jq -er '.data.repository.pullRequest.id' <<<"$merge_preflight_response")" ||
  error 'merge-preflight-node-id-invalid'

# This is the only PR merge write in the script.  Use the GraphQL mutation
# directly so a branch merge queue cannot turn this operation into an implicit
# enqueue.  expectedHeadOid is GitHub's server-side compare-and-set guard.
merge_mutation='mutation($input:MergePullRequestInput!) {
  mergePullRequest(input:$input) {
    pullRequest {
      id
      number
      state
      headRefOid
      baseRefName
      baseRefOid
      mergeCommit { oid }
    }
  }
}'
merge_request_path="$tmp_dir/merge-request.json"
if ! jq -n \
  --arg query "$merge_mutation" \
  --arg node_id "$merge_pr_node_id" \
  --arg head "$expected_head_sha" \
  '{query:$query,variables:{input:{pullRequestId:$node_id,expectedHeadOid:$head,mergeMethod:"SQUASH"}}}' \
  >"$merge_request_path"; then
  error 'merge-input-build-failed'
fi
merge_response="$(GH_REPO="$repo" gh api graphql --input "$merge_request_path" 2>/dev/null)" ||
  error 'merge-command-failed'
if ! jq -e \
  --argjson pr "$expected_pr" \
  --arg node_id "$merge_pr_node_id" \
  --arg head "$expected_head_sha" \
  --arg base "$expected_base_sha" \
  --arg base_ref "$expected_base_ref" '
    type == "object" and
    ((.errors? == null) or (.errors | type == "array" and length == 0)) and
    (.data.mergePullRequest | type == "object") and
    (.data.mergePullRequest.pullRequest | type == "object") and
    (.data.mergePullRequest.pullRequest.id == $node_id) and
    (.data.mergePullRequest.pullRequest.number == $pr) and
    (.data.mergePullRequest.pullRequest.state == "MERGED") and
    (.data.mergePullRequest.pullRequest.headRefOid | type == "string" and ascii_downcase == ($head | ascii_downcase)) and
    (.data.mergePullRequest.pullRequest.baseRefName == $base_ref) and
    (.data.mergePullRequest.pullRequest.baseRefOid | type == "string" and ascii_downcase == ($base | ascii_downcase)) and
    (.data.mergePullRequest.pullRequest.mergeCommit | type == "object") and
    (.data.mergePullRequest.pullRequest.mergeCommit.oid | type == "string" and test("^[0-9a-fA-F]{40}$"))
  ' <<<"$merge_response" >/dev/null 2>&1; then
  error 'merge-response-invalid'
fi

post_pr="$(gh pr view "$expected_pr" --repo "$repo" --json number,state,mergedAt,mergeCommit,headRefOid,baseRefName 2>/dev/null)" || error 'post-merge-pr-read-failed'
if ! jq -e --argjson pr "$expected_pr" --arg head "$expected_head_sha" --arg base "$expected_base_ref" '
  type == "object" and .number == $pr and .state == "MERGED" and
  (.mergedAt | type == "string" and length > 0) and
  (.mergeCommit | type == "object") and (.mergeCommit.oid | type == "string" and test("^[0-9a-fA-F]{40}$")) and
  .headRefOid == $head and .baseRefName == $base
' <<<"$post_pr" >/dev/null 2>&1; then
  error 'post-merge-pr-state-invalid'
fi
post_issue_attempt=1
post_issue_max_attempts=5
while [ "$post_issue_attempt" -le "$post_issue_max_attempts" ]; do
  post_issue="$(gh issue view "$expected_issue" --repo "$repo" --json number,state 2>/dev/null)" ||
    error 'post-merge-issue-read-failed'
  if ! jq -e --argjson issue "$expected_issue" '
    type == "object" and .number == $issue and
    (.state == "OPEN" or .state == "CLOSED")
  ' <<<"$post_issue" >/dev/null 2>&1; then
    error 'post-merge-issue-state-invalid'
  fi
  if jq -e --argjson issue "$expected_issue" '.number == $issue and .state == "CLOSED"' <<<"$post_issue" >/dev/null 2>&1; then
    break
  fi
  if [ "$post_issue_attempt" -eq "$post_issue_max_attempts" ]; then
    error 'post-merge-issue-state-invalid'
  fi
  sleep 1 || error 'post-merge-issue-retry-delay-failed'
  post_issue_attempt=$((post_issue_attempt + 1))
done

merge_commit="$(jq -r '.mergeCommit.oid' <<<"$post_pr")"
printf 'publish_cloud_merge: status=merged; merge=1; issue=%s; pr=%s; head=%s; merge_commit=%s\n' \
  "$expected_issue" "$expected_pr" "$expected_head_sha" "$merge_commit"
