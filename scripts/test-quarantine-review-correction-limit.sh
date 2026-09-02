#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
helper="${repo_root}/scripts/quarantine-review-correction-limit.sh"
policy="${repo_root}/.agents/workflows/backlog-policy.json"

fail() {
  printf 'quarantine_review_correction_limit_test.FAIL=%s\n' "$1" >&2
  exit 1
}

[ -x "$helper" ] || fail 'helper-missing'
[ -r "$policy" ] || fail 'policy-missing'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-review-correction-limit-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fake_bin="${tmp_dir}/bin"
mkdir -p "$fake_bin"

cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_STATE:?}"
log="${FAKE_LOG:?}"
request="$*"
printf '%s\n' "$request" >>"$log"
mode="${FAKE_MODE:-normal}"
correction_label="${FAKE_CORRECTION_LABEL:-agent:correction-5}"

if [[ "$request" == *"/git/ref/heads/main"* ]]; then
  if [ "$mode" = stale-base ]; then
    printf '%s\n' 'cccccccccccccccccccccccccccccccccccccccc'
  else
    printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  fi
elif [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
  if [ "$mode" = invalid-issue ]; then
    printf '%s\n' '{}'
  elif [[ "$request" == *"--json comments"* && "$request" != *"number,state,labels,comments"* ]]; then
    jq -c '{comments:.comments}' "$state"
  elif [ "$mode" = stale-issue ]; then
    jq '(.labels = [{name:"agent:ready"},{name:"kind:bug"}])' "$state"
  else
    cat "$state"
  fi
elif [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  after=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f)
        case "${2:-}" in after=*) after="${2#after=}" ;; esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  if [[ "$request" == *"closingIssuesReferences(first:100"* ]]; then
    closing_mode="${FAKE_CLOSING_MODE:-single}"
    case "$closing_mode" in
      malformed)
        printf '%s\n' '{"data":{}}'
        exit 0
        ;;
      graphql-errors)
        printf '%s\n' '{"errors":[{"message":"synthetic GraphQL failure"}],"data":null}'
        exit 0
        ;;
      cursor-stalled)
        jq -nc --arg cursor "${after:-closing-cursor-1}" \
          '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:77,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:true,endCursor:$cursor},nodes:[]}}}}}'
        exit 0
        ;;
      duplicate-id)
        jq -nc '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:77,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"closing-12",number:12,repository:{nameWithOwner:"nerdchanii/rpm"}},{id:"closing-12",number:13,repository:{nameWithOwner:"other/rpm"}}]}}}}}'
        exit 0
        ;;
    esac
    nodes='[{"id":"closing-12","number":12,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
    has_next=false
    cursor=''
    if [ "$closing_mode" = same-repo-extra ]; then
      nodes='[{"id":"closing-12","number":12,"repository":{"nameWithOwner":"nerdchanii/rpm"}},{"id":"closing-13","number":13,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
    elif [ "$closing_mode" = cross-repo-extra ]; then
      if [ -z "$after" ]; then
        has_next=true
        cursor=closing-cursor-1
      else
        nodes='[{"id":"closing-13","number":13,"repository":{"nameWithOwner":"other/rpm"}}]'
      fi
    elif [ "$closing_mode" = page-limit ]; then
      has_next=true
      cursor="closing-cursor-${after:-0}-next"
    fi
    jq -nc --argjson nodes "$nodes" --arg cursor "$cursor" --argjson has_next "$has_next" \
      '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:77,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
    exit 0
  fi
  comment_mode="${FAKE_COMMENT_MODE:-${FAKE_MODE:-normal}}"
  if [ "$comment_mode" = malformed ]; then
    printf '%s\n' '{"data":{}}'
    exit 0
  fi
  if [ "$comment_mode" = graphql-errors ]; then
    printf '%s\n' '{"errors":[{"message":"synthetic GraphQL failure"}],"data":null}'
    exit 0
  fi
  if [ "$comment_mode" = cursor-stalled ]; then
    jq -nc --argjson nodes '[]' --arg cursor "${after:-cursor-1}" --argjson has_next true \
      '{data:{repository:{nameWithOwner:"nerdchanii/rpm",issue:{number:12,repository:{nameWithOwner:"nerdchanii/rpm"},comments:{pageInfo:{hasNextPage:$has_next,endCursor:$cursor},nodes:$nodes}}}}}'
    exit 0
  fi
  comments_json="$(jq -c '[.comments[]? | {id:(.id // null),body,author}]' "$state")"
  comments_json="$(jq -c 'to_entries | map(.value + {id:(.value.id // ("COMMENT_" + (.key | tostring)))})' <<<"$comments_json")"
  if [ "$comment_mode" = two-pages ]; then
    if [ -z "$after" ]; then
      nodes="$(jq -c '.[0:100]' <<<"$comments_json")"
      has_next=true
      cursor=comment-cursor-1
    else
      nodes="$(jq -c '.[100:]' <<<"$comments_json")"
      has_next=false
      cursor=''
    fi
  elif [ "$comment_mode" = duplicate-id ]; then
    nodes="$(jq -c '.[0:1] + .[0:1]' <<<"$comments_json")"
    has_next=false
    cursor=''
  elif [ "$comment_mode" = page-limit ]; then
    nodes='[]'
    has_next=true
    cursor="cursor-${after:-0}"
  else
    nodes="$comments_json"
    has_next=false
    cursor=''
  fi
  jq -nc --argjson nodes "$nodes" --arg cursor "$cursor" --argjson has_next "$has_next" \
    '{data:{repository:{nameWithOwner:"nerdchanii/rpm",issue:{number:12,repository:{nameWithOwner:"nerdchanii/rpm"},comments:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
