#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
publisher="${repo_root}/scripts/publish-cloud-merge.sh"
policy="${repo_root}/.agents/workflows/backlog-policy.json"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-publish-cloud-merge.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

repo='nerdchanii/rpm'
issue=12
pr=44
base_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
head_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
pr_node_id='PR_kwDOtest44'

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cat >"$tmp_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${GH_LOG:?}"
state_dir="${GH_STATE:?}"
merge_pr_node_id='PR_kwDOtest44'
merge_head_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf '%s\n' "$*" >>"$log_file"
count() { grep -F -c "$1" "$log_file" 2>/dev/null || true; }
json() { printf '%s\n' "$1"; }

mark_merged() {
  printf '%s\n' 1 >"${state_dir}/merge-count"
  : >"${state_dir}/merged"
  if [ -f "${state_dir}/issue.json" ]; then
    jq '.state = "CLOSED"' "${state_dir}/issue.json" >"${state_dir}/issue.next"
    mv -- "${state_dir}/issue.next" "${state_dir}/issue.json"
  fi
}

if [ "${1:-}" = api ]; then
  endpoint=""
  query=""
  input_json=""
  input_path=""
  threads_after=""
  closing_after=""
  previous_arg=""
  for arg in "$@"; do
    if [ "$previous_arg" = --input ]; then
      input_path="$arg"
      previous_arg=""
      continue
    fi
    case "$arg" in
      repos/*) endpoint="$arg" ;;
      query=*) query="${arg#query=}" ;;
      input=*) input_json="${arg#input=}" ;;
      --input) previous_arg=--input ;;
      threadsAfter=*) threads_after="${arg#threadsAfter=}" ;;
      after=*) closing_after="${arg#after=}" ;;
    esac
  done
  if [ -n "$input_path" ]; then
    [ -f "$input_path" ] || { printf 'missing GraphQL input file\n' >&2; exit 92; }
    query="$(jq -er '.query | strings' "$input_path")"
    input_json="$(jq -ce '.variables.input' "$input_path")"
  fi
  if [[ "$query" == *"mergePullRequest"* ]]; then
    { printf '%s input=%s\n' "$*" "$input_json"; } >>"${GH_GRAPHQL_MERGE_LOG:?}"
    [ -n "$input_json" ] || { printf 'missing GraphQL merge input\n' >&2; exit 92; }
    if [ "${GH_MODE:-}" = merge-response-malformed ]; then
      mark_merged
      json "{\"data\":{\"mergePullRequest\":{\"pullRequest\":{\"id\":\"${merge_pr_node_id}\",\"number\":44,\"state\":\"MERGED\",\"headRefOid\":\"${merge_head_sha}\",\"baseRefName\":\"main\",\"baseRefOid\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}}}}"
    elif [ "${GH_MODE:-}" = merge-response-errors ]; then
      json '{"errors":[{"message":"merge response failed"}]}'
    else
      mark_merged
      json "{\"data\":{\"mergePullRequest\":{\"pullRequest\":{\"id\":\"${merge_pr_node_id}\",\"number\":44,\"state\":\"MERGED\",\"headRefOid\":\"${merge_head_sha}\",\"baseRefName\":\"main\",\"baseRefOid\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"mergeCommit\":{\"oid\":\"cccccccccccccccccccccccccccccccccccccccc\"}}}}}"
    fi
    exit 0
  fi
  if [[ "$query" == *"baseRefOid"* ]]; then
    if [ "${GH_MODE:-}" = preflight-malformed ]; then
      json '{"data":{"repository":{"pullRequest":{"id":"PR_kwDOtest44","number":44,"state":"OPEN","headRefName":"agent/issue-12","baseRefName":"main","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}'
    else
      json '{"data":{"repository":{"pullRequest":{"id":"PR_kwDOtest44","number":44,"state":"OPEN","headRefName":"agent/issue-12","baseRefName":"main","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}'
    fi
    exit 0
  fi
  case "$endpoint" in
    repos/nerdchanii/rpm/issues\?*)
      if [ "${GH_MODE:-}" = lower-candidate ] && [ "$(count 'repos/nerdchanii/rpm/issues?')" -gt 1 ]; then
        json '[[{"number":11,"title":"lower","html_url":"https://github.com/nerdchanii/rpm/issues/11","state":"open","labels":[{"name":"agent:awaiting-merge"}]},{"number":12,"title":"target","html_url":"https://github.com/nerdchanii/rpm/issues/12","state":"open","labels":[{"name":"agent:awaiting-merge"}]}]]'
      else
        json '[[{"number":12,"title":"target","html_url":"https://github.com/nerdchanii/rpm/issues/12","state":"open","labels":[{"name":"agent:awaiting-merge"}]}]]'
      fi
      ;;
    repos/nerdchanii/rpm/issues/12/timeline\?*)
      if [ "${GH_MODE:-}" = multiple-pr ]; then
        json '[[{"event":"labeled","label":{"name":"agent:awaiting-merge"},"actor":{"login":"github-actions[bot]"}},{"event":"cross-referenced","source":{"issue":{"number":44,"title":"PR 44","html_url":"https://github.com/nerdchanii/rpm/pull/44","pull_request":{"url":"x"}}}},{"event":"cross-referenced","source":{"issue":{"number":45,"title":"PR 45","html_url":"https://github.com/nerdchanii/rpm/pull/45","pull_request":{"url":"x"}}}}]]'
      else
        json '[[{"event":"labeled","label":{"name":"agent:awaiting-merge"},"actor":{"login":"github-actions[bot]"}},{"event":"cross-referenced","source":{"issue":{"number":44,"title":"PR 44","html_url":"https://github.com/nerdchanii/rpm/pull/44","pull_request":{"url":"x"}}}}]]'
      fi
      ;;
    repos/nerdchanii/rpm/pulls/44|repos/nerdchanii/rpm/pulls/45)
      pr_number="${endpoint##*/}"
      head_repo='nerdchanii/rpm'
      head_ref='agent/issue-12'
      head_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      auto_merge='null'
      if [ "${GH_MODE:-}" = fork ]; then head_repo='someone/rpm'; fi
      if [ "${GH_MODE:-}" = protected-head ]; then head_ref='main'; fi
      if [ "${GH_MODE:-}" = auto-merge ]; then auto_merge='{"enabled_by":{"login":"someone"}}'; fi
      if [ "${GH_MODE:-}" = head-drift ] && [ "$(count 'pulls/44')" -gt 1 ]; then head_sha='dddddddddddddddddddddddddddddddddddddddd'; fi
      json "{\"number\":${pr_number},\"title\":\"PR\",\"html_url\":\"https://github.com/nerdchanii/rpm/pull/${pr_number}\",\"state\":\"open\",\"draft\":false,\"auto_merge\":${auto_merge},\"mergeable\":true,\"mergeable_state\":\"clean\",\"base\":{\"ref\":\"main\",\"sha\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"repo\":{\"full_name\":\"nerdchanii/rpm\"}},\"head\":{\"ref\":\"${head_ref}\",\"sha\":\"${head_sha}\",\"repo\":{\"full_name\":\"${head_repo}\"}}}"
      ;;
    repos/nerdchanii/rpm/git/ref/heads/main)
      json '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
      ;;
    repos/nerdchanii/rpm/branches/main/protection)
      if [ "${GH_MODE:-}" = protection-drift ] && [ "$(count 'branches/main/protection')" -gt 1 ]; then
        json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":false,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
      else
        json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
      fi
      ;;
    *)
      if [[ "$query" == *closingIssuesReferences* ]]; then
        if [ -z "$closing_after" ]; then
          json '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"pageInfo":{"hasNextPage":true,"endCursor":"closing-1"},"nodes":[{"number":12}]}}}}}'
        else
          json '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":13}]}}}}}'
        fi
      elif [[ "$query" == *reviewThreads* ]]; then
        thread_json='[]'
        if [ "${GH_MODE:-}" = thread-drift ] && [ "$(count 'reviewThreads')" -gt 1 ]; then
          thread_json='[{"id":"thread-new","isResolved":false,"isOutdated":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"comment-new","body":"**P1:** blocker","createdAt":"2026-09-02T00:00:00Z","url":"https://github.com/nerdchanii/rpm/pull/44#discussion_r1","author":{"login":"reviewer"}}]}}]'
        fi
        queue='null'
        repository_queue='null'
        if [ "${GH_MODE:-}" = merge-queue ]; then repository_queue='{"id":"MQ_test"}'; fi
        json "{\"data\":{\"repository\":{\"mergeQueue\":${repository_queue},\"pullRequest\":{\"number\":44,\"headRefOid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":${thread_json}},\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"mergeQueueEntry\":${queue}}}}}"
      else
        json '{"errors":[{"message":"unexpected fake GraphQL request"}]}'
        exit 1
      fi
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
  if [ "${GH_MODE:-}" = check-drift ] && [ "$(count 'pr checks')" -gt 1 ]; then
    json '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"fail"}]'
  else
    json '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
  fi
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf '%s\n' "$*" >>"${GH_MERGE_LOG:?}"
  mark_merged
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [ "${GH_MODE:-}" = post-state-fail ]; then
    json '{"number":44,"state":"OPEN","mergedAt":null,"mergeCommit":null,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main"}'
  elif [ -f "${state_dir}/merged" ]; then
    json '{"number":44,"state":"MERGED","mergedAt":"2026-09-02T00:00:00Z","mergeCommit":{"oid":"cccccccccccccccccccccccccccccccccccccccc"},"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main"}'
  else
    json '{"number":44,"state":"OPEN","mergedAt":null,"mergeCommit":null,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main"}'
  fi
  exit 0
