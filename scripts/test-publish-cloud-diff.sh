#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
publisher="${repo_root}/scripts/publish-cloud-diff.sh"
real_git="$(command -v git)"

fail() {
  printf 'publish_cloud_diff_test.FAIL=%s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'publish_cloud_diff_test.PASS=%s\n' "$1"
}

assert_contains() {
  local value="$1" needle="$2"
  printf '%s\n' "$value" | grep -Fq "$needle" || fail "missing '${needle}' in: ${value}"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-publish-cloud-diff-test.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "$fake_bin"
remote_head_file="${tmp_dir}/remote-head"
push_log="${tmp_dir}/push.log"
gh_state_file="${tmp_dir}/github.json"
gh_log="${tmp_dir}/gh.log"
thread_state_file="${tmp_dir}/thread-state"
race_count_file="${tmp_dir}/race-count"
pr_view_count_file="${tmp_dir}/pr-view-count"
resolve_count_file="${tmp_dir}/resolve-count"

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
real_git="${RPM_TEST_REAL_GIT:?RPM_TEST_REAL_GIT is required}"
remote_head_file="${RPM_TEST_REMOTE_HEAD:?RPM_TEST_REMOTE_HEAD is required}"
push_log="${RPM_TEST_PUSH_LOG:?RPM_TEST_PUSH_LOG is required}"
gh_state_file="${RPM_TEST_GH_STATE:?RPM_TEST_GH_STATE is required}"
race_count_file="${RPM_TEST_RACE_COUNT:?RPM_TEST_RACE_COUNT is required}"
  case "${1:-}" in
  push)
    url=""; refspec=""; lease=""; lease_seen=false
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        https://github.com/nerdchanii/rpm.git) url="$1" ;;
        HEAD:refs/heads/*) refspec="$1" ;;
        --force-with-lease=refs/heads/*:*) lease="${1#--force-with-lease=}"; lease_seen=true ;;
        --force*|--force-with-lease*) exit 93 ;;
      esac
      shift
    done
    [ "$url" = "https://github.com/nerdchanii/rpm.git" ] || exit 91
    [[ "$refspec" =~ ^HEAD:refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || exit 92
    [ "$lease_seen" = true ] || exit 93
    lease_ref="${lease%%:*}"
    lease_expected="${lease#*:}"
    pushed_ref="${refspec#HEAD:refs/heads/}"
    [ "$lease_ref" = "refs/heads/$pushed_ref" ] || exit 94
    if [ "${RPM_TEST_PUSH_RACE:-false}" = "true" ]; then
      printf '%s\n' '0000000000000000000000000000000000000001' >"$remote_head_file"
    fi
    actual_remote="$(cat "$remote_head_file" 2>/dev/null || true)"
    [ "$actual_remote" = "$lease_expected" ] || exit 96
    if [ "${RPM_TEST_FAIL_PUSH:-false}" = "true" ]; then
      exit 95
    fi
    printf '%s\n' "$refspec" >>"$push_log"
    new_sha="$($real_git rev-parse --verify HEAD^{commit})"
    printf '%s\n' "$new_sha" >"$remote_head_file"
    if [ -f "$gh_state_file" ]; then
      next_state="${gh_state_file}.next"
      jq --arg ref "$pushed_ref" --arg sha "$new_sha" \
        '.prs |= map(if .headRefName == $ref then .headRefOid = $sha else . end)' "$gh_state_file" >"$next_state"
      mv -- "$next_state" "$gh_state_file"
    fi
    ;;
  ls-remote)
    ref="${@: -1}"
    if [ "$ref" = "refs/heads/main" ]; then
      if [ -n "${RPM_TEST_MAIN_HEAD:-}" ] && [ -f "$RPM_TEST_MAIN_HEAD" ]; then
        printf '%s\t%s\n' "$(<"$RPM_TEST_MAIN_HEAD")" "$ref"
      fi
    elif [ -f "$remote_head_file" ] && [ -s "$remote_head_file" ]; then
      remote_sha="$(<"$remote_head_file")"
      if [ "${RPM_TEST_REMOTE_RACE:-false}" = "true" ]; then
        race_count="$(cat "$race_count_file" 2>/dev/null || printf '0')"
        race_count="${race_count:-0}"
        race_count=$((race_count + 1))
        printf '%s\n' "$race_count" >"$race_count_file"
        if [ "$race_count" -eq 2 ]; then
          printf '%s\n' '0000000000000000000000000000000000000001' >"$remote_head_file"
        fi
      fi
      printf '%s\t%s\n' "$remote_sha" "$ref"
    fi
    ;;
  *)
    exec "$real_git" "$@"
    ;;
esac
FAKE_GIT
chmod +x "${fake_bin}/git"

cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state_file="${RPM_TEST_GH_STATE:?RPM_TEST_GH_STATE is required}"
log_file="${RPM_TEST_GH_LOG:?RPM_TEST_GH_LOG is required}"
thread_state_file="${RPM_TEST_THREAD_STATE:?RPM_TEST_THREAD_STATE is required}"
pr_view_count_file="${RPM_TEST_PR_VIEW_COUNT:?RPM_TEST_PR_VIEW_COUNT is required}"
resolve_count_file="${RPM_TEST_RESOLVE_COUNT:?RPM_TEST_RESOLVE_COUNT is required}"
printf '%s\n' "$*" >>"$log_file"
case "$*" in *"--repo nerdchanii/rpm"*) ;; *) exit 90 ;; esac
if [ "${RPM_TEST_FAIL_GH:-}" = "issue-view" ] && [ "$1 $2" = "issue view" ]; then exit 41; fi
if [ "${RPM_TEST_FAIL_GH:-}" = "pr-list" ] && [ "$1 $2" = "pr list" ]; then exit 42; fi

get_issue() { jq -c --argjson n "$1" '.issues[] | select(.number == $n)' "$state_file"; }
get_pr() {
  local n="$1" remote="" view_count
  view_count="$(cat "$pr_view_count_file" 2>/dev/null || printf '0')"
  view_count="${view_count:-0}"
  view_count=$((view_count + 1))
  printf '%s\n' "$view_count" >"$pr_view_count_file"
  if [ "${RPM_TEST_LABEL_RACE:-false}" = "true" ] && [ "$view_count" -eq 4 ]; then
    next_state="${state_file}.label-race"
    jq '(.prs[] | select(.number == 7) | .labels) = ["agent:correction-3"]' "$state_file" >"$next_state"
    mv -- "$next_state" "$state_file"
  fi
  if [ "${RPM_TEST_AWAITING_HEAD_RACE:-false}" = "true" ] && [ "$view_count" -eq 3 ]; then
    printf '%s\n' '0000000000000000000000000000000000000001' >"$RPM_TEST_REMOTE_HEAD"
  fi
  remote="$(cat "$RPM_TEST_REMOTE_HEAD" 2>/dev/null || true)"
  jq -c --argjson n "$n" --arg remote "$remote" \
    '.prs[] | select(.number == $n) | if ($remote != "" and (.headRefName // "") != "main") then .headRefOid = $remote else . end' "$state_file"
}
save() { mv -- "$1" "$state_file"; }
labels_arg() { printf '%s\n' "${1-}" | jq -Rsc 'split("\n") | map(select(length > 0))'; }

case "$1 $2" in
  "label list")
    printf '%s\n' '[{"name":"agent:research"},{"name":"agent:ready"},{"name":"agent:claimed"},{"name":"agent:review-pending"},{"name":"agent:awaiting-merge"},{"name":"agent:blocked"},{"name":"agent:correction-0"},{"name":"agent:correction-1"},{"name":"agent:correction-2"},{"name":"agent:correction-3"},{"name":"agent:correction-4"},{"name":"agent:correction-5"},{"name":"kind:feature"},{"name":"process:agent-followup"}]'
    ;;
  "issue view")
    n=""; url=""; comments=false; shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) [[ "$2" == *comments* ]] && comments=true; shift 2 ;;
        [0-9]*) n="$1"; shift ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "$url" ]; then
      jq --arg url "$url" '.issues[] | select(.url == $url) | . + {labels:[.labels[]? | {name:.}]}' "$state_file"
    elif "$comments"; then
      get_issue "$n" | jq '{comments:(.comments // [])}'
    else
      get_issue "$n"
    fi
    ;;
  "issue edit")
    n=""; remove=(); add=(); shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;;
        --remove-label) remove+=("$2"); shift 2 ;;
        --add-label) add+=("$2"); shift 2 ;;
        [0-9]*) n="$1"; shift ;;
        *) shift ;;
      esac
    done
    next="${state_file}.next"
    rem="$(printf '%s\n' "${remove[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    adds="$(printf '%s\n' "${add[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    jq --argjson n "$n" --argjson rem "$rem" --argjson adds "$adds" \
      '.issues |= map(if .number == $n then .labels = ((.labels // []) | map(. as $label | select(($rem | index($label)) == null)) + $adds | unique) else . end)' "$state_file" >"$next"
    save "$next"
    ;;
  "issue comment")
    n=""; body_file=""; shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        [0-9]*) n="$1"; shift ;;
        *) shift ;;
      esac
    done
    body="$(<"$body_file")"; next="${state_file}.next"
    jq --argjson n "$n" --arg body "$body" '.issues |= map(if .number == $n then .comments = ((.comments // []) + [{body:$body}]) else . end)' "$state_file" >"$next"
    save "$next"
    ;;
  "issue list")
    jq '[.issues[] | select((.labels // []) | map(if type == "object" then .name else . end) | index("process:agent-followup") != null) | {number,title,url,body,state}]' "$state_file"
    ;;
  "issue create")
    title=""; body_file=""; shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --label) shift 2 ;;
        *) shift ;;
      esac
    done
    n="$(jq '[.issues[].number] | max // 100' "$state_file")"; n=$((n + 1))
    body="$(<"$body_file")"; url="https://github.com/nerdchanii/rpm/issues/$n"; next="${state_file}.next"
    jq --argjson n "$n" --arg title "$title" --arg body "$body" --arg url "$url" \
      '.issues += [{number:$n,title:$title,url:$url,body:$body,state:"OPEN",labels:["process:agent-followup"],comments:[]}]' "$state_file" >"$next"
    save "$next"
    printf '%s\n' "$url"
    ;;
  "pr list")
    jq '[.prs[] | select((.state // "OPEN") == "OPEN")]' "$state_file"
    ;;
  "pr view")
    n=""; shift 2
    while [ "$#" -gt 0 ]; do case "$1" in --repo) shift 2 ;; [0-9]*) n="$1"; shift ;; *) shift ;; esac; done
    get_pr "$n"
    ;;
  "pr create")
    head=""; base=""; title=""; body_file=""; draft=false; shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;; --head) head="$2"; shift 2 ;; --base) base="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;; --body-file) body_file="$2"; shift 2 ;;
        --draft) draft=true; shift ;; *) shift ;;
      esac
    done
    n="$(jq '[.prs[].number] | max // 100' "$state_file")"; n=$((n + 1))
    body="$(<"$body_file")"; head_sha="$(<"${RPM_TEST_REMOTE_HEAD:?}")"; base_sha="${RPM_TEST_BASE_SHA:?}"
    url="https://github.com/nerdchanii/rpm/pull/${n}"; next="${state_file}.next"
    jq --argjson n "$n" --arg url "$url" --arg title "$title" --arg body "$body" \
      --arg head "$head" --arg base "$base" --arg head_sha "$head_sha" --arg base_sha "$base_sha" --argjson draft "$draft" \
      '.prs += [{number:$n,url:$url,title:$title,body:$body,state:"OPEN",isDraft:$draft,baseRefName:$base,baseRefOid:$base_sha,headRefName:$head,headRefOid:$head_sha,headRepository:{nameWithOwner:"nerdchanii/rpm"},headRepositoryOwner:{login:"nerdchanii"},labels:[]}]' "$state_file" >"$next"
    save "$next"
    if [ "${RPM_TEST_PR_CREATE_AFTER_WRITE:-false}" = "true" ]; then
      exit 43
    fi
    printf '%s\n' "$url"
    ;;
  "pr edit")
    n=""; body_file=""; remove=(); add=(); shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;; --body-file) body_file="$2"; shift 2 ;;
        --remove-label) remove+=("$2"); shift 2 ;; --add-label) add+=("$2"); shift 2 ;;
        [0-9]*) n="$1"; shift ;; *) shift ;;
      esac
    done
    next="${state_file}.next"; rem="$(printf '%s\n' "${remove[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"; adds="$(printf '%s\n' "${add[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    jq --argjson n "$n" --argjson rem "$rem" --argjson adds "$adds" '.prs |= map(if .number == $n then .labels = ((.labels // []) | map(. as $label | select(($rem | index($label)) == null)) + $adds | unique) else . end)' "$state_file" >"$next"
    if [ -n "$body_file" ]; then body="$(<"$body_file")"; jq --argjson n "$n" --arg body "$body" '.prs |= map(if .number == $n then .body = $body else . end)' "$next" >"${next}.body"; mv -- "${next}.body" "$next"; fi
    save "$next"
    ;;
  "pr ready")
    n=""; shift 2; while [ "$#" -gt 0 ]; do case "$1" in --repo) shift 2 ;; [0-9]*) n="$1"; shift ;; *) shift ;; esac; done
    next="${state_file}.next"; jq --argjson n "$n" '.prs |= map(if .number == $n then .isDraft = false else . end)' "$state_file" >"$next"; save "$next"
    ;;
  "api graphql")
    query=""; thread_id=""; comments_after=""; threads_after=""; after=""; number=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) shift 2 ;;
        -f)
          case "$2" in
            query=*) query="${2#query=}" ;;
            threadId=*) thread_id="${2#threadId=}" ;;
            commentsAfter=*) comments_after="${2#commentsAfter=}" ;;
            threadsAfter=*) threads_after="${2#threadsAfter=}" ;;
            after=*) after="${2#after=}" ;;
          esac
          shift 2
          ;;
        -F)
          case "$2" in number=*) number="${2#number=}" ;; esac
          shift 2
          ;;
        *) shift ;;
      esac
    done
    if [[ "$query" == *'closingIssuesReferences(first:100'* ]]; then
      closing_ref_mode="${RPM_TEST_CLOSING_REF_MODE:-valid}"
      closing_nodes='[{"number":42,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
      closing_has_next=false
      closing_cursor=""
      closing_refs_absent=false
      case "$closing_ref_mode" in
        missing) closing_nodes='[]' ;;
        duplicate) closing_nodes='[{"number":42,"repository":{"nameWithOwner":"nerdchanii/rpm"}},{"number":42,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]' ;;
        malformed) closing_nodes='[{"number":"42","repository":{"nameWithOwner":"nerdchanii/rpm"}}]' ;;
        wrong-repo) closing_nodes='[{"number":42,"repository":{"nameWithOwner":"evil/rpm"}}]' ;;
        absent) closing_refs_absent=true ;;
        pagination)
          if [ -z "$after" ]; then
            closing_nodes='[{"number":99,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
            closing_has_next=true
            closing_cursor="closing-cursor-1"
          else
            closing_nodes='[{"number":42,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
          fi
          ;;
      esac
      if [ "$closing_refs_absent" = "true" ]; then
        jq -nc --argjson pr "${number:-7}" '{data:{repository:{pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"}}}}}'
      else
        jq -nc --argjson pr "${number:-7}" --argjson nodes "$closing_nodes" --arg cursor "$closing_cursor" --argjson has_next "$closing_has_next" \
          '{data:{repository:{pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
      fi
    elif [[ "$query" == *'reviewThreads(first:100'* && "$query" != *'node(id:'* ]]; then
      live_nodes='[]'
      if [ "${RPM_TEST_LIVE_UNRESOLVED:-false}" = "true" ]; then
        live_nodes='[{"id":"LIVE_THREAD_1","isResolved":false,"isOutdated":false}]'
      fi
      live_has_next=false
      live_cursor=""
      if [ "${RPM_TEST_LIVE_PAGINATED:-false}" = "true" ] && [ -z "$threads_after" ]; then
        live_has_next=true
        live_cursor="live-cursor-1"
        live_nodes='[{"id":"LIVE_THREAD_1","isResolved":true,"isOutdated":false}]'
      elif [ "${RPM_TEST_LIVE_PAGINATED:-false}" = "true" ] && [ -n "$threads_after" ]; then
        live_nodes='[{"id":"LIVE_THREAD_2","isResolved":false,"isOutdated":false}]'
      fi
      jq -nc --argjson pr "${number:-7}" --argjson nodes "$live_nodes" --arg cursor "$live_cursor" --argjson has_next "$live_has_next" \
        '{data:{repository:{pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"},reviewThreads:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
    elif [[ "$query" == query* ]]; then
      resolved=false
      if [ -f "$thread_state_file" ] && grep -Fqx -- "$thread_id" "$thread_state_file"; then resolved=true; fi
      thread_type="${RPM_TEST_THREAD_TYPE:-PullRequestReviewThread}"
      thread_repo="${RPM_TEST_THREAD_REPO:-nerdchanii/rpm}"
      thread_pr="${RPM_TEST_THREAD_PR:-7}"
      expected_head="${RPM_TEST_EXPECTED_THREAD_HEAD:-0000000000000000000000000000000000000000}"
      thread_mode="${RPM_TEST_THREAD_MODE:-valid}"
      if [ "$thread_id" = "PRRT_test_2" ] && [ -n "${RPM_TEST_SECOND_THREAD_MODE:-}" ]; then
        thread_mode="$RPM_TEST_SECOND_THREAD_MODE"
      fi
      author="chatgpt-codex-connector[bot]"
      thread_path="src/app.txt"
      thread_line=1
      thread_original_line=1
      thread_original_start=1
      thread_side=RIGHT
      thread_start_side=RIGHT
      thread_outdated=false
      comment_outdated=false
      comment_commit="$expected_head"
      comment_original_commit="$expected_head"
      case "$thread_mode" in
        wrong-actor) author="human-user" ;;
        wrong-path) thread_path="src/other.txt" ;;
        wrong-line) thread_original_line=99; thread_original_start=99 ;;
        stale-commit) comment_commit="0000000000000000000000000000000000000001"; comment_original_commit="$comment_commit" ;;
        outdated) thread_outdated=true; comment_outdated=true ;;
        wrong-side) thread_side=LEFT; thread_start_side=LEFT ;;
      esac
      root_comment="$(jq -nc --arg author "$author" --arg path "$thread_path" --arg commit "$comment_commit" --arg original "$comment_original_commit" --argjson outdated "$comment_outdated" \
        '{id:"COMMENT_test_1",author:{login:$author},createdAt:"2026-09-02T00:00:00Z",body:"fix this",path:$path,line:1,startLine:null,originalLine:1,originalStartLine:null,diffHunk:"@@ -1 +1 @@",outdated:$outdated,side:"RIGHT",startSide:null,commit:{oid:$commit},originalCommit:{oid:$original}}')"
      comments="[$root_comment]"
      if [ "$thread_mode" = "reply-actor" ]; then
        reply_comment="$(jq -nc --arg path "$thread_path" --arg commit "$comment_commit" --arg original "$comment_original_commit" \
          '{id:"COMMENT_test_2",author:{login:"human-user"},createdAt:"2026-09-02T00:00:01Z",body:"reply",path:$path,line:1,startLine:null,originalLine:1,originalStartLine:null,diffHunk:"@@ -1 +1 @@",outdated:false,side:"RIGHT",startSide:null,commit:{oid:$commit},originalCommit:{oid:$original}}')"
        comments="[$root_comment,$reply_comment]"
      fi
      if [ "${RPM_TEST_THREAD_MODE:-valid}" = "comment-pagination" ] && [ -n "$comments_after" ]; then
        comments="$(jq -nc --arg expected "$expected_head" '[{id:"COMMENT_test_2",author:{login:"chatgpt-codex-connector[bot]"},createdAt:"2026-09-02T00:00:01Z",body:"reply",path:"src/app.txt",line:1,startLine:null,originalLine:1,originalStartLine:null,diffHunk:"@@ -1 +1 @@",outdated:false,side:"RIGHT",startSide:null,commit:{oid:$expected},originalCommit:{oid:$expected}}]')"
      fi
      page_has_next=false
      page_cursor=""
      if [ "${RPM_TEST_THREAD_MODE:-valid}" = "comment-pagination" ] && [ -z "$comments_after" ]; then
        page_has_next=true
        page_cursor="comment-cursor-1"
      fi
      jq -nc --arg id "$thread_id" --arg type "$thread_type" --arg repo "$thread_repo" --argjson pr "$thread_pr" --argjson resolved "$resolved" \
        --arg path "$thread_path" --argjson line "$thread_line" --argjson original_line "$thread_original_line" --argjson original_start "$thread_original_start" \
        --arg side "$thread_side" --arg start_side "$thread_start_side" --argjson thread_outdated "$thread_outdated" \
        --argjson comments "$comments" --arg cursor "$page_cursor" --argjson has_next "$page_has_next" \
        '{data:{node:{__typename:$type,id:$id,isResolved:$resolved,isOutdated:$thread_outdated,path:$path,line:$line,startLine:null,originalLine:$original_line,originalStartLine:$original_start,diffSide:$side,startDiffSide:$start_side,pullRequest:{number:$pr,repository:{nameWithOwner:$repo}},comments:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$comments}}}}'
    else
      if [ "${RPM_TEST_RESOLVE_HEAD_RACE:-false}" = "true" ]; then
        printf '%s\n' '0000000000000000000000000000000000000001' >"${RPM_TEST_REMOTE_HEAD:?}"
      fi
      printf '%s\n' "$thread_id" >>"$thread_state_file"
      count="$(cat "$resolve_count_file" 2>/dev/null || printf '0')"
      count="${count:-0}"
      printf '%s\n' "$((count + 1))" >"$resolve_count_file"
      printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    fi
    ;;
  *) printf 'unexpected fake gh call: %s\n' "$*" >&2; exit 99 ;;
esac
FAKE_GH
chmod +x "${fake_bin}/gh"

export PATH="${fake_bin}:${PATH}"
export GITHUB_REPOSITORY="nerdchanii/rpm"
export GH_TOKEN="test-token"
export RPM_TEST_REAL_GIT="$real_git"
export RPM_TEST_REMOTE_HEAD="$remote_head_file"
export RPM_TEST_PUSH_LOG="$push_log"
export RPM_TEST_GH_STATE="$gh_state_file"
export RPM_TEST_GH_LOG="$gh_log"
export RPM_TEST_THREAD_STATE="$thread_state_file"
export RPM_TEST_RACE_COUNT="$race_count_file"
export RPM_TEST_PR_VIEW_COUNT="$pr_view_count_file"
export RPM_TEST_RESOLVE_COUNT="$resolve_count_file"

new_repo() {
  local name="$1"
  local path="${tmp_dir}/${name}"
  mkdir -p "$path/src" "$path/scripts"
  "$real_git" -C "$path" init -q -b main
  "$real_git" -C "$path" config user.name test
  "$real_git" -C "$path" config user.email test@example.com
  printf 'old\n' >"$path/src/app.txt"
  printf '# gate fixture\n' >"$path/scripts/safe-direct-merge.sh"
  "$real_git" -C "$path" add src/app.txt scripts/safe-direct-merge.sh
  "$real_git" -C "$path" commit -qm init
  "$real_git" -C "$path" remote add origin https://github.com/nerdchanii/rpm.git
  printf '%s\n' "$path"
}

make_patch() {
  local path="$1" patch_file="$2" target="$3" content="$4"
  printf '%s\n' "$content" >"$path/$target"
  "$real_git" -C "$path" diff --binary >"$patch_file"
  "$real_git" -C "$path" restore -- "$target"
}

make_protected_patch() {
  local path="$1" patch_file="$2"
  printf 'new\n' >"$path/src/app.txt"
  printf '# altered\n' >"$path/scripts/safe-direct-merge.sh"
  "$real_git" -C "$path" diff --binary >"$patch_file"
  "$real_git" -C "$path" restore -- src/app.txt scripts/safe-direct-merge.sh
}

write_result() {
  local path="$1"
  shift
  printf '%s\n' "$*" >"$path"
}

write_issue_state() {
  local issue="$1" labels_json="$2" prs_json="${3:-[]}"
  jq -n --argjson labels "$labels_json" --argjson prs "$prs_json" --argjson issue "$issue" \
    '{issues:[{number:$issue,state:"OPEN",title:("Issue " + ($issue|tostring)),body:"",labels:$labels,comments:[]}],prs:$prs}' >"$gh_state_file"
}

write_review_state() {
  local base_sha="$1" head_sha="$2" branch="$3"
  local head_repository="${4:-nerdchanii/rpm}" pr_labels
  pr_labels="${5:-[\"agent:correction-0\"]}"
  jq -n --arg base "$base_sha" --arg head "$head_sha" --arg branch "$branch" \
    --arg head_repository "$head_repository" --argjson labels "$pr_labels" \
    '{issues:[{number:42,state:"OPEN",title:"Issue 42",body:"",labels:["agent:review-pending","kind:feature"],comments:[]}],prs:[{number:7,url:"https://github.com/nerdchanii/rpm/pull/7",title:"review",body:"Closes #42",state:"OPEN",isDraft:false,baseRefName:"main",baseRefOid:$base,headRefName:$branch,headRefOid:$head,headRepository:{nameWithOwner:$head_repository},headRepositoryOwner:{login:"nerdchanii"},labels:$labels}]}' >"$gh_state_file"
}

run_publisher() {
  local path="$1" expected_thread_head="" arg previous=""
  shift
  local -a publisher_args=("$@")
  for arg in "${publisher_args[@]}"; do
    if [ "$previous" = "--expected-head-sha" ]; then
      expected_thread_head="$arg"
    fi
    case "$arg" in
      --expected-head-sha=*)
        expected_thread_head="${arg#--expected-head-sha=}"
        previous=""
        ;;
      --expected-head-sha) previous="$arg" ;;
      *) previous="" ;;
    esac
  done
  (cd "$path" && RPM_TEST_EXPECTED_THREAD_HEAD="$expected_thread_head" bash "$publisher" --expected-issue "${RPM_TEST_EXPECTED_ISSUE:-42}" "${publisher_args[@]}")
}

run_publisher_without_expected_issue() {
  local path="$1"
  shift
  (cd "$path" && bash "$publisher" "$@")
}

base_sha=""
head_sha=""
patch_file=""
result_file=""
repo=""

# Issue happy path: commit the validated patch, push one safe branch, create a
# Draft PR, mark it ready, preserve kind labels, and advance the issue.
repo="$(new_repo issue-happy)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue.patch"
result_file="${tmp_dir}/issue-result.json"
make_patch "$repo" "$patch_file" src/app.txt "new issue content"
write_issue_state 42 '["agent:claimed","kind:feature"]'
: >"$remote_head_file"
: >"$push_log"
: >"$gh_log"
jq -n --arg base "$base_sha" '{version:1,lane:"issue",status:"patch",issue:42,pr:null,base_sha:$base,head_sha:null,summary:"Issue implementation",validation:["just validate: PASS"],actionable_findings_remaining:false,next_state:"review-pending",correction_label:"agent:correction-0",resolved_thread_ids:[],followups:[]}' >"$result_file"
export RPM_TEST_BASE_SHA="$base_sha"
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-happy)" || fail "issue happy path failed: $output"
assert_contains "$output" '"status":"published"'
new_sha="$(<"$remote_head_file")"
[ -n "$new_sha" ] || fail "issue push did not record a head"
branch="feat/issue-42-codex-cloud-issue-happy"
assert_contains "$(<"$push_log")" "HEAD:refs/heads/${branch}"
jq -e --arg branch "$branch" --arg sha "$new_sha" \
  '.prs | length == 1 and .[0].headRefName == $branch and .[0].headRefOid == $sha and .[0].isDraft == false and (.[0].labels | index("agent:correction-0") != null) and (.[0].body | contains("Closes #42"))' "$gh_state_file" >/dev/null || fail "issue publication state mismatch"
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "issue labels were not preserved"
pass "issue-happy-publication"

# Review happy path: base_sha identifies main while head_sha identifies the
# starting PR head.  The lease-protected fast-forward push supplies the CAS.
repo="$(new_repo review-happy)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-happy"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review.patch"
result_file="${tmp_dir}/review-result.json"
make_patch "$repo" "$patch_file" src/app.txt "review fixed"
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
: >"$push_log"
jq -n --arg base "$base_sha" --arg head "$head_sha" '{version:1,lane:"review",status:"patch",issue:42,pr:7,base_sha:$base,head_sha:$head,summary:"Review fix",validation:["focused test: PASS"],actionable_findings_remaining:true,next_state:"review-pending",correction_label:"agent:correction-1",resolved_thread_ids:["PRRT_test_1"],followups:[]}' >"$result_file"
export RPM_TEST_BASE_SHA="$base_sha"
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-happy)" || fail "review happy path failed: $output"
assert_contains "$output" '"status":"published"'
review_new_sha="$(<"$remote_head_file")"
jq -e --arg sha "$review_new_sha" '.prs[0].headRefOid == $sha and (.prs[0].labels | index("agent:correction-1") != null) and (.prs[0].labels | index("agent:correction-0") == null)' "$gh_state_file" >/dev/null || fail "review correction label was not replaced"
assert_contains "$(<"$gh_log")" 'api graphql'
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "review ordinary labels changed"
pass "review-distinct-shas-and-thread-resolution"

expect_failure() {
  local name="$1" needle="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded: $output"
  assert_contains "$output" "$needle"
  pass "$name"
}

reset_fake() {
  : >"$remote_head_file"
  : >"$push_log"
  : >"$gh_log"
  : >"$thread_state_file"
  : >"$race_count_file"
  : >"$pr_view_count_file"
  : >"$resolve_count_file"
  unset RPM_TEST_REMOTE_RACE RPM_TEST_FAIL_PUSH RPM_TEST_PR_CREATE_AFTER_WRITE
  unset RPM_TEST_PUSH_RACE RPM_TEST_EXPECTED_ISSUE RPM_TEST_LABEL_RACE RPM_TEST_AWAITING_HEAD_RACE
  unset RPM_TEST_THREAD_REPO RPM_TEST_THREAD_PR RPM_TEST_THREAD_TYPE RPM_TEST_EXPECTED_THREAD_HEAD
  unset RPM_TEST_THREAD_MODE RPM_TEST_SECOND_THREAD_MODE RPM_TEST_LIVE_UNRESOLVED RPM_TEST_LIVE_PAGINATED RPM_TEST_RESOLVE_HEAD_RACE
  unset RPM_TEST_CLOSING_REF_MODE
}

write_issue_result() {
  local path="$1" base="$2" status="${3:-patch}" next_state="${4:-review-pending}"
  local actionable="${5:-false}" correction="${6-agent:correction-0}"
  jq -n --arg base "$base" --arg status "$status" --arg next "$next_state" \
    --arg correction "$correction" --argjson actionable "$actionable" \
    '{version:1,lane:"issue",status:$status,issue:42,pr:null,base_sha:$base,head_sha:null,summary:"test result",validation:["focused test: PASS"],actionable_findings_remaining:$actionable,next_state:$next,correction_label:(if $correction == "" then null else $correction end),resolved_thread_ids:[],followups:[]}' >"$path"
}

write_review_result() {
  local path="$1" base="$2" head="$3" status="${4:-patch}" next_state="${5:-review-pending}"
  local actionable="${6:-true}" correction="${7-agent:correction-1}"
  jq -n --arg base "$base" --arg head "$head" --arg status "$status" --arg next "$next_state" \
    --arg correction "$correction" --argjson actionable "$actionable" \
    '{version:1,lane:"review",status:$status,issue:42,pr:7,base_sha:$base,head_sha:$head,summary:"test result",validation:["focused test: PASS"],actionable_findings_remaining:$actionable,next_state:$next,correction_label:(if $correction == "" then null else $correction end),resolved_thread_ids:[],followups:[]}' >"$path"
}

prepare_review_thread_case() {
  local name="$1" ids_json="${2:-[\"PRRT_test_1\"]}"
  repo="$(new_repo "$name")"
  base_sha="$($real_git -C "$repo" rev-parse HEAD)"
  branch="feat/issue-42-codex-cloud-${name}"
  "$real_git" -C "$repo" switch -q -c "$branch"
  printf 'review base\n' >"$repo/src/app.txt"
  "$real_git" -C "$repo" add src/app.txt
  "$real_git" -C "$repo" commit -qm 'review base'
  head_sha="$($real_git -C "$repo" rev-parse HEAD)"
  patch_file="${tmp_dir}/${name}.patch"
  result_file="${tmp_dir}/${name}.json"
  make_patch "$repo" "$patch_file" src/app.txt "${name} content"
  write_review_state "$base_sha" "$head_sha" "$branch"
  printf '%s\n' "$head_sha" >"$remote_head_file"
  write_review_result "$result_file" "$base_sha" "$head_sha"
  jq --argjson ids "$ids_json" '.resolved_thread_ids = $ids' "$result_file" >"${result_file}.next"
  mv -- "${result_file}.next" "$result_file"
  reset_fake
  printf '%s\n' "$head_sha" >"$remote_head_file"
}

followup_fingerprint() {
  local title="$1" body="$2" digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\0%s' "$title" "$body" | sha256sum | awk '{print $1}')"
  else
    digest="$(printf '%s\0%s' "$title" "$body" | shasum -a 256 | awk '{print $1}')"
  fi
  printf 'sha256:%s\n' "$digest"
}

add_followup_to_result() {
  local path="$1" title="$2" source="$3" details="$4"
  local body="<!-- rpm-agent-followup-source: ${source} -->"$'\n'"${details}"
  local fingerprint
  fingerprint="$(followup_fingerprint "$title" "$body")"
  local tmp="${path}.next"
  jq --arg title "$title" --arg source "$source" --arg body "$body" --arg fingerprint "$fingerprint" \
    '.followups = [{title:$title,body:$body,source:$source,fingerprint:$fingerprint,labels:["bug"]}]' "$path" >"$tmp"
  mv -- "$tmp" "$path"
}

# A correction label changed after the publisher's initial snapshot is never
# replaced from a stale run.  The fake GitHub mutates it on the guard read;
# the publisher must fail before issuing the label edit.
repo="$(new_repo review-correction-label-race)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-correction-label-race"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-correction-label-race.patch"
result_file="${tmp_dir}/review-correction-label-race.json"
make_patch "$repo" "$patch_file" src/app.txt 'correction label race content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_LABEL_RACE=true
expect_failure "correction-label-race-fails-closed" 'correction-label-race' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-correction-label-race
if grep -Fq -- '--add-label agent:correction-1' "$gh_log"; then
  fail "correction label race issued a stale label edit"
fi
jq -e '.prs[0].labels == ["agent:correction-3"]' "$gh_state_file" >/dev/null || fail "correction label race did not preserve newer label"
unset RPM_TEST_LABEL_RACE

# An unclaimed, ready issue can report no work without a GitHub mutation.
repo="$(new_repo issue-no-work-ready)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-no-work-ready.patch"
result_file="${tmp_dir}/issue-no-work-ready.json"
: >"$patch_file"
write_issue_state 42 '["agent:ready","kind:feature"]'
write_issue_result "$result_file" "$base_sha" no-work unchanged false ""
reset_fake
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-no-work-ready)" || fail "unclaimed no-work failed: $output"
assert_contains "$output" '"status":"no-work"'
[ ! -s "$push_log" ] || fail "unclaimed no-work pushed code"
jq -e '.issues[0].labels == ["agent:ready","kind:feature"]' "$gh_state_file" >/dev/null || fail "unclaimed no-work changed labels"
pass "issue-no-work-unclaimed-is-no-mutation"

# A selected issue left claimed by a no-work result is recovered to blocked.
repo="$(new_repo issue-no-work-claimed)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-no-work-claimed.patch"
result_file="${tmp_dir}/issue-no-work-claimed.json"
: >"$patch_file"
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha" no-work unchanged false ""
reset_fake
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-no-work-claimed)" || fail "claimed no-work recovery failed: $output"
assert_contains "$output" '"reason":"no-work-left-claimed"'
jq -e '.issues[0].labels == ["agent:blocked","kind:feature"] and (.issues[0].comments | length) == 1' "$gh_state_file" >/dev/null || fail "claimed no-work was not blocked"
pass "issue-no-work-claimed-recovers-idempotently"

# Blocked work may still publish up to the validated follow-up limit.  A
# repeated blocked result keeps both the lifecycle and follow-up idempotent.
repo="$(new_repo issue-blocked-followup)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-blocked-followup.patch"
result_file="${tmp_dir}/issue-blocked-followup.json"
: >"$patch_file"
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha" blocked blocked false ""
add_followup_to_result "$result_file" 'Deferred unrelated finding' issue:42 'This finding is outside the selected change.'
reset_fake
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-blocked-followup)" || fail "blocked follow-up publication failed: $output"
assert_contains "$output" '"status":"blocked"'
jq -e '.issues[0].labels == ["agent:blocked","kind:feature"] and (.issues[0].comments | length) == 1 and ([.issues[] | select((.labels // []) | index("process:agent-followup") != null)] | length) == 1' "$gh_state_file" >/dev/null || fail "blocked follow-up state mismatch"
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-blocked-followup)" || fail "blocked follow-up repeat failed: $output"
jq -e '(.issues[0].labels | index("agent:blocked") != null) and (.issues[0].comments | length) == 1 and ([.issues[] | select((.labels // []) | index("process:agent-followup") != null)] | length) == 1' "$gh_state_file" >/dev/null || fail "blocked repeat was not idempotent"
pass "blocked-followup-published-and-deduped"

# Dry-run validates the handoff while keeping the checkout, branch, and API
# surface untouched.
repo="$(new_repo issue-dry-run)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-dry-run.patch"
result_file="${tmp_dir}/issue-dry-run.json"
make_patch "$repo" "$patch_file" src/app.txt 'dry run content'
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
before_head="$($real_git -C "$repo" rev-parse HEAD)"
before_status="$($real_git -C "$repo" status --porcelain=v1 --untracked-files=all)"
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-dry-run --dry-run)" || fail "dry-run failed: $output"
assert_contains "$output" '"reason":"dry-run-validated"'
[ ! -s "$push_log" ] && [ ! -s "$gh_log" ] || fail "dry-run mutated an API or remote"
[ "$before_head" = "$($real_git -C "$repo" rev-parse HEAD)" ] || fail "dry-run changed HEAD"
[ "$before_status" = "$($real_git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] || fail "dry-run changed worktree"
pass "dry-run-zero-mutation"

# Publisher-side patch parsing remains a second protected-path gate.
repo="$(new_repo issue-protected-patch)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-protected.patch"
result_file="${tmp_dir}/issue-protected.json"
make_protected_patch "$repo" "$patch_file"
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
expect_failure "protected-path-defense-in-depth" 'patch-protected-path:scripts/safe-direct-merge.sh' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-protected-patch
[ ! -s "$push_log" ] || fail "protected patch reached push"

# The old canonical_body alias and oversized UTF-8 summary are rejected
# before any GitHub read or write.
repo="$(new_repo issue-schema)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-schema.patch"
result_file="${tmp_dir}/issue-schema.json"
: >"$patch_file"
write_issue_result "$result_file" "$base_sha" no-work unchanged false ""
reset_fake
expect_failure "expected-issue-required" 'missing-expected-issue' \
  run_publisher_without_expected_issue "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-missing-expected-issue
export RPM_TEST_EXPECTED_ISSUE=43
expect_failure "expected-issue-binds-result" 'result-issue-mismatch' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-mismatched-expected-issue
unset RPM_TEST_EXPECTED_ISSUE
jq '. + {canonical_body:"forbidden alias"}' "$result_file" >"${result_file}.next"; mv -- "${result_file}.next" "$result_file"
reset_fake
expect_failure "result-schema-rejects-canonical-body-alias" 'invalid-result-schema' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-schema

printf '%s\n' "{\"version\":1,\"lane\":\"issue\",\"status\":\"no-work\",\"issue\":42,\"pr\":null,\"base_sha\":\"$base_sha\",\"head_sha\":null,\"summary\":\"first\",\"summary\":\"duplicate\",\"validation\":[],\"actionable_findings_remaining\":false,\"next_state\":\"unchanged\",\"correction_label\":null,\"resolved_thread_ids\":[],\"followups\":[]}" >"$result_file"
expect_failure "result-schema-rejects-duplicate-key" 'invalid-result-integrity' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-duplicate-key

write_issue_result "$result_file" "$base_sha" no-work unchanged false ""
long_summary="$(python3 - <<'PY'
print('가' * 1400)
PY
)"
jq --arg summary "$long_summary" '.summary = $summary' "$result_file" >"${result_file}.next"; mv -- "${result_file}.next" "$result_file"
expect_failure "summary-utf8-byte-limit" 'invalid-result-integrity' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-summary-bytes

# A review PR from a fork is never eligible for an in-repository ref push.
repo="$(new_repo review-fork)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-fork"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-fork.patch"
result_file="${tmp_dir}/review-fork.json"
make_patch "$repo" "$patch_file" src/app.txt 'fork review content'
write_review_state "$base_sha" "$head_sha" "$branch" evil/rpm
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
expect_failure "fork-head-rejected" 'pr-head-repository-mismatch' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-fork
[ ! -s "$push_log" ] || fail "fork PR reached push"

# The expected review ref cannot be a protected branch, even if the PR
# metadata is otherwise valid.
repo="$(new_repo review-protected-ref)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-protected-ref"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-protected-ref.patch"
result_file="${tmp_dir}/review-protected-ref.json"
make_patch "$repo" "$patch_file" src/app.txt 'protected ref content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
expect_failure "protected-review-ref-rejected" 'unsafe-head-ref' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref main --run-id review-protected-ref
[ ! -s "$push_log" ] || fail "protected review ref reached push"

# A remote update between the preflight read and the push is caught by the
# captured-ref CAS check, with no force fallback.
repo="$(new_repo review-remote-race)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-remote-race"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-race.patch"
result_file="${tmp_dir}/review-race.json"
make_patch "$repo" "$patch_file" src/app.txt 'race content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_REMOTE_RACE=true
expect_failure "remote-head-race-cas" 'pre-push-remote-head-race' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-remote-race
[ ! -s "$push_log" ] || fail "remote race reached push"
unset RPM_TEST_REMOTE_RACE

# A remote update after the local lease read is rejected by the server-side
# force-with-lease check.  The fake git mutates the ref inside `git push`, so
# the earlier read still matches and only the atomic lease can catch it.
repo="$(new_repo review-atomic-lease-race)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-atomic-lease-race"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-atomic-lease-race.patch"
result_file="${tmp_dir}/review-atomic-lease-race.json"
make_patch "$repo" "$patch_file" src/app.txt 'atomic lease race content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_PUSH_RACE=true
expect_failure "remote-head-race-atomic-lease" 'push-failed' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-atomic-lease-race
[ ! -s "$push_log" ] || fail "atomic lease race reached successful push"
unset RPM_TEST_PUSH_RACE

# A failed normal push is surfaced as a CAS/push failure and never retried
# with --force.
repo="$(new_repo review-push-failure)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-push-failure"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-push-failure.patch"
result_file="${tmp_dir}/review-push-failure.json"
make_patch "$repo" "$patch_file" src/app.txt 'push failure content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_FAIL_PUSH=true
expect_failure "normal-push-failure-no-force" 'push-failed' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-push-failure
[ ! -s "$push_log" ] || fail "failed push was logged as successful"
unset RPM_TEST_FAIL_PUSH

# Multiple push URLs fail identity verification before any publication.
repo="$(new_repo remote-pushurl)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/remote-pushurl.patch"
result_file="${tmp_dir}/remote-pushurl.json"
: >"$patch_file"
write_issue_state 42 '["agent:ready"]'
write_issue_result "$result_file" "$base_sha" no-work unchanged false ""
"$real_git" -C "$repo" config --add remote.origin.pushurl https://github.com/nerdchanii/rpm.git
"$real_git" -C "$repo" config --add remote.origin.pushurl https://github.com/nerdchanii/rpm.git
reset_fake
expect_failure "multiple-pushurl-rejected" 'origin-push-url-count' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id remote-pushurl

# If PR creation reports an error after writing the PR, exact branch/base/head
# reconciliation adopts the single matching PR instead of creating a duplicate.
repo="$(new_repo issue-create-race)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-create-race.patch"
result_file="${tmp_dir}/issue-create-race.json"
make_patch "$repo" "$patch_file" src/app.txt 'create race content'
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
export RPM_TEST_BASE_SHA="$base_sha"
export RPM_TEST_PR_CREATE_AFTER_WRITE=true
output="$(run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-create-race)" || fail "create race adoption failed: $output"
assert_contains "$output" '"status":"published"'
jq -e '.prs | length == 1 and .[0].isDraft == false and (.[0].body | contains("Closes #42"))' "$gh_state_file" >/dev/null || fail "create race did not adopt exact PR"
unset RPM_TEST_PR_CREATE_AFTER_WRITE
pass "issue-pr-create-race-adopts-exact-match"

# A newly created PR must expose the expected issue through GitHub's closing
# reference connection before the publisher performs any label or issue
# transition.  A body-only/timeline hint is insufficient.
repo="$(new_repo issue-closing-reference-create)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-closing-reference-create.patch"
result_file="${tmp_dir}/issue-closing-reference-create.json"
make_patch "$repo" "$patch_file" src/app.txt 'closing reference create content'
write_issue_state 42 '["agent:claimed","kind:feature"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
export RPM_TEST_BASE_SHA="$base_sha"
export RPM_TEST_CLOSING_REF_MODE=missing
expect_failure "issue-created-pr-closing-reference-required" 'closing-issue-binding-missing' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-closing-reference-create
jq -e '.issues[0].labels == ["agent:claimed","kind:feature"] and (.prs | length == 1)' "$gh_state_file" >/dev/null || fail "created PR closing-reference failure changed lifecycle"
unset RPM_TEST_CLOSING_REF_MODE

# Existing PR adoption has the same binding gate before its managed body or
# correction labels can be changed.
repo="$(new_repo issue-closing-reference-existing)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-issue-closing-reference-existing"
patch_file="${tmp_dir}/issue-closing-reference-existing.patch"
result_file="${tmp_dir}/issue-closing-reference-existing.json"
make_patch "$repo" "$patch_file" src/app.txt 'closing reference existing content'
prs_json="$(jq -nc --arg base "$base_sha" --arg branch "$branch" '[{number:7,url:"https://github.com/nerdchanii/rpm/pull/7",title:"existing",body:"Closes #42",state:"OPEN",isDraft:false,baseRefName:"main",baseRefOid:$base,headRefName:$branch,headRefOid:$base,headRepository:{nameWithOwner:"nerdchanii/rpm"},headRepositoryOwner:{login:"nerdchanii"},labels:["agent:correction-0"]}]')"
write_issue_state 42 '["agent:claimed","kind:feature"]' "$prs_json"
write_issue_result "$result_file" "$base_sha"
reset_fake
export RPM_TEST_BASE_SHA="$base_sha"
export RPM_TEST_CLOSING_REF_MODE=missing
expect_failure "issue-adopted-pr-closing-reference-required" 'closing-issue-binding-missing' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-closing-reference-existing
jq -e '.issues[0].labels == ["agent:claimed","kind:feature"] and (.prs[0].labels == ["agent:correction-0"])' "$gh_state_file" >/dev/null || fail "adopted PR closing-reference failure changed lifecycle"
unset RPM_TEST_CLOSING_REF_MODE

# Thread IDs are checked against the exact PR before any review commit/push.
repo="$(new_repo review-thread-binding)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-thread-binding"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-thread-binding.patch"
result_file="${tmp_dir}/review-thread-binding.json"
make_patch "$repo" "$patch_file" src/app.txt 'thread binding content'
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha"
jq '.resolved_thread_ids = ["PRRT_test_1"]' "$result_file" >"${result_file}.next"; mv -- "${result_file}.next" "$result_file"
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_THREAD_REPO=evil/rpm
expect_failure "review-thread-repo-binding" 'review-thread-not-bound-or-already-resolved' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-binding
[ ! -s "$push_log" ] || fail "unbound review thread reached push"
unset RPM_TEST_THREAD_REPO

# A body or timeline hint cannot stand in for GitHub's actual closing issue
# connection.  Missing, duplicate, malformed, and absent connections all fail
# before the review patch is pushed.
for closing_ref_mode in missing duplicate malformed absent wrong-repo; do
  prepare_review_thread_case "review-closing-reference-${closing_ref_mode}" '[]'
  export RPM_TEST_CLOSING_REF_MODE="$closing_ref_mode"
  case "$closing_ref_mode" in
    missing) closing_needle=closing-issue-binding-missing ;;
    duplicate) closing_needle=closing-reference-duplicate ;;
    malformed|absent|wrong-repo) closing_needle=closing-reference-response-invalid ;;
  esac
  expect_failure "review-closing-reference-${closing_ref_mode}" "$closing_needle" \
    run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id "review-closing-reference-${closing_ref_mode}"
  [ ! -s "$push_log" ] || fail "${closing_ref_mode} closing-reference attack reached push"
  unset RPM_TEST_CLOSING_REF_MODE
done

# The connection is paginated.  The expected issue appears only on its second
# page and must still be found before any review mutation.
prepare_review_thread_case review-closing-reference-pagination '[]'
export RPM_TEST_CLOSING_REF_MODE=pagination
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-closing-reference-pagination)" || fail "review closing-reference pagination failed: $output"
assert_contains "$output" '"status":"published"'
unset RPM_TEST_CLOSING_REF_MODE
pass "review-closing-reference-pagination"

# The no-work awaiting path uses the same source-of-truth binding before its
# issue-label transition.
prepare_review_thread_case review-no-work-closing-reference '[]'
: >"$patch_file"
jq '.status = "no-work" | .actionable_findings_remaining = false | .correction_label = null | .next_state = "awaiting-merge"' "$result_file" >"${result_file}.next"
mv -- "${result_file}.next" "$result_file"
export RPM_TEST_CLOSING_REF_MODE=missing
expect_failure "review-no-work-closing-reference-required" 'closing-issue-binding-missing' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-no-work-closing-reference
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "no-work closing-reference failure changed issue state"
unset RPM_TEST_CLOSING_REF_MODE

# A claim from another pull request is also rejected before the patch is
# applied.  Repository and PR identity are checked independently.
prepare_review_thread_case review-thread-pr-mismatch
export RPM_TEST_THREAD_PR=8
expect_failure "review-thread-pr-number-mismatch" 'review-thread-not-bound-or-already-resolved' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-pr-mismatch
[ ! -s "$push_log" ] || fail "wrong PR review claim reached push"
[ ! -s "$resolve_count_file" ] || fail "wrong PR review claim reached resolve"
unset RPM_TEST_THREAD_PR

# A result cannot claim a thread that is already resolved on the live PR.
prepare_review_thread_case review-thread-already-resolved
printf '%s\n' PRRT_test_1 >"$thread_state_file"
expect_failure "review-thread-already-resolved" 'review-thread-not-bound-or-already-resolved' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-already-resolved
[ ! -s "$push_log" ] || fail "already resolved review claim reached push"
[ ! -s "$resolve_count_file" ] || fail "already resolved review claim reached resolve"

# A review patch always returns to review-pending.  It cannot skip the
# review-state transition and directly request awaiting-merge.
prepare_review_thread_case review-patch-awaiting-state '[]'
jq '.next_state = "awaiting-merge"' "$result_file" >"${result_file}.next"
mv -- "${result_file}.next" "$result_file"
expect_failure "review-patch-cannot-await-merge" 'invalid-result-integrity' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-patch-awaiting-state
[ ! -s "$push_log" ] || fail "review patch awaiting-state reached push"

# Every claimed thread is checked before applying or pushing the patch.  Each
# malformed or untrusted claim therefore causes zero resolve mutations.
for thread_mode in wrong-actor reply-actor wrong-path wrong-line stale-commit outdated wrong-side; do
  prepare_review_thread_case "review-thread-${thread_mode}"
  export RPM_TEST_THREAD_MODE="$thread_mode"
  expect_failure "review-thread-${thread_mode}-rejected" 'review-thread-not-bound-or-already-resolved' \
    run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id "review-thread-${thread_mode}"
  [ ! -s "$push_log" ] || fail "${thread_mode} review claim reached push"
  [ ! -s "$resolve_count_file" ] || fail "${thread_mode} review claim reached resolve"
  unset RPM_TEST_THREAD_MODE
done

# One invalid claim blocks the whole set, including a valid claim listed first.
prepare_review_thread_case review-thread-one-invalid ' ["PRRT_test_1", "PRRT_test_2"] '
export RPM_TEST_SECOND_THREAD_MODE=wrong-path
expect_failure "review-thread-invalid-set-rejected" 'review-thread-not-bound-or-already-resolved' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-one-invalid
[ ! -s "$push_log" ] || fail "invalid thread set reached push"
[ ! -s "$resolve_count_file" ] || fail "invalid thread set reached resolve"
unset RPM_TEST_SECOND_THREAD_MODE

# All comment pages are included in the claim.  A trusted reply on a later
# page remains valid and is resolved exactly once.
prepare_review_thread_case review-thread-comment-pagination
export RPM_TEST_THREAD_MODE=comment-pagination
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-comment-pagination)" || fail "comment pagination review failed: $output"
assert_contains "$output" '"status":"published"'
[ "$(<"$resolve_count_file")" = 1 ] || fail "comment pagination resolved unexpected count"
unset RPM_TEST_THREAD_MODE
pass "review-thread-comment-pagination"

# A head race introduced by the resolve mutation is detected immediately
# afterward, so the publisher never advances the issue lifecycle.
prepare_review_thread_case review-thread-after-resolve-head-race
export RPM_TEST_RESOLVE_HEAD_RACE=true
expect_failure "review-thread-after-resolve-head-race" 'review-thread-after-resolve-pr-head-race' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-thread-after-resolve-head-race
[ "$(<"$resolve_count_file")" = 1 ] || fail "after-resolve head race did not exercise one resolve"
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "after-resolve head race changed issue state"
unset RPM_TEST_RESOLVE_HEAD_RACE

# A no-work handoff has no thread IDs and checks the complete live inventory.
# An unresolved thread on a later GraphQL page keeps the issue review-pending.
prepare_review_thread_case review-no-work-live-unresolved '[]'
: >"$patch_file"
jq '.status = "no-work" | .actionable_findings_remaining = false | .correction_label = null | .next_state = "awaiting-merge"' "$result_file" >"${result_file}.next"
mv -- "${result_file}.next" "$result_file"
export RPM_TEST_LIVE_PAGINATED=true
expect_failure "no-work-live-thread-inventory" 'no-work-unresolved-review-threads' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-no-work-live-unresolved
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "live unresolved no-work changed issue state"
[ ! -s "$resolve_count_file" ] || fail "live unresolved no-work reached resolve"
unset RPM_TEST_LIVE_PAGINATED

# A no-work result carrying thread IDs is incoherent and is rejected before
# the live GitHub inventory or any mutation.
prepare_review_thread_case review-no-work-thread-ids '[]'
: >"$patch_file"
jq '.status = "no-work" | .actionable_findings_remaining = false | .correction_label = null | .next_state = "awaiting-merge" | .resolved_thread_ids = ["PRRT_test_1"]' "$result_file" >"${result_file}.next"
mv -- "${result_file}.next" "$result_file"
expect_failure "no-work-thread-ids-rejected" 'invalid-result-integrity' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-no-work-thread-ids
[ ! -s "$resolve_count_file" ] || fail "no-work thread IDs reached resolve"

# Review no-work can advance to awaiting-merge only with no actionable
# findings. A follow-up source may refer to the issue or the PR.
repo="$(new_repo review-no-work-awaiting)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-no-work-awaiting"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-no-work-awaiting.patch"
result_file="${tmp_dir}/review-no-work-awaiting.json"
: >"$patch_file"
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha" no-work awaiting-merge false ""
add_followup_to_result "$result_file" 'Review follow-up' issue:42 'A separate review finding is tracked here.'
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-no-work-awaiting)" || fail "review no-work awaiting failed: $output"
assert_contains "$output" '"reason":"review-no-code-change"'
jq -e '.issues[0].labels == ["agent:awaiting-merge","kind:feature"] and ([.issues[] | select((.labels // []) | index("process:agent-followup") != null)] | length) == 1' "$gh_state_file" >/dev/null || fail "review no-work awaiting state mismatch"
[ ! -s "$push_log" ] || fail "review no-work awaiting pushed code"
pass "review-no-work-awaiting-with-issue-followup"

# The awaiting-merge lifecycle write re-reads the PR head immediately before
# changing the issue label.  A head change at that point leaves the issue in
# review-pending and fails closed.
repo="$(new_repo review-awaiting-head-race)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-awaiting-head-race"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-awaiting-head-race.patch"
result_file="${tmp_dir}/review-awaiting-head-race.json"
: >"$patch_file"
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha" no-work awaiting-merge false ""
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
export RPM_TEST_AWAITING_HEAD_RACE=true
expect_failure "awaiting-merge-head-race-fails-closed" 'awaiting-merge-pr-head-mismatch' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-awaiting-head-race
jq -e '.issues[0].labels == ["agent:review-pending","kind:feature"]' "$gh_state_file" >/dev/null || fail "awaiting head race changed issue lifecycle"
unset RPM_TEST_AWAITING_HEAD_RACE

# An unchanged no-work result cannot carry thread or follow-up side effects.
repo="$(new_repo review-no-work-unchanged)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-no-work-unchanged"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-no-work-unchanged.patch"
result_file="${tmp_dir}/review-no-work-unchanged.json"
: >"$patch_file"
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha" no-work unchanged false ""
add_followup_to_result "$result_file" 'Invalid unchanged follow-up' pr:7 'This must not be published on unchanged.'
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
expect_failure "unchanged-no-work-side-effects-rejected" 'invalid-result-integrity' \
  run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-no-work-unchanged
[ ! -s "$push_log" ] || fail "unchanged no-work reached push"

# Blocked review handoffs are also idempotent and may be retried after the
# issue has already reached the blocked lifecycle state.
repo="$(new_repo review-blocked-repeat)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
branch="feat/issue-42-codex-cloud-review-blocked-repeat"
"$real_git" -C "$repo" switch -q -c "$branch"
printf 'review base\n' >"$repo/src/app.txt"
"$real_git" -C "$repo" add src/app.txt
"$real_git" -C "$repo" commit -qm 'review base'
head_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/review-blocked-repeat.patch"
result_file="${tmp_dir}/review-blocked-repeat.json"
: >"$patch_file"
write_review_state "$base_sha" "$head_sha" "$branch"
printf '%s\n' "$head_sha" >"$remote_head_file"
write_review_result "$result_file" "$base_sha" "$head_sha" blocked blocked false ""
reset_fake
printf '%s\n' "$head_sha" >"$remote_head_file"
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-blocked-repeat)" || fail "review blocked handoff failed: $output"
output="$(run_publisher "$repo" --mode review --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --expected-head-sha "$head_sha" --expected-pr 7 --expected-head-ref "$branch" --run-id review-blocked-repeat)" || fail "review blocked repeat failed: $output"
jq -e '.issues[0].labels == ["agent:blocked","kind:feature"] and (.issues[0].comments | length) == 1' "$gh_state_file" >/dev/null || fail "review blocked repeat was not idempotent"
[ ! -s "$push_log" ] || fail "review blocked handoff pushed code"
pass "review-blocked-transition-idempotent"

# The protected-path parser also rejects a traversal header and a symlink mode
# even when the result envelope itself is valid.
repo="$(new_repo issue-malformed-patch)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-malformed.patch"
result_file="${tmp_dir}/issue-malformed.json"
cat >"$patch_file" <<'PATCH'
diff --git a/../escape b/../escape
index 1111111..2222222 100644
--- a/../escape
+++ b/../escape
@@ -1 +1 @@
-old
+new
PATCH
write_issue_state 42 '["agent:claimed"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
expect_failure "traversal-path-defense-in-depth" 'patch-traversal' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-malformed
[ ! -s "$push_log" ] || fail "traversal patch reached push"

repo="$(new_repo issue-symlink-mode)"
base_sha="$($real_git -C "$repo" rev-parse HEAD)"
patch_file="${tmp_dir}/issue-symlink.patch"
result_file="${tmp_dir}/issue-symlink.json"
cat >"$patch_file" <<'PATCH'
diff --git a/src/link b/src/link
new file mode 120000
index 0000000..1111111
--- /dev/null
+++ b/src/link
@@ -0,0 +1 @@
+target
PATCH
write_issue_state 42 '["agent:claimed"]'
write_issue_result "$result_file" "$base_sha"
reset_fake
expect_failure "symlink-mode-defense-in-depth" 'symlink-or-submodule-mode' \
  run_publisher "$repo" --mode issue --result "$result_file" --patch "$patch_file" --expected-base-sha "$base_sha" --run-id issue-symlink-mode
[ ! -s "$push_log" ] || fail "symlink patch reached push"

bash -n "$publisher" || fail "publisher syntax"
bash -n "${BASH_SOURCE[0]}" || fail "test syntax"
pass "publisher-and-test-syntax"