elif [[ "$request" == *"/pulls/77"* ]]; then
  if [ "$mode" = invalid-pr ]; then
    printf '%s\n' '{}'
  elif [ "$mode" = stale-pr ]; then
    jq -nc '{number:77,state:"open",base:{ref:"main",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{full_name:"nerdchanii/rpm"}},head:{ref:"feat/test",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{full_name:"nerdchanii/rpm"}},labels:[{name:"agent:correction-5"}]}'
  else
    jq -nc --arg corrections "$correction_label" '{number:77,state:"open",base:{ref:"main",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{full_name:"nerdchanii/rpm"}},head:{ref:"feat/test",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",repo:{full_name:"nerdchanii/rpm"}},labels:($corrections | split(",") | map({name:.}))}'
  fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [ "$mode" = invalid-link ]; then
    printf '%s\n' '{}'
  elif [ "$mode" = multiple-closing ]; then
    printf '%s\n' '{"closingIssuesReferences":[{"number":12,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}},{"number":13,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}'
  else
    printf '%s\n' '{"closingIssuesReferences":[{"number":12,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}'
  fi
elif [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
  if [ "$mode" = edit-race ]; then
    jq '(.labels = [{name:"agent:ready"},{name:"kind:bug"}])' "$state" >"${state}.next"
  elif [ "$mode" = drop-ordinary ]; then
    jq '(.labels = [.labels[] | select(.name != "agent:review-pending" and .name != "kind:bug")] + [{name:"agent:blocked"}])' "$state" >"${state}.next"
  else
    jq '(.labels = [.labels[] | select(.name != "agent:review-pending")] + [{name:"agent:blocked"}])' "$state" >"${state}.next"
  fi
  mv "${state}.next" "$state"
elif [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
  body_file=''
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --body-file ]; then
      body_file="$2"
      shift 2
    else
      shift
    fi
  done
  [ -n "$body_file" ] || exit 2
  jq --arg body "$(<"$body_file")" '(.comments += [{body:$body}])' "$state" >"${state}.next"
  mv "${state}.next" "$state"
else
  printf 'unexpected fake gh call: %s\n' "$request" >&2
  exit 90
fi
EOF
chmod +x "${fake_bin}/gh"

cat >"${fake_bin}/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-called\n' >>"${FAKE_LOG:?}"
exit 91
EOF
chmod +x "${fake_bin}/codex"

run_helper() {
  local name="$1" initial="$2" expected_rc="$3" mode="${4:-normal}" reason="${5:-correction-limit}" correction_label="${6:-agent:correction-5}" closing_mode="${7:-single}"
  local case_dir state log output actual_rc
  case_dir="${tmp_dir}/${name}"
  state="${case_dir}/state.json"
  log="${case_dir}/gh.log"
  mkdir -p "$case_dir"
  printf '%s\n' "$initial" >"$state"
  : >"$log"
  set +e
  output="$(
    PATH="${fake_bin}:${PATH}" \
      FAKE_STATE="$state" \
      FAKE_LOG="$log" \
      FAKE_MODE="$mode" \
      FAKE_CORRECTION_LABEL="$correction_label" \
      FAKE_CLOSING_MODE="$closing_mode" \
      GITHUB_REPOSITORY=nerdchanii/rpm \
      GH_TOKEN=test-token \
      bash "$helper" \
        --policy "$policy" \
        --issue 12 \
        --pr 77 \
        --base-ref main \
        --base-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --head-ref feat/test \
        --head-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        --reason "$reason"
  )"
  actual_rc=$?
  set -e
  [ "$actual_rc" -eq "$expected_rc" ] || {
    printf '%s\n' "$output" >&2
    fail "${name}-exit-${actual_rc}"
  }
  printf '%s\n' "$output"
}