fi

if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
  if [ "${GH_MODE:-}" = post-state-fail ]; then
    json '{"number":12,"state":"OPEN"}'
  elif [[ "$*" == *"labels"* ]] || [[ "$*" == *"comments"* ]]; then
    cat "${state_dir}/issue.json"
  elif [ -f "${state_dir}/issue.json" ]; then
    jq '{number,state}' "${state_dir}/issue.json"
  else
    json '{"number":12,"state":"CLOSED"}'
  fi
  exit 0
fi

if [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
  n=""; remove=""; add=""; shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --remove-label) remove="$2"; shift 2 ;;
      --add-label) add="$2"; shift 2 ;;
      [0-9]*) n="$1"; shift ;;
      *) shift ;;
    esac
  done
  [ "$n" = 12 ] || exit 91
  jq --arg remove "$remove" --arg add "$add" \
    '.labels = ((.labels // []) | map(select(. != $remove)) + [$add] | map(select(length > 0)) | unique)' \
    "${state_dir}/issue.json" >"${state_dir}/issue.next"
  mv -- "${state_dir}/issue.next" "${state_dir}/issue.json"
  exit 0
fi

if [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then
  n=""; body_file=""; shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      [0-9]*) n="$1"; shift ;;
      *) shift ;;
    esac
  done
  [ "$n" = 12 ] || exit 91
  body="$(<"$body_file")"
  jq --arg body "$body" '.comments = ((.comments // []) + [{body:$body}])' \
    "${state_dir}/issue.json" >"${state_dir}/issue.next"
  mv -- "${state_dir}/issue.next" "${state_dir}/issue.json"
  exit 0
