#!/usr/bin/env bash
set -euo pipefail

# Move one deterministically malformed merge candidate out of the scheduler
# queue.  The selector only calls this helper after all GitHub read responses
# have been parsed and the anomaly has been classified.  This helper owns the
# small, guarded issue-state write so a transient API/parser error never
# changes an issue.

usage() {
  cat >&2 <<'EOF'
usage: quarantine-merge-selector-anomaly.sh --issue NUMBER --reason REASON [--details TEXT] [--policy PATH]
EOF
}

error() {
  printf 'quarantine_merge_selector.FAIL=%s\n' "$1" >&2
  exit 1
}

issue_number=''
reason=''
details=''
policy=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)
      [ "$#" -ge 2 ] || { usage; error 'missing-issue'; }
      issue_number="$2"
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; error 'missing-reason'; }
      reason="$2"
      shift 2
      ;;
    --details)
      [ "$#" -ge 2 ] || { usage; error 'missing-details'; }
      details="$2"
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] || { usage; error 'missing-policy'; }
      policy="$2"
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

case "$issue_number" in
  ''|*[!0-9]*) error 'invalid-issue' ;;
esac
[ "$issue_number" -gt 0 ] 2>/dev/null || error 'invalid-issue'
case "$reason" in
  no-closing-pr|fork-pr|multiple-prs|multiple-closing-references|unsafe-base|unsafe-head|stale-base) ;;
  *) error 'invalid-reason' ;;
esac
case "$details" in
  *$'\n'*|*$'\r'*) error 'details-must-be-single-line' ;;
esac
[ "${#details}" -le 1000 ] || error 'details-too-long'
[ -n "${GITHUB_REPOSITORY:-}" ] || error 'missing-repository'
[ -n "${GH_TOKEN:-}" ] || error 'missing-gh-token'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -z "$policy" ]; then
  policy="${script_dir}/../.agents/workflows/backlog-policy.json"
fi
[ -r "$policy" ] || error 'policy-unreadable'

awaiting_merge_label="$(jq -er '.labels["awaiting-merge"] | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-awaiting-merge-label-invalid'
blocked_label="$(jq -er '.labels.blocked | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-blocked-label-invalid'
ready_label="$(jq -er '.labels.ready | strings | select(length > 0)' "$policy" 2>/dev/null)" ||
  error 'policy-ready-label-invalid'
lifecycle_json="$(jq -ce '
  .labels |
  select(type == "object") |
  [to_entries[].value] |
  select(length > 0 and
    all(.[]; type == "string" and length > 0) and
    (length == (unique | length)))
' "$policy" 2>/dev/null)" ||
  error 'policy-lifecycle-labels-invalid'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-merge-selector-quarantine.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

issue_state_json() {
  gh issue view "$issue_number" --repo "$GITHUB_REPOSITORY" --json number,state,labels,comments
}

validate_issue_json() {
  local value="$1"
  jq -e --argjson issue "$issue_number" '
    type == "object" and
    .number == $issue and
    (.state | type == "string") and
    (.labels | type == "array" and all(.[]; type == "object" and (.name | type == "string"))) and
    (.comments | type == "array" and all(.[]; type == "object" and (.body | type == "string")))
  ' <<<"$value" >/dev/null 2>&1 || error 'invalid-issue-response'
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

validate_exact_state() {
  local value="$1" expected="$2" labels lifecycle count
  labels="$(issue_labels "$value")"
  for lifecycle in $(jq -r '.[]' <<<"$lifecycle_json"); do
    count="$(label_count "$labels" "$lifecycle")"
    [ "$count" -le 1 ] || error 'duplicate-lifecycle-label'
  done
  [ "$(label_count "$labels" "$expected")" -eq 1 ] || error 'issue-state-mismatch'
  while IFS= read -r lifecycle; do
    [ -n "$lifecycle" ] || continue
    if [ "$lifecycle" != "$expected" ]; then
      [ "$(label_count "$labels" "$lifecycle")" -eq 0 ] || error 'conflicting-lifecycle-label'
    fi
  done <<<"$(jq -r '.[]' <<<"$lifecycle_json")"
}

friendly_reason() {
  case "$1" in
    no-closing-pr) printf '이슈를 닫는 열린 PR을 찾지 못했습니다.' ;;
    fork-pr) printf '다른 저장소에서 온 PR이 연결되어 있습니다.' ;;
    multiple-prs) printf '이슈를 닫는 열린 PR이 여러 개입니다.' ;;
    multiple-closing-references) printf '이슈를 닫는 PR 연결 정보가 여러 개입니다.' ;;
    unsafe-base) printf 'PR이 안전한 main 브랜치를 대상으로 하지 않습니다.' ;;
    unsafe-head) printf 'PR의 작업 브랜치 이름을 안전하게 확인하지 못했습니다.' ;;
    stale-base) printf 'PR이 현재 main 버전을 기준으로 하지 않습니다.' ;;
    *) printf '병합할 수 있는 PR 상태가 아닙니다.' ;;
  esac
}