history_comments_for() {
  local max_counter="$1"
  jq -nc --arg head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --argjson max_counter "$max_counter" \
    '[range(0; ($max_counter + 1)) | {body:("<!-- rpm-agent-correction-history: pr=77; counter=agent:correction-" + tostring + "; head=" + $head + " -->"),author:{login:"github-actions[bot]"}}]'
}
review_pending_for() {
  local comments="$1"
  jq -nc --argjson comments "$comments" '{number:12,state:"OPEN",labels:[{name:"agent:review-pending"},{name:"kind:bug"}],comments:$comments}'
}
history_comments="$(history_comments_for 5)"
review_pending="$(review_pending_for "$history_comments")"

assert_blocked_reason() {
  local name="$1" reason="$2"
  local state="${tmp_dir}/${name}/state.json"
  jq -e --arg reason "$reason" '
    .state == "OPEN" and
    ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"] and
    ([.comments[] | select(.body | startswith("<!-- rpm-agent-correction-limit-block: issue=12;pr=77 -->"))] | length) == 1 and
    any(.comments[]; (.body | contains($reason)))
  ' "$state" >/dev/null || fail "${name}-blocked-state"
  ! rg -q 'codex-called' "${tmp_dir}/${name}/gh.log" || fail "${name}-started-cloud"
}

assert_multiple_closing_blocked() {
  local name="$1"
  local state="${tmp_dir}/${name}/state.json"
  jq -e '
    .state == "OPEN" and
    ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"] and
    ([.comments[] | select(.body | startswith("<!-- rpm-agent-correction-limit-block: issue=12;pr=77 -->"))] | length) == 1 and
    any(.comments[]; (.body | contains("multiple-closing-references")))
  ' "$state" >/dev/null || fail "${name}-multiple-closing-blocked-state"
  ! rg -q 'codex-called' "${tmp_dir}/${name}/gh.log" || fail "${name}-started-cloud"
}

run_helper transition "$review_pending" 0
transition_state="${tmp_dir}/transition/state.json"
jq -e '
  .state == "OPEN" and
  ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"] and
  (.comments | length) == 7 and
  ([.comments[] | select(.body | startswith("<!-- rpm-agent-correction-limit-block: issue=12;pr=77 -->"))] | length) == 1
' "$transition_state" >/dev/null || fail 'transition-state'
! rg -q 'codex-called' "${tmp_dir}/transition/gh.log" || fail 'transition-started-cloud'

# A PR that closes the selected issue together with another issue is a
# terminal review-selection anomaly. It must move the review issue to blocked
# without requiring correction-history comments.
multiple_closing_review_pending="$(review_pending_for '[]')"
run_helper multiple-closing "$multiple_closing_review_pending" 0 normal multiple-closing-references agent:correction-0 same-repo-extra
assert_multiple_closing_blocked multiple-closing
run_helper multiple-closing-cross-repo "$multiple_closing_review_pending" 0 normal multiple-closing-references agent:correction-0 cross-repo-extra
assert_multiple_closing_blocked multiple-closing-cross-repo

# The terminal writer is idempotent after the first transition and comment.
multiple_closing_state="${tmp_dir}/multiple-closing/state.json"
PATH="${fake_bin}:${PATH}" \
  FAKE_STATE="$multiple_closing_state" \
  FAKE_LOG="${tmp_dir}/multiple-closing/second-gh.log" \
  FAKE_MODE=normal \
  FAKE_CLOSING_MODE=same-repo-extra \
  GITHUB_REPOSITORY=nerdchanii/rpm \
  GH_TOKEN=test-token \
  bash "$helper" \
    --policy "$policy" \
    --issue 12 --pr 77 --base-ref main \
    --base-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --head-ref feat/test --head-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --reason multiple-closing-references >/dev/null || fail 'multiple-closing-idempotent-repeat'