fi

printf 'unexpected fake gh call: %s\n' "$*" >&2
exit 99
FAKE_GH
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export GITHUB_REPOSITORY="$repo"
export GH_TOKEN='test-token'

make_result() {
  local mode="$1" path="$2" issue_value="$issue" pr_value="$pr"
  if [ "$mode" = wrong-result-ids ]; then issue_value=999; pr_value=998; fi
  if [ "$mode" = duplicate-result-key ]; then
    printf '{"version":1,"lane":"merge","status":"merge","issue":%s,"pr":%s,"base_sha":"%s","head_sha":"%s","summary":"ready","summary":"duplicate","validation":["just validate"],"actionable_findings_remaining":false,"next_state":"awaiting-merge","correction_label":null,"resolved_thread_ids":[],"followups":[]}\n' \
      "$issue_value" "$pr_value" "$base_sha" "$head_sha" >"$path"
    return 0
  fi
  local status='merge' next_state='awaiting-merge' summary='ready'
  if [ "$mode" = cloud-blocked ]; then
    status='blocked'; next_state='blocked'; summary='required checks failed'
  elif [ "$mode" = cloud-no-work ]; then
    status='no-work'; next_state='unchanged'; summary='required checks are still running'
  fi
  jq -n --argjson issue "$issue_value" --argjson pr "$pr_value" \
    --arg base "$base_sha" --arg head "$head_sha" --arg status "$status" \
    --arg next_state "$next_state" --arg summary "$summary" \
    '{version:1,lane:"merge",status:$status,issue:$issue,pr:$pr,base_sha:$base,head_sha:$head,summary:$summary,validation:["just validate"],actionable_findings_remaining:false,next_state:$next_state,correction_label:null,resolved_thread_ids:[],followups:[]}' >"$path"
  if [ "$mode" = extra-result-key ]; then
    jq '. + {unexpected:"extra"}' "$path" >"${path}.next"
    mv -- "${path}.next" "$path"
  elif [ "$mode" = wrong-next-state ]; then
    jq '.next_state = "blocked"' "$path" >"${path}.next"
    mv -- "${path}.next" "$path"
  fi
}