comment_has_marker() {
  local comments_json="$1" marker="$2"
  jq -e --arg marker "$marker" '
    any(.comments[]; (.body | type == "string" and startswith($marker)))
  ' <<<"$comments_json" >/dev/null 2>&1
}

write_comment() {
  local marker="<!-- rpm-agent-merge-selector-block: issue=${issue_number};reason=${reason} -->"
  {
    printf '%s\n\n' "$marker"
    printf '자동 병합을 안전하게 멈췄습니다.\n\n'
    printf '이슈 상태: `%s`\n' "$blocked_label"
    printf '사유: `%s`\n' "$reason"
    printf '쉽게 말하면: %s\n' "$(friendly_reason "$reason")"
    if [ -n "$details" ]; then
      printf '상세: %s\n' "$details"
    fi
    printf '\n문제를 정리한 뒤 이슈를 `%s` 또는 `agent:research`로 다시 옮겨 주세요.\n' \
      "$ready_label"
  } >"$tmp_dir/comment.md"
}

post_comment_once() {
  local marker="$1" comments_json comments_after
  comments_json="$(jq -c '{comments:.comments}' <<<"$issue_before")"
  if comment_has_marker "$comments_json" "$marker"; then
    return 0
  fi
  gh issue comment "$issue_number" --repo "$GITHUB_REPOSITORY" --body-file "$tmp_dir/comment.md" >/dev/null 2>&1 ||
    error 'comment-write-failed'
  comments_after="$(gh issue view "$issue_number" --repo "$GITHUB_REPOSITORY" --json comments 2>/dev/null)" ||
    error 'comment-refetch-failed'
  jq -e 'type == "object" and (.comments | type == "array" and all(.[]; type == "object" and (.body | type == "string")))' \
    <<<"$comments_after" >/dev/null 2>&1 || error 'invalid-comment-response'
  comment_has_marker "$comments_after" "$marker" || error 'comment-not-verified'
}

issue_before="$(issue_state_json 2>/dev/null)" || error 'issue-read-failed'
validate_issue_json "$issue_before"
issue_state="$(jq -r '.state | ascii_upcase' <<<"$issue_before")"
labels="$(issue_labels "$issue_before")"
conflicting_lifecycle=0
while IFS= read -r lifecycle; do
  [ -n "$lifecycle" ] || continue
  if [ "$lifecycle" != "$awaiting_merge_label" ] && [ "$(label_count "$labels" "$lifecycle")" -ne 0 ]; then
    conflicting_lifecycle=1
    break
  fi
done <<<"$(jq -r '.[]' <<<"$lifecycle_json")"
if [ "$issue_state" != OPEN ] || [ "$(label_count "$labels" "$awaiting_merge_label")" -ne 1 ] || [ "$conflicting_lifecycle" -ne 0 ]; then
  printf 'quarantine_merge_selector: status=no-work; issue=%s; reason=issue-eligibility-changed\n' "$issue_number"
  exit 0
fi
validate_exact_state "$issue_before" "$awaiting_merge_label"
ordinary_before="$(ordinary_labels "$issue_before")"

gh issue edit "$issue_number" --repo "$GITHUB_REPOSITORY" \
  --remove-label "$awaiting_merge_label" --add-label "$blocked_label" >/dev/null 2>&1 ||
  error 'state-transition-failed'
issue_after="$(issue_state_json 2>/dev/null)" || error 'state-refetch-failed'
validate_issue_json "$issue_after"
validate_exact_state "$issue_after" "$blocked_label"
ordinary_after="$(ordinary_labels "$issue_after")"
[ "$ordinary_before" = "$ordinary_after" ] || error 'ordinary-labels-changed'

marker="<!-- rpm-agent-merge-selector-block: issue=${issue_number};reason=${reason} -->"
write_comment
post_comment_once "$marker"
printf 'quarantine_merge_selector: status=blocked; issue=%s; reason=%s\n' "$issue_number" "$reason"