multiple_closing_state_json="$(<"$multiple_closing_state")"
jq -e '([.comments[] | select(.body | startswith("<!-- rpm-agent-correction-limit-block: issue=12;pr=77 -->"))] | length) == 1' \
  <<<"$multiple_closing_state_json" >/dev/null || fail 'multiple-closing-idempotent-comment-count'
second_edit_count="$(rg -c -- 'issue edit 12' "${tmp_dir}/multiple-closing/second-gh.log" || true)"
second_comment_count="$(rg -c -- 'issue comment 12' "${tmp_dir}/multiple-closing/second-gh.log" || true)"
[ "${second_edit_count:-0}" -eq 0 ] || fail 'multiple-closing-idempotent-edit-count'
[ "${second_comment_count:-0}" -eq 0 ] || fail 'multiple-closing-idempotent-comment-write-count'

# If the live PR no longer has two closing references, the immutable terminal
# snapshot is stale. The helper must report no-work before any issue write.
run_helper multiple-closing-state-changed "$multiple_closing_review_pending" 0 normal multiple-closing-references agent:correction-0 single
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/multiple-closing-state-changed/gh.log" ||
  fail 'multiple-closing-state-changed-mutated'
run_helper multiple-closing-base-changed "$multiple_closing_review_pending" 0 stale-base multiple-closing-references agent:correction-0 same-repo-extra
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/multiple-closing-base-changed/gh.log" ||
  fail 'multiple-closing-base-changed-mutated'

# A malformed GraphQL page or a cursor that stops advancing must fail closed
# before the issue transition. This covers the bounded inventory reader rather
# than the old one-page REST shape.
for closing_mode in malformed cursor-stalled; do
  run_helper "multiple-closing-${closing_mode}" "$multiple_closing_review_pending" 1 normal multiple-closing-references agent:correction-0 "$closing_mode"
  ! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/multiple-closing-${closing_mode}/gh.log" ||
    fail "multiple-closing-${closing_mode}-mutated"
done

run_helper idempotent "$review_pending" 0
idempotent_state="${tmp_dir}/idempotent/state.json"
PATH="${fake_bin}:${PATH}" \
  FAKE_STATE="$idempotent_state" \
  FAKE_LOG="${tmp_dir}/idempotent/gh.log" \
  FAKE_MODE=normal \
  GITHUB_REPOSITORY=nerdchanii/rpm \
  GH_TOKEN=test-token \
  bash "$helper" \
    --policy "$policy" \
    --issue 12 --pr 77 --base-ref main \
    --base-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --head-ref feat/test --head-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null || fail 'idempotent-repeat'
idempotent_state_json="$(<"$idempotent_state")"
jq -e '([.comments[] | select(.body | startswith("<!-- rpm-agent-correction-limit-block: issue=12;pr=77 -->"))] | length) == 1' \
  <<<"$idempotent_state_json" >/dev/null || fail 'idempotent-comment-count'
[ "$(rg -c -- 'issue edit 12' "${tmp_dir}/idempotent/gh.log")" -eq 1 ] || fail 'idempotent-edit-count'
[ "$(rg -c -- 'issue comment 12' "${tmp_dir}/idempotent/gh.log")" -eq 1 ] || fail 'idempotent-comment-write-count'

# A visible counter with a missing durable record is a terminal partial
# transaction. The writer blocks it without repairing the record.
forged_label='{"number":12,"state":"OPEN","labels":[{"name":"agent:review-pending"},{"name":"kind:bug"}],"comments":[]}'
run_helper forged-label "$forged_label" 0 normal correction-history-sequence-missing agent:correction-5
assert_blocked_reason forged-label correction-history-sequence-missing

partial_comments="$(history_comments_for 0)"
partial_transaction="$(review_pending_for "$partial_comments")"
run_helper partial-transaction "$partial_transaction" 0 normal correction-history-sequence-missing agent:correction-1
assert_blocked_reason partial-transaction correction-history-sequence-missing

# If the publisher finishes the marker write before the trusted writer runs,
# the same snapshot becomes valid and the writer must leave it untouched.
valid_zero="$(review_pending_for "$(history_comments_for 0)")"
run_helper stale-recovery-valid "$valid_zero" 0 normal correction-history-sequence-missing agent:correction-0
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/stale-recovery-valid/gh.log" || fail 'stale-recovery-valid-mutated'

multiple_labels="$review_pending"
run_helper multiple-correction-labels "$multiple_labels" 0 normal correction-label-invalid agent:correction-5,agent:correction-1
assert_blocked_reason multiple-correction-labels correction-label-invalid