run_case() {
  local mode="$1" expected_rc="$2" expected_merges="$3" description="$4"
  local case_dir="$tmp_dir/$mode"
  mkdir -p "$case_dir"
  : >"$case_dir/gh.log"
  : >"$case_dir/merge.log"
  : >"$case_dir/graphql-merge.log"
  rm -f "$case_dir/merge-count" "$case_dir/merged"
  jq -n --argjson issue "$issue" \
    '{number:$issue,state:"OPEN",labels:["agent:awaiting-merge","kind:feature"],comments:[]}' >"$case_dir/issue.json"
  export GH_LOG="$case_dir/gh.log" GH_MERGE_LOG="$case_dir/merge.log" GH_GRAPHQL_MERGE_LOG="$case_dir/graphql-merge.log" GH_STATE="$case_dir" GH_MODE="$mode"
  result="$case_dir/result.json"
  make_result "$mode" "$result"
  set +e
  "$publisher" --repo "$repo" --policy "$policy" --result "$result" \
    --expected-issue "$issue" --expected-pr "$pr" \
    --expected-base-ref main --expected-head-ref agent/issue-12 \
    --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" \
    >"$case_dir/out" 2>"$case_dir/err"
  actual_rc=$?
  set -e
  [ "$actual_rc" -eq "$expected_rc" ] || { cat "$case_dir/err" >&2; fail "$description (exit $actual_rc, expected $expected_rc)"; }
  merge_count=0
  [ -f "$case_dir/merge-count" ] && merge_count="$(<"$case_dir/merge-count")"
  [ "$merge_count" -eq "$expected_merges" ] || fail "$description (merge count $merge_count, expected $expected_merges)"
  graphql_merge_count="$(wc -l <"$case_dir/graphql-merge.log" | tr -d '[:space:]')"
  expected_graphql_merges="$expected_merges"
  case "$mode" in
    merge-response-malformed|merge-response-errors) expected_graphql_merges=1 ;;
  esac
  [ "$graphql_merge_count" -eq "$expected_graphql_merges" ] || fail "$description (GraphQL merge mutation count $graphql_merge_count, expected $expected_graphql_merges)"
  pass "$description"
}