lowered_label_history="$review_pending"
run_helper lowered-label-history "$lowered_label_history" 0 normal correction-history-label-lowered agent:correction-3
assert_blocked_reason lowered-label-history correction-history-label-lowered

duplicate_history="$(jq '.comments += [.comments[5]]' <<<"$review_pending")"
run_helper duplicate-history "$duplicate_history" 0 normal correction-history-duplicate agent:correction-5
assert_blocked_reason duplicate-history correction-history-duplicate

untrusted_history="$(jq '.comments[5].author.login = "human-user"' <<<"$review_pending")"
run_helper untrusted-history "$untrusted_history" 0 normal correction-history-sequence-missing agent:correction-5
assert_blocked_reason untrusted-history correction-history-sequence-missing

# Marker-like comments from an untrusted or deleted author are ordinary
# comments. They do not advance or invalidate an otherwise complete history.
untrusted_extra_comments="$(jq '. + [{id:"untrusted-exact",body:"<!-- rpm-agent-correction-history: pr=77; counter=agent:correction-5; head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->",author:{login:"human-user"}},{id:"anonymous-malformed",body:"<!-- rpm-agent-correction-history: malformed",author:null}]' <<<"$(history_comments_for 4)")"
untrusted_extra_state="$(review_pending_for "$untrusted_extra_comments")"
run_helper untrusted-extra-ignored "$untrusted_extra_state" 0 normal correction-limit agent:correction-4
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/untrusted-extra-ignored/gh.log" || fail 'untrusted-extra-mutated'

# The history marker may be beyond the first GitHub page. The helper must use
# the second page before deciding that correction-5 is terminal.
filler_comments="$(jq -nc '[range(0;100) | {id:("filler-" + tostring),body:"ordinary comment",author:null}]')"
paged_comments="$(jq -nc --argjson filler "$filler_comments" --argjson history "$(history_comments_for 5)" '$filler + $history')"
paged_state="$(review_pending_for "$paged_comments")"
run_helper pagination-second-page "$paged_state" 0 two-pages correction-limit agent:correction-5
assert_blocked_reason pagination-second-page correction-limit

# Malformed GraphQL responses, cursor failures, duplicate IDs, and the page
# limit all fail before the helper can change labels or post a comment.
for pagination_mode in malformed graphql-errors cursor-stalled duplicate-id page-limit; do
  run_helper "pagination-${pagination_mode}" "$review_pending" 1 "$pagination_mode"
  ! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/pagination-${pagination_mode}/gh.log" ||
    fail "pagination-${pagination_mode}-mutated"
done

head_mismatch_history="$(jq '.comments[5].body = "<!-- rpm-agent-correction-history: pr=77; counter=agent:correction-5; head=cccccccccccccccccccccccccccccccccccccccc -->"' <<<"$review_pending")"
run_helper head-mismatch-history "$head_mismatch_history" 0 normal correction-history-head-mismatch agent:correction-5
assert_blocked_reason head-mismatch-history correction-history-head-mismatch

missing_history="$(jq 'del(.comments[3])' <<<"$review_pending")"
run_helper missing-history "$missing_history" 0 normal correction-history-sequence-missing agent:correction-5
assert_blocked_reason missing-history correction-history-sequence-missing

malformed_history="$(jq '.comments[5].body += "\nextra"' <<<"$review_pending")"
run_helper malformed-history "$malformed_history" 0 normal correction-history-malformed agent:correction-5
assert_blocked_reason malformed-history correction-history-malformed

run_helper stale-issue "$review_pending" 0 stale-issue
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/stale-issue/gh.log" || fail 'stale-issue-mutated'

run_helper stale-pr "$review_pending" 0 stale-pr
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/stale-pr/gh.log" || fail 'stale-pr-mutated'

run_helper invalid-issue "$review_pending" 1 invalid-issue
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/invalid-issue/gh.log" || fail 'invalid-issue-mutated'

run_helper invalid-pr "$review_pending" 1 invalid-pr
! rg -q 'issue edit 12|issue comment 12' "${tmp_dir}/invalid-pr/gh.log" || fail 'invalid-pr-mutated'

run_helper edit-race "$review_pending" 1 edit-race
! rg -q 'issue comment 12' "${tmp_dir}/edit-race/gh.log" || fail 'edit-race-commented'

printf 'quarantine_review_correction_limit_test.PASS=history-terminal-transition-idempotence-stale-malformed-no-cloud\n'