assert_blocked_case() {
  local mode="$1" case_dir
  case_dir="$tmp_dir/$mode"
  jq -e '
    .state == "OPEN" and
    .labels == ["agent:blocked", "kind:feature"] and
    ([.comments[] | select((.body // "") | startswith("<!-- rpm-agent-merge-block:"))] | length) == 1
  ' "$case_dir/issue.json" >/dev/null || fail "$mode did not record one blocked state and comment"
  pass "$mode records blocked state and a deduplicated reason comment"
}

run_no_work_retry_limit_case() {
  local mode=cloud-no-work case_dir result actual_rc attempt
  case_dir="$tmp_dir/$mode"
  mkdir -p "$case_dir"
  : >"$case_dir/gh.log"
  : >"$case_dir/merge.log"
  jq -n --argjson issue "$issue" \
    '{number:$issue,state:"OPEN",labels:["agent:awaiting-merge","kind:feature"],comments:[]}' >"$case_dir/issue.json"
  export GH_LOG="$case_dir/gh.log" GH_MERGE_LOG="$case_dir/merge.log" GH_STATE="$case_dir" GH_MODE="$mode"
  result="$case_dir/result.json"
  for ((attempt = 1; attempt <= 5; attempt++)); do
    make_result "$mode" "$result"
    set +e
    "$publisher" --repo "$repo" --policy "$policy" --result "$result" \
      --expected-issue "$issue" --expected-pr "$pr" \
      --expected-base-ref main --expected-head-ref agent/issue-12 \
      --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" \
      >"$case_dir/out" 2>"$case_dir/err"
    actual_rc=$?
    set -e
    [ "$actual_rc" -eq 0 ] || { cat "$case_dir/err" >&2; fail "no-work retry $attempt failed"; }
  done
  jq -e '
    .state == "OPEN" and .labels == ["agent:blocked", "kind:feature"] and
    ([.comments[] | select((.body // "") | startswith("<!-- rpm-agent-merge-block:"))] | length) == 1 and
    ([.comments[] | select((.body // "") | startswith("<!-- rpm-agent-merge-retry:"))] | length) == 4
  ' "$case_dir/issue.json" >/dev/null || fail 'no-work retry limit did not block after five attempts'
  # Replaying the same terminal handoff must not add another reason comment.
  set +e
  "$publisher" --repo "$repo" --policy "$policy" --result "$result" \
    --expected-issue "$issue" --expected-pr "$pr" \
    --expected-base-ref main --expected-head-ref agent/issue-12 \
    --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" \
    >"$case_dir/replay.out" 2>"$case_dir/replay.err"
  actual_rc=$?
  set -e
  [ "$actual_rc" -eq 0 ] || { cat "$case_dir/replay.err" >&2; fail 'no-work terminal replay failed'; }
  [ "$(jq '[.comments[]] | length' "$case_dir/issue.json")" -eq 5 ] || fail 'no-work replay duplicated comments'
  pass 'no-work is bounded to five attempts and the terminal comment is deduplicated'
}

run_case happy 0 1 'happy merge calls one GraphQL mutation and verifies post-state'
if rg -n -- '--(admin|auto|delete-branch)' "$publisher" >/dev/null 2>&1; then
  fail 'publisher contains a forbidden merge override or branch-delete option'
fi
if [ "$(wc -l <"$tmp_dir/happy/graphql-merge.log" | tr -d '[:space:]')" -ne 1 ]; then
  fail 'happy merge did not call one GraphQL merge mutation'
fi
if ! grep -Fq -- "input={\"pullRequestId\":\"${pr_node_id}\",\"expectedHeadOid\":\"${head_sha}\",\"mergeMethod\":\"SQUASH\"}" "$tmp_dir/happy/graphql-merge.log"; then
  fail 'happy merge did not send the exact node ID, head SHA, and SQUASH input'
fi
pass 'publisher merge mutation has no admin, auto, or branch-delete override'
run_case wrong-result-ids 1 0 'a Cloud result for another issue or PR is rejected'
run_case extra-result-key 1 0 'an extra Cloud result key is rejected'
run_case duplicate-result-key 1 0 'a duplicate Cloud result key is rejected'
run_case wrong-next-state 1 0 'a Cloud result with the wrong next state is rejected'
run_case lower-candidate 1 0 'a lower candidate appearing before merge is rejected'
run_case head-drift 1 0 'head drift is rejected before merge'
run_case thread-drift 0 0 'new review thread changes the second gate to blocked'
run_case check-drift 0 0 'check drift changes the second gate to blocked'
run_case protection-drift 0 0 'protection drift changes the second gate to blocked'
run_case fork 0 0 'fork head is blocked'
run_case protected-head 0 0 'protected head branch is blocked'
run_case multiple-pr 0 0 'multiple open closing PRs are blocked'
run_case merge-queue 0 0 'an enabled branch merge queue is blocked before CLI enqueue'
run_case auto-merge 0 0 'an existing auto-merge request is blocked'
run_case preflight-malformed 1 0 'a malformed final PR preflight is rejected before mutation'
run_case merge-response-malformed 1 1 'a malformed merge response fails closed after one mutation'
run_case merge-response-errors 1 0 'a GraphQL merge error fails closed without trusting a malformed state'
run_case post-state-fail 1 1 'post-state failure is reported after the single merge attempt'

for blocked_mode in thread-drift check-drift protection-drift fork protected-head multiple-pr merge-queue auto-merge; do
  assert_blocked_case "$blocked_mode"
done

run_case cloud-blocked 0 0 'a blocked Cloud result transitions the awaiting issue'
assert_blocked_case cloud-blocked
run_no_work_retry_limit_case
