#!/usr/bin/env bash
set -euo pipefail

# Non-network regression tests for safe-direct-merge.sh. The temporary repo,
# collector, gh, and git commands make every scenario deterministic.
repo_root="$(git rev-parse --show-toplevel)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mock_repo="${tmp_dir}/repo"
mock_bin="${tmp_dir}/bin"
mock_worktree="${tmp_dir}/pr-worktree"
mkdir -p "${mock_repo}/scripts" "${mock_repo}/.agents/workflows" "${mock_bin}" "${mock_worktree}"
cp "${repo_root}/scripts/safe-direct-merge.sh" "${mock_repo}/scripts/safe-direct-merge.sh"
cp "${repo_root}/.agents/workflows/backlog-policy.json" \
  "${mock_repo}/.agents/workflows/backlog-policy.json"
chmod +x "${mock_repo}/scripts/safe-direct-merge.sh"

cat > "${mock_repo}/scripts/collect-pr-review-context.sh" <<'MOCK_COLLECTOR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${COLLECTOR_LOG}"
if [ "${MOCK_COLLECTOR_SCENARIO:-ok}" = "unsupported" ]; then
  printf 'collector: GraphQL review lookup unavailable\n' >&2
  exit 1
fi
if [ "${MOCK_COLLECTOR_SCENARIO:-ok}" = "malformed" ]; then
  printf '{"reviewThreads":'
  exit 0
fi
if [ "${MOCK_COLLECTOR_SCENARIO:-ok}" = "identity-mismatch" ]; then
  printf '{"pullRequest":{"number":2,"url":"https://github.com/owner/repo/pull/2"},"reviewThreads":[]}\n'
  exit 0
fi
if [ "${MOCK_COLLECTOR_SCENARIO:-ok}" = "review-race" ]; then
  count=0
  if [ -f "${REVIEW_CALL_LOG}" ]; then count="$(cat "${REVIEW_CALL_LOG}")"; fi
  count=$((count + 1))
  printf '%s\n' "$count" >"${REVIEW_CALL_LOG}"
  if [ "$count" -gt 1 ]; then
    printf '{"pullRequest":{"number":1,"url":"https://github.com/owner/repo/pull/1"},"reviewThreads":[{"isResolved":false}]}\n'
  else
    printf '{"pullRequest":{"number":1,"url":"https://github.com/owner/repo/pull/1"},"reviewThreads":[]}\n'
  fi
  exit 0
fi
printf '{"pullRequest":{"number":1,"url":"https://github.com/owner/repo/pull/1"},"reviewThreads":[]}\n'
MOCK_COLLECTOR
chmod +x "${mock_repo}/scripts/collect-pr-review-context.sh"
trusted_source="${tmp_dir}/trusted-source"
mkdir -p "${trusted_source}/scripts" "${trusted_source}/.agents/workflows"
trusted_source="$(cd "${trusted_source}" && pwd -P)"
cp "${mock_repo}/scripts/safe-direct-merge.sh" "${trusted_source}/scripts/safe-direct-merge.sh"
cp "${mock_repo}/scripts/collect-pr-review-context.sh" \
  "${trusted_source}/scripts/collect-pr-review-context.sh"
cp "${mock_repo}/.agents/workflows/backlog-policy.json" \
  "${trusted_source}/.agents/workflows/backlog-policy.json"
chmod +x "${trusted_source}/scripts/safe-direct-merge.sh" \
  "${trusted_source}/scripts/collect-pr-review-context.sh"
trusted_commit_source="${tmp_dir}/trusted-commit-source"
mkdir -p "${trusted_commit_source}/scripts" "${trusted_commit_source}/.agents/workflows"
cp "${trusted_source}/scripts/safe-direct-merge.sh" \
  "${trusted_commit_source}/scripts/safe-direct-merge.sh"
cp "${trusted_source}/scripts/collect-pr-review-context.sh" \
  "${trusted_commit_source}/scripts/collect-pr-review-context.sh"
cp "${trusted_source}/.agents/workflows/backlog-policy.json" \
  "${trusted_commit_source}/.agents/workflows/backlog-policy.json"
trusted_main_sha='1111111111111111111111111111111111111111'
trusted_script_hash="$(git hash-object "${mock_repo}/scripts/safe-direct-merge.sh")"
trusted_policy_hash="$(git hash-object "${mock_repo}/.agents/workflows/backlog-policy.json")"
trusted_collector_hash="$(git hash-object "${mock_repo}/scripts/collect-pr-review-context.sh")"

cat > "${mock_bin}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$*" == *"reviewThreads"* ]]; then
  printf 'gh: unsupported reviewThreads field\n' >&2
  exit 1
fi
case "$*" in
  *"api -X GET repos/owner/repo/commits/main"*)
    if [ "${MOCK_GIT_REAL:-false}" = "true" ]; then
      printf '%s\n' "${ACTUAL_TRUSTED_SHA}"
    else
      printf '%s\n' "${TRUSTED_MAIN_SHA}"
    fi
    ;;
  *"branches/main/protection"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "unprotected" ] \
      || [ "${MOCK_GH_SCENARIO:-ok}" = "ruleset" ] \
      || [ "${MOCK_GH_SCENARIO:-ok}" = "ruleset-bypass" ]; then
      exit 1
    fi
    contexts='["metadata","verify"]'
    conversation=true
    [ "${MOCK_GH_SCENARIO:-ok}" = "wrong-protection-check" ] && contexts='["metadata"]'
    [ "${MOCK_GH_SCENARIO:-ok}" = "no-conversation-resolution" ] && conversation=false
    printf '{"required_status_checks":{"contexts":%s},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":1},"required_conversation_resolution":{"enabled":%s}}\n' \
      "$contexts" "$conversation"
    ;;
  *"rules/branches/main"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "ruleset" ] \
      || [ "${MOCK_GH_SCENARIO:-ok}" = "ruleset-bypass" ]; then
      printf '%s\n' '[{"type":"required_status_checks","ruleset_id":42,"parameters":{"required_status_checks":[{"context":"metadata"},{"context":"verify"}]}},{"type":"pull_request","ruleset_id":42,"parameters":{"required_review_thread_resolution":true}}]'
    elif [ "${MOCK_GH_SCENARIO:-ok}" = "merge-queue" ]; then
      printf '%s\n' '[{"type":"merge_queue","ruleset_id":77,"parameters":{}}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  *"api -X GET repos/owner/repo/rulesets/42"*)
    bypass='[]'
    [ "${MOCK_GH_SCENARIO:-ok}" = "ruleset-bypass" ] \
      && bypass='[{"actor_id":1,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
    printf '{"enforcement":"active","bypass_actors":%s}\n' "$bypass"
    ;;
  *"--json number,url,state,headRefOid"*)
    merged_state='MERGED'
    [ "${MOCK_GH_SCENARIO:-ok}" = "merge-not-completed" ] && merged_state='OPEN'
    printf '{"number":1,"url":"https://github.com/owner/repo/pull/1","state":"%s","headRefOid":"0123456789abcdef0123456789abcdef01234567"}\n' "$merged_state"
    ;;
  *"--json number,url,state,isDraft,mergeable,mergeStateStatus,baseRefName,headRefName,isCrossRepository,headRefOid"*)
    oid='0123456789abcdef0123456789abcdef01234567'
    cross_repository='false'
    pr_url='https://github.com/owner/repo/pull/1'
    base_branch='main'
    head_branch='feature/mock'
    [ "${MOCK_GH_SCENARIO:-ok}" = "mixed-url" ] && pr_url='https://GITHUB.com/OWNER/REPO/pull/1'
    [ "${MOCK_GH_SCENARIO:-ok}" = "cross-repo" ] && cross_repository='true'
    [ "${MOCK_GH_SCENARIO:-ok}" = "non-main-base" ] && base_branch='develop'
    [ "${MOCK_GH_SCENARIO:-ok}" = "hash-branch" ] && head_branch='feature#probe'
    if [ "${MOCK_GH_SCENARIO:-ok}" = "head-race" ]; then
      count=0
      if [ -f "${HEAD_OID_LOG}" ]; then count="$(cat "${HEAD_OID_LOG}")"; fi
      count=$((count + 1))
      printf '%s\n' "$count" >"${HEAD_OID_LOG}"
      [ "$count" -gt 1 ] && oid='fedcba9876543210fedcba9876543210fedcba98'
    fi
    printf '{"number":1,"url":"%s","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"%s","headRefName":"%s","isCrossRepository":%s,"headRefOid":"%s"}\n' "$pr_url" "$base_branch" "$head_branch" "$cross_repository" "$oid"
    ;;
  *"--json headRefOid"*)
    oid='0123456789abcdef0123456789abcdef01234567'
    if [ "${MOCK_GH_SCENARIO:-ok}" = "head-race" ]; then
      count=0
      if [ -f "${HEAD_OID_LOG}" ]; then count="$(cat "${HEAD_OID_LOG}")"; fi
      count=$((count + 1))
      printf '%s\n' "$count" >"${HEAD_OID_LOG}"
      [ "$count" -gt 1 ] && oid='fedcba9876543210fedcba9876543210fedcba98'
    fi
    printf '%s\n' "$oid"
    ;;
  *"--json baseRefName"*)
    base_branch='main'
    [ "${MOCK_GH_SCENARIO:-ok}" = "base-race" ] && base_branch='develop'
    printf '%s\n' "$base_branch"
    ;;
  *"--json number,url,state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus"*)
    final_url='https://github.com/owner/repo/pull/1'
    final_state='OPEN'
    final_draft='false'
    final_base='main'
    final_head='0123456789abcdef0123456789abcdef01234567'
    final_mergeable='MERGEABLE'
    final_merge_state='CLEAN'
    case "${MOCK_GH_SCENARIO:-ok}" in
      final-state-race) final_state='CLOSED' ;;
      final-draft-race) final_draft='true' ;;
      final-base-race) final_base='develop' ;;
      final-head-race) final_head='fedcba9876543210fedcba9876543210fedcba98' ;;
      final-conflicting-race) final_mergeable='CONFLICTING' ;;
      final-blocked-race) final_merge_state='BLOCKED' ;;
      final-unknown-race) final_mergeable='UNKNOWN' ;;
    esac
    printf '{"number":1,"url":"%s","state":"%s","isDraft":%s,"baseRefName":"%s","headRefOid":"%s","mergeable":"%s","mergeStateStatus":"%s"}\n' \
      "$final_url" "$final_state" "$final_draft" "$final_base" "$final_head" \
      "$final_mergeable" "$final_merge_state"
    ;;
  *"pr checks"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "check-race" ]; then
      count=0
      if [ -f "${CHECK_CALL_LOG}" ]; then count="$(cat "${CHECK_CALL_LOG}")"; fi
      count=$((count + 1))
      printf '%s\n' "$count" >"${CHECK_CALL_LOG}"
      if [ "$count" -gt 1 ]; then
        printf '[{"name":"metadata","bucket":"fail"},{"name":"verify","bucket":"pass"}]\n'
      else
        printf '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]\n'
      fi
    elif [ "${MOCK_GH_SCENARIO:-ok}" = "duplicate-mixed" ]; then
      printf '[{"name":"metadata","bucket":"pass"},{"name":"metadata","bucket":"fail"},{"name":"verify","bucket":"pass"}]\n'
    elif [ "${MOCK_GH_SCENARIO:-ok}" = "unrelated-pending" ]; then
      printf '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"},{"name":"optional","bucket":"pending"}]\n'
      exit 8
    else
      printf '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]\n'
    fi
    ;;
  *"pr merge"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "base-race" ]; then
      printf 'develop\n' >"${BASE_RACE_LOG}"
    fi
    printf 'merged\n'
    ;;
  *) printf 'gh mock: unsupported command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK_GH
chmod +x "${mock_bin}/gh"

cat > "${mock_bin}/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MOCK_GIT_REAL:-false}" = "true" ]; then
  exec "${REAL_GIT}" "$@"
fi
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "core.hooksPath=/dev/null" ]; then
  shift 2
fi
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  printf '%s\n' "${MOCK_REPO}"
  exit 0
fi
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--path-format=absolute" ] \
  && [ "${3:-}" = "--git-common-dir" ]; then
  printf '%s\n' "${MOCK_COMMON_DIR}"
  exit 0
fi
if [ "${1:-}" = "config" ] && [ "${2:-}" = "--local" ] && [ "${3:-}" = "--path" ] \
  && [ "${4:-}" = "--get" ] && [ "${5:-}" = "rpm.safeDirectMergeTrustedCheckout" ]; then
  printf '%s\n' "${TRUSTED_CHECKOUT}"
  exit 0
fi
if [ "${1:-}" = "hash-object" ]; then
  if [ "${2:-}" = "--stdin" ]; then
    exec "${REAL_GIT}" hash-object --stdin
  fi
  case "$2" in
    scripts/safe-direct-merge.sh)
      printf '%s\n' "${TRUSTED_SCRIPT_HASH}"
      ;;
    .agents/workflows/backlog-policy.json)
      printf '%s\n' "${TRUSTED_POLICY_HASH}"
      ;;
    scripts/collect-pr-review-context.sh)
      printf '%s\n' "${TRUSTED_COLLECTOR_HASH}"
      ;;
    *scripts/safe-direct-merge.sh)
      if [ "${MOCK_GIT_SCENARIO:-}" = "launcher-working-tree-mismatch" ] \
        && [ "${2:-}" = "${MOCK_LAUNCHER_PATH:-}" ]; then
        printf 'deadbeef\n'
      elif [ "${MOCK_GIT_SCENARIO:-}" = "materialized-script-mismatch" ] \
        && [ "${2:-}" != "${MOCK_LAUNCHER_PATH:-}" ]; then
        printf 'deadbeef\n'
      else
        printf '%s\n' "${TRUSTED_SCRIPT_HASH}"
      fi
      ;;
    *.agents/workflows/backlog-policy.json)
      [ "${MOCK_GIT_SCENARIO:-}" = "materialized-policy-mismatch" ] \
        && printf 'deadbeef\n' || printf '%s\n' "${TRUSTED_POLICY_HASH}"
      ;;
    *scripts/collect-pr-review-context.sh)
      if [ "${MOCK_GIT_SCENARIO:-}" = "materialized-collector-mismatch" ]; then
        printf 'deadbeef\n'
      elif [ "${MOCK_GIT_SCENARIO:-}" = "post-verify-collector-tamper" ]; then
        printf '\nexit 98\n' >>"$2"
        printf '%s\n' "${TRUSTED_COLLECTOR_HASH}"
      else
        printf '%s\n' "${TRUSTED_COLLECTOR_HASH}"
      fi
      ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "${1:-}" = "-C" ]; then
  worktree="$2"
  shift 2
  while [ "${1:-}" = "-c" ]; do
    shift 2
  done
  if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
    printf '%s\n' "${worktree}"
    exit 0
  fi
  if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--path-format=absolute" ] \
    && [ "${3:-}" = "--git-common-dir" ]; then
    printf '%s\n' "${MOCK_COMMON_DIR}"
    exit 0
  fi
  if [ "${1:-}" = "symbolic-ref" ] && [ "${2:-}" = "--short" ] && [ "${3:-}" = "HEAD" ]; then
    printf 'main\n'
    exit 0
  fi
  if [ "${1:-}" = "config" ] && [ "${2:-}" = "--local" ] && [ "${3:-}" = "--path" ] \
    && [ "${4:-}" = "--get" ] && [ "${5:-}" = "rpm.safeDirectMergeTrustedCheckout" ]; then
    printf '%s\n' "${TRUSTED_CHECKOUT}"
    exit 0
  fi
  if [ "${1:-}" = "config" ] && [ "${2:-}" = "--local" ] && [ "${3:-}" = "--get" ] \
    && [ "${4:-}" = "remote.origin.url" ]; then
    printf 'https://github.com/owner/repo.git\n'
    exit 0
  fi
  if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "HEAD" ]; then
    printf '%s\n' "${TRUSTED_MAIN_SHA}"
    exit 0
  fi
  if [ "${1:-}" = "cat-file" ] && [ "${2:-}" = "-e" ]; then
    exit 0
  fi
  if [ "${1:-}" = "rev-parse" ] && [[ "${2:-}" == "${TRUSTED_MAIN_SHA}:"* ]]; then
    case "${2#*:}" in
      scripts/safe-direct-merge.sh) printf '%s\n' "${TRUSTED_SCRIPT_HASH}" ;;
      .agents/workflows/backlog-policy.json) printf '%s\n' "${TRUSTED_POLICY_HASH}" ;;
      scripts/collect-pr-review-context.sh) printf '%s\n' "${TRUSTED_COLLECTOR_HASH}" ;;
      *) exit 1 ;;
    esac
    exit 0
  fi
  if [ "${1:-}" = "show" ] && [[ "${2:-}" == "${TRUSTED_MAIN_SHA}:"* ]]; then
    trusted_path="${2#*:}"
    cat "${TRUSTED_COMMIT_SOURCE:-${TRUSTED_SOURCE}}/${trusted_path}"
    exit 0
  fi
  if [ "${1:-}" = "branch" ] && [ "${2:-}" = "--show-current" ]; then
    if [ "${MOCK_GIT_SCENARIO:-}" = "branch-failure" ]; then
      exit 1
    fi
    printf 'feature/mock\n'
    exit 0
  fi
  if [ "${1:-}" = "status" ]; then
    if [ "$worktree" = "${TRUSTED_CHECKOUT}" ]; then
      [ -z "${MOCK_TRUSTED_CHECKOUT_STATUS:-}" ] \
        || printf '%s\n' "${MOCK_TRUSTED_CHECKOUT_STATUS}"
    elif [ "${MOCK_GIT_SCENARIO:-}" = "concurrent-ignored" ] \
      && [ "$worktree" = "${MOCK_CONCURRENT_WORKTREE:-}" ]; then
      printf 'late ignored content\n' >"$worktree/late-ignored"
    elif [ -n "${MOCK_WORKTREE_STATUS:-}" ]; then
      printf '%s\n' "${MOCK_WORKTREE_STATUS}"
    fi
    exit 0
  fi
  printf 'git mock: unsupported -C command in %s\n' "${worktree}" >&2
  exit 1
fi
if [ "${1:-}" = "init" ] && [ "${2:-}" = "--bare" ]; then
  exit 0
fi
if [[ "${1:-}" == --git-dir=* ]]; then
  shift
  while [ "${1:-}" = "-c" ]; do
    shift 2
  done
  if [ "${1:-}" = "ls-remote" ]; then
    remote_ref="${!#}"
    case "${MOCK_REMOTE_BRANCH_SCENARIO:-matching}" in
      absent) exit 2 ;;
      network-error) exit 128 ;;
      advanced)
        printf 'fedcba9876543210fedcba9876543210fedcba98\t%s\n' "$remote_ref"
        ;;
      push-race)
        if [ -f "${REMOTE_RACE_LOG}" ]; then
          printf 'fedcba9876543210fedcba9876543210fedcba98\t%s\n' "$remote_ref"
        else
          printf '%s\t%s\n' "${EXPECTED_HEAD_OID}" "$remote_ref"
        fi
        ;;
      *) printf '%s\t%s\n' "${EXPECTED_HEAD_OID}" "$remote_ref" ;;
    esac
    exit 0
  fi
  if [ "${1:-}" = "push" ]; then
    printf '%s\n' "$*" >>"${PUSH_LOG}"
    if [ "${MOCK_REMOTE_BRANCH_SCENARIO:-matching}" = "push-race" ]; then
      : >"${REMOTE_RACE_LOG}"
      exit 1
    fi
    exit 0
  fi
  printf 'git mock: unsupported isolated transport command: %s\n' "$*" >&2
  exit 1
fi
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "list" ]; then
  if [ "${MOCK_GIT_SCENARIO:-}" = "inventory-failure" ]; then
    exit 1
  fi
  if [ -n "${MOCK_WORKTREE:-}" ]; then
    printf 'worktree %s\n' "${MOCK_WORKTREE}"
    printf 'HEAD deadbeef\n'
    printf 'branch refs/heads/feature/mock\n'
  fi
  if [ -n "${MOCK_CURRENT_WORKTREE:-}" ]; then
    printf 'worktree %s\n' "${MOCK_CURRENT_WORKTREE}"
    printf 'HEAD deadbeef\n'
    printf 'branch refs/heads/feature/mock\n'
  fi
  exit 0
fi
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "remove" ]; then
  printf '%s\n' "$*" >> "${WORKTREE_LOG}"
  if [ "${MOCK_GIT_SCENARIO:-}" = "remove-failure" ]; then
    exit 1
  fi
  exit 0
fi
if [ "${1:-}" = "show-ref" ] && [ "${2:-}" = "--verify" ] && [ "${3:-}" = "--hash" ]; then
  printf '%s\n' "$*" >>"${LOCAL_REF_LOG}"
  exit 99
fi
if [ "${1:-}" = "update-ref" ] && [ "${2:-}" = "-d" ]; then
  printf '%s\n' "$*" >>"${LOCAL_REF_LOG}"
  exit 99
fi
if [ "${1:-}" = "branch" ]; then
  exit 0
fi
printf 'git mock: unsupported command: %s\n' "$*" >&2
exit 1
MOCK_GIT
chmod +x "${mock_bin}/git"

safe_merge="${trusted_source}/scripts/safe-direct-merge.sh"
system_path="${PATH}"
export MOCK_REPO="${mock_repo}" GH_LOG="${tmp_dir}/gh.log" \
  COLLECTOR_LOG="${tmp_dir}/collector.log" WORKTREE_LOG="${tmp_dir}/worktree.log" \
  HEAD_OID_LOG="${tmp_dir}/head-oid.log" REVIEW_CALL_LOG="${tmp_dir}/review.log" \
  CHECK_CALL_LOG="${tmp_dir}/check.log" PUSH_LOG="${tmp_dir}/push.log" \
  LOCAL_REF_LOG="${tmp_dir}/local-ref.log" REMOTE_RACE_LOG="${tmp_dir}/remote-race.log" \
  BASE_RACE_LOG="${tmp_dir}/base-race.log" \
  EXPECTED_HEAD_OID="0123456789abcdef0123456789abcdef01234567" \
  TRUSTED_CHECKOUT="${trusted_source}" MOCK_COMMON_DIR="${tmp_dir}/common.git" \
  TRUSTED_COMMIT_SOURCE="${trusted_commit_source}" \
  MOCK_LAUNCHER_PATH="${trusted_source}/scripts/safe-direct-merge.sh" \
  RPM_SAFE_DIRECT_MERGE_BOOTSTRAPPED=1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -Eq 'git[[:space:]]+worktree[[:space:]]+remove' \
  "${repo_root}/scripts/safe-direct-merge.sh"; then
  fail 'worktree-removal-boundary: automatic worktree removal is present'
fi
if grep -Eq 'update-ref[[:space:]]+-d|git[[:space:]]+branch[[:space:]]+-D' \
  "${repo_root}/scripts/safe-direct-merge.sh"; then
  fail 'local-branch-boundary: automatic local branch deletion is present'
fi
if grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge|remote_transport[[:space:]]+push|git[[:space:]].*push|gh[[:space:]]+api.*-X[[:space:]]+DELETE' \
  "${repo_root}/scripts/safe-direct-merge.sh"; then
  fail 'mutation-boundary: direct merge or remote ref mutation is present'
fi

# Build a real temporary repository and worktree for the ignored-file case.
# The fake git command delegates to the real binary for that case, while gh
# and the review collector remain deterministic and offline.
real_git="$(command -v git)"
actual_repo="${tmp_dir}/actual-repo"
actual_worktree="${tmp_dir}/actual-worktree"
mkdir -p "${actual_repo}/scripts" "${actual_repo}/.agents/workflows"
cp "${repo_root}/scripts/safe-direct-merge.sh" "${actual_repo}/scripts/safe-direct-merge.sh"
cp "${mock_repo}/scripts/collect-pr-review-context.sh" \
  "${actual_repo}/scripts/collect-pr-review-context.sh"
cp "${repo_root}/.agents/workflows/backlog-policy.json" \
  "${actual_repo}/.agents/workflows/backlog-policy.json"
printf 'ignored-file\n' > "${actual_repo}/.gitignore"
printf 'tracked-file\n' > "${actual_repo}/tracked.txt"
git -C "${actual_repo}" init -q -b main
git -C "${actual_repo}" config user.email test@example.invalid
git -C "${actual_repo}" config user.name 'safe-direct-merge test'
git -C "${actual_repo}" remote add origin https://github.com/owner/repo.git
git -C "${actual_repo}" config rpm.safeDirectMergeTrustedCheckout "${actual_repo}"
git -C "${actual_repo}" add .
git -C "${actual_repo}" commit -q -m 'test fixture'
git -C "${actual_repo}" worktree add -q -b feature/mock "${actual_worktree}"
printf 'generated content\n' > "${actual_worktree}/ignored-file"
actual_trusted_sha="$(git -C "${actual_repo}" rev-parse HEAD)"
hostile_hook_dir="${tmp_dir}/hostile-hooks"
hostile_hook_log="${tmp_dir}/hostile-hook.log"
mkdir -p "${hostile_hook_dir}"
printf '%s\n' '#!/usr/bin/env bash' 'printf "executed\\n" >"${HOSTILE_HOOK_LOG}"' \
  >"${hostile_hook_dir}/post-index-change"
chmod +x "${hostile_hook_dir}/post-index-change"
git -C "${actual_repo}" config core.hooksPath "${hostile_hook_dir}"
touch "${actual_repo}/tracked.txt"
export HOSTILE_HOOK_LOG="${hostile_hook_log}"
git -C "${actual_repo}" status --porcelain >/dev/null
if [ ! -e "${hostile_hook_log}" ]; then
  fail 'trusted-status-hook-fixture: hostile hook did not execute in the control case'
fi
rm -f "${hostile_hook_log}"
touch "${actual_repo}/tracked.txt"
export TRUSTED_MAIN_SHA="${trusted_main_sha}" ACTUAL_TRUSTED_SHA="${actual_trusted_sha}" \
  REAL_GIT="${real_git}" \
  TRUSTED_SOURCE="${trusted_source}" \
  TRUSTED_SCRIPT_HASH="${trusted_script_hash}" TRUSTED_POLICY_HASH="${trusted_policy_hash}" \
  TRUSTED_COLLECTOR_HASH="${trusted_collector_hash}" \
  LOCAL_SCRIPT_HASH="${trusted_script_hash}" LOCAL_POLICY_HASH="${trusted_policy_hash}" \
  LOCAL_COLLECTOR_HASH="${trusted_collector_hash}" PUSH_LOG="${tmp_dir}/push.log"

run_case() {
  local name="$1" expected_rc="$2" scenario="$3" collector_scenario="$4" dirty="$5"
  local output rc
  : > "${REVIEW_CALL_LOG}"
  : > "${CHECK_CALL_LOG}"
  : > "${GH_LOG}"
  : > "${COLLECTOR_LOG}"
  : > "${WORKTREE_LOG}"
  : > "${HEAD_OID_LOG}"
  : > "${LOCAL_REF_LOG}"
  : > "${PUSH_LOG}"
  rm -f "${REMOTE_RACE_LOG}"
  output="$(MOCK_GH_SCENARIO="${scenario}" MOCK_COLLECTOR_SCENARIO="${collector_scenario}" \
    MOCK_WORKTREE_STATUS="${dirty}" MOCK_WORKTREE="${MOCK_WORKTREE_CASE:-}" \
    PATH="${mock_bin}:${system_path}" "${safe_merge}" --dry-run 1 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "${rc}" -ne "${expected_rc}" ]; then
    printf '%s\n' "${output}" >&2
    fail "${name}: expected rc ${expected_rc}, got ${rc}"
  fi
  printf '%s\n' "${output}"
}

# Each launch materializes one immutable main revision. Multiple PRs are
# rejected before PR inspection so a later audit cannot inherit stale assets.
: > "${GH_LOG}"
set +e
multiple_pr_output="$(PATH="${mock_bin}:${system_path}" "${safe_merge}" --dry-run 1 2 2>&1)"
multiple_pr_rc=$?
set -e
if [ "${multiple_pr_rc}" -ne 2 ] \
  || ! grep -q 'one-pr-per-invocation' <<<"${multiple_pr_output}" \
  || grep -q 'pr view\|pr checks' "${GH_LOG}"; then
  printf '%s\n' "${multiple_pr_output}" >&2
  fail 'multiple-prs: stale trusted assets could reach a later PR'
fi

# The collector owns the paginated review-thread lookup. A collector failure
# blocks the merge, and gh must never receive the unsupported reviewThreads
# field used by the old implementation.
output="$(run_case unsupported-review-lookup 1 ok unsupported "" 2>&1)"
if ! grep -q 'review context collection failed' <<<"${output}"; then
  fail 'unsupported-review-lookup: collector failure was not fail-closed'
fi
if grep -q 'reviewThreads' "${GH_LOG}"; then
  fail 'unsupported-review-lookup: safe merge attempted gh reviewThreads lookup'
fi

set +e
allow_failure_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=unsupported MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" --allow-findings --dry-run 1 2>&1)"
allow_failure_rc=$?
set -e
if [ "${allow_failure_rc}" -ne 1 ] || ! grep -q 'review context collection failed' <<<"${allow_failure_output}"; then
  printf '%s\n' "${allow_failure_output}" >&2
  fail 'allow-findings: collector failure was incorrectly overridden'
fi

output="$(run_case malformed-review-context 1 ok malformed "" 2>&1)"
if ! grep -q 'review context payload is invalid' <<<"${output}"; then
  fail 'malformed-review-context: invalid payload was not fail-closed'
fi

output="$(run_case identity-mismatch-review-context 1 ok identity-mismatch "" 2>&1)"
if ! grep -q 'review context payload is invalid' <<<"${output}"; then
  fail 'identity-mismatch-review-context: mismatched PR identity was not fail-closed'
fi

output="$(run_case duplicate-mixed-check 1 duplicate-mixed ok "" 2>&1)"
if ! grep -q 'required checks failed: metadata=fail' <<<"${output}"; then
  fail 'duplicate-mixed-check: one failing duplicate did not block merge'
fi

MOCK_WORKTREE_CASE="${mock_worktree}"
output="$(run_case unrelated-pending-check 0 unrelated-pending ok "" 2>&1)"
unset MOCK_WORKTREE_CASE
if ! grep -q '(dry-run) gates satisfied' <<<"${output}"; then
  fail 'unrelated-pending-check: gh exit 8 blocked green policy checks'
fi

# A dirty worktree holding the PR branch is preserved and blocks the merge.
: > "${GH_LOG}"
: > "${COLLECTOR_LOG}"
: > "${WORKTREE_LOG}"
set +e
dirty_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  MOCK_WORKTREE_STATUS=' M user-file' "${safe_merge}" 1 2>&1)"
dirty_rc=$?
set -e
if [ "${dirty_rc}" -ne 1 ] || ! grep -q 'dirty worktree' <<<"${dirty_output}"; then
  printf '%s\n' "${dirty_output}" >&2
  fail 'dirty-worktree: dirty worktree did not block merge'
fi
if [ -s "${WORKTREE_LOG}" ]; then
  fail 'dirty-worktree: dirty worktree was removed'
fi

# Ignored files also make a worktree unsafe to remove. This uses the real
# temporary repository/worktree above so the result cannot be produced by a
# mock status string alone.
rm -f "${GH_LOG}" "${COLLECTOR_LOG}" "${WORKTREE_LOG}"
touch "${GH_LOG}" "${COLLECTOR_LOG}" "${WORKTREE_LOG}"
set +e
ignored_output="$(
  cd "${actual_repo}"
  PATH="${mock_bin}:${system_path}" MOCK_GIT_REAL=true REAL_GIT="${real_git}" \
    MOCK_GH_SCENARIO=ok MOCK_COLLECTOR_SCENARIO=ok \
    "${actual_repo}/scripts/safe-direct-merge.sh" 1 2>&1
)"
ignored_rc=$?
set -e
if [ "${ignored_rc}" -ne 1 ] || ! grep -q 'dirty worktree' <<<"${ignored_output}"; then
  printf '%s\n' "${ignored_output}" >&2
  fail 'ignored-worktree: ignored file did not block merge'
fi
if [ -s "${WORKTREE_LOG}" ]; then
  fail 'ignored-worktree: worktree with ignored file was removed'
fi
if [ ! -f "${actual_worktree}/ignored-file" ] || [ ! -d "${actual_worktree}" ]; then
  fail 'ignored-worktree: ignored file or worktree was removed'
fi
if [ -e "${hostile_hook_log}" ]; then
  fail 'trusted-status-hook: repository-configured post-index-change hook executed'
fi

# Real Git worktrees can hide a modified launcher with either index flag.
# The launcher byte check must reject both cases before any PR lookup.
hidden_launcher_backup="${tmp_dir}/actual-launcher-original"
cp "${actual_repo}/scripts/safe-direct-merge.sh" "${hidden_launcher_backup}"
for hidden_index_flag in --assume-unchanged --skip-worktree; do
  git -C "${actual_repo}" update-index "${hidden_index_flag}" -- scripts/safe-direct-merge.sh
  printf '\n# hidden index-flag launcher mutation\n' \
    >>"${actual_repo}/scripts/safe-direct-merge.sh"
  if [ -n "$(git -C "${actual_repo}" status --porcelain --untracked-files=all)" ]; then
    fail "${hidden_index_flag}: Git exposed the hidden launcher mutation"
  fi
  set +e
  hidden_launcher_output="$(
    cd "${actual_repo}"
    PATH="${mock_bin}:${system_path}" MOCK_GIT_REAL=true REAL_GIT="${real_git}" \
      MOCK_GH_SCENARIO=ok MOCK_COLLECTOR_SCENARIO=ok \
      "${actual_repo}/scripts/safe-direct-merge.sh" --dry-run 1 2>&1
  )"
  hidden_launcher_rc=$?
  set -e
  git -C "${actual_repo}" update-index --no-assume-unchanged --no-skip-worktree -- \
    scripts/safe-direct-merge.sh
  cp "${hidden_launcher_backup}" "${actual_repo}/scripts/safe-direct-merge.sh"
  if [ "${hidden_launcher_rc}" -ne 2 ] \
    || ! grep -q 'untrusted-launcher-bytes' <<<"${hidden_launcher_output}"; then
    printf '%s\n' "${hidden_launcher_output}" >&2
    fail "${hidden_index_flag}: hidden launcher mutation was evaluated"
  fi
done

output="$(run_case cross-repository 1 cross-repo ok "" 2>&1)"
if ! grep -q 'cross-repository PRs' <<<"${output}"; then
  fail 'cross-repository: cross-repository PR was not rejected'
fi

output="$(run_case non-main-base 1 non-main-base ok "" 2>&1)"
if ! grep -q 'base branch develop is not protected main' <<<"${output}"; then
  fail 'non-main-base: protection for main was applied to another base branch'
fi

MOCK_WORKTREE_CASE="${mock_worktree}"
output="$(run_case normal-dry-run 0 ok ok "" 2>&1)"
unset MOCK_WORKTREE_CASE
if ! grep -q '(dry-run) gates satisfied for branch feature/mock' <<<"${output}"; then
  fail 'normal-dry-run: expected successful dry-run output'
fi

# The documented bootstrap evaluates the source read from the trusted commit,
# so a later working-tree launcher mutation cannot affect the audit.
trusted_bootstrap_source="$(cat "${trusted_commit_source}/scripts/safe-direct-merge.sh"; printf .)"
trusted_bootstrap_source="${trusted_bootstrap_source%.}"
bootstrap_launcher_backup="${tmp_dir}/bootstrap-launcher-original"
cp "${trusted_source}/scripts/safe-direct-merge.sh" "${bootstrap_launcher_backup}"
printf '\n# working-tree-only launcher mutation after bootstrap\n' \
  >>"${trusted_source}/scripts/safe-direct-merge.sh"
set +e
bootstrap_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  bash -c "${trusted_bootstrap_source}" "${safe_merge}" --dry-run 1 2>&1)"
bootstrap_rc=$?
set -e
cp "${bootstrap_launcher_backup}" "${trusted_source}/scripts/safe-direct-merge.sh"
if [ "${bootstrap_rc}" -ne 0 ] \
  || ! grep -q '(dry-run) gates satisfied' <<<"${bootstrap_output}"; then
  printf '%s\n' "${bootstrap_output}" >&2
  fail 'trusted-commit-bootstrap: working-tree launcher affected the audit'
fi

# URL references are accepted only when they name a PR in the current origin.
set +e
external_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="" "${safe_merge}" --dry-run \
  https://github.com/other/repo/pull/1 2>&1)"
external_rc=$?
set -e
if [ "${external_rc}" -ne 1 ] || ! grep -q 'does not match current origin' <<<"${external_output}"; then
  printf '%s\n' "${external_output}" >&2
  fail 'external-same-repository-url: URL repository was not rejected'
fi

set +e
mixed_input_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" --dry-run HTTPS://GITHUB.com/OWNER/REPO/pull/1 2>&1)"
mixed_input_rc=$?
set -e
if [ "${mixed_input_rc}" -ne 0 ] \
  || ! grep -q '(dry-run) gates satisfied' <<<"${mixed_input_output}"; then
  printf '%s\n' "${mixed_input_output}" >&2
  fail 'mixed-case-input-url: canonical repository identity was rejected'
fi

MOCK_WORKTREE_CASE="${mock_worktree}"
mixed_url_output="$(run_case mixed-case-url 0 mixed-url ok "" 2>&1)"
unset MOCK_WORKTREE_CASE
if ! grep -q '(dry-run) gates satisfied' <<<"${mixed_url_output}"; then
  printf '%s\n' "${mixed_url_output}" >&2
  fail 'mixed-case-url: canonical URL comparison rejected same PR'
fi

set +e
unprotected_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=unprotected \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" --dry-run 1 2>&1)"
unprotected_rc=$?
set -e
if [ "${unprotected_rc}" -ne 1 ] || ! grep -q 'branch protection/ruleset enforcement' <<<"${unprotected_output}" \
  || grep -q 'pr merge' "${GH_LOG}"; then
  printf '%s\n' "${unprotected_output}" >&2
  fail 'unprotected-main: missing platform enforcement was accepted'
fi

for enforcement_scenario in wrong-protection-check no-conversation-resolution ruleset-bypass; do
  : > "${GH_LOG}"
  set +e
  enforcement_output="$(PATH="${mock_bin}:${system_path}" \
    MOCK_GH_SCENARIO="${enforcement_scenario}" MOCK_COLLECTOR_SCENARIO=ok \
    MOCK_WORKTREE="${mock_worktree}" "${safe_merge}" --dry-run 1 2>&1)"
  enforcement_rc=$?
  set -e
  if [ "${enforcement_rc}" -ne 1 ] \
    || ! grep -q 'branch protection/ruleset enforcement' <<<"${enforcement_output}" \
    || grep -q 'pr merge' "${GH_LOG}"; then
    printf '%s\n' "${enforcement_output}" >&2
    fail "${enforcement_scenario}: incomplete or bypassable enforcement was accepted"
  fi
done

: > "${GH_LOG}"
set +e
merge_queue_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=merge-queue \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" --dry-run 1 2>&1)"
merge_queue_rc=$?
set -e
if [ "${merge_queue_rc}" -ne 1 ] || ! grep -q 'merge queue applies' <<<"${merge_queue_output}" \
  || grep -q 'pr merge' "${GH_LOG}"; then
  printf '%s\n' "${merge_queue_output}" >&2
  fail 'merge-queue: queue admission was accepted as a direct merge'
fi

MOCK_WORKTREE_CASE="${mock_worktree}"
ruleset_output="$(run_case ruleset-enforcement 0 ruleset ok "" 2>&1)"
unset MOCK_WORKTREE_CASE
if ! grep -q '(dry-run) gates satisfied' <<<"${ruleset_output}" \
  || ! grep -q 'rulesets/42' "${GH_LOG}"; then
  printf '%s\n' "${ruleset_output}" >&2
  fail 'ruleset-enforcement: active no-bypass ruleset was not recognized'
fi

# The configured clean-main launcher is the only executable trust root. A
# current-checkout copy is rejected before it can inspect a PR.
: > "${GH_LOG}"
set +e
untrusted_launcher_output="$(PATH="${mock_bin}:${system_path}" \
  "${mock_repo}/scripts/safe-direct-merge.sh" --dry-run 1 2>&1)"
untrusted_launcher_rc=$?
set -e
if [ "${untrusted_launcher_rc}" -ne 2 ] \
  || ! grep -q 'untrusted-launcher' <<<"${untrusted_launcher_output}" \
  || grep -q 'pr view\|pr merge' "${GH_LOG}"; then
  printf '%s\n' "${untrusted_launcher_output}" >&2
  fail 'untrusted-launcher: current-checkout script was accepted'
fi

# A launcher modified in the trusted checkout can hide behind
# assume-unchanged/skip-worktree. The bootstrap still compares the evaluated
# launcher bytes with the trusted main blob before materializing any asset.
launcher_backup="${tmp_dir}/trusted-launcher-original"
cp "${trusted_source}/scripts/safe-direct-merge.sh" "${launcher_backup}"
printf '\n# hidden working-tree launcher mutation\n' \
  >>"${trusted_source}/scripts/safe-direct-merge.sh"
set +e
launcher_tamper_output="$(PATH="${mock_bin}:${system_path}" \
  MOCK_GIT_SCENARIO=launcher-working-tree-mismatch \
  "${safe_merge}" --dry-run 1 2>&1)"
launcher_tamper_rc=$?
set -e
cp "${launcher_backup}" "${trusted_source}/scripts/safe-direct-merge.sh"
if [ "${launcher_tamper_rc}" -ne 2 ] \
  || ! grep -q 'untrusted-launcher-bytes' <<<"${launcher_tamper_output}" \
  || grep -q 'pr view\|pr checks' "${GH_LOG}"; then
  printf '%s\n' "${launcher_tamper_output}" >&2
  fail 'launcher-working-tree-mutation: hidden launcher bytes were executed'
fi

for materialized_scenario in materialized-script-mismatch \
  materialized-policy-mismatch materialized-collector-mismatch; do
  : > "${GH_LOG}"
  set +e
  materialized_output="$(PATH="${mock_bin}:${system_path}" \
    MOCK_GIT_SCENARIO="${materialized_scenario}" \
    "${safe_merge}" --dry-run 1 2>&1)"
  materialized_rc=$?
  set -e
  if [ "${materialized_rc}" -ne 2 ] \
    || ! grep -q 'trusted-main-asset-invalid' <<<"${materialized_output}" \
    || grep -q 'pr view\|pr merge' "${GH_LOG}"; then
    printf '%s\n' "${materialized_output}" >&2
    fail "${materialized_scenario}: asset identity mismatch was accepted"
  fi
done

: > "${GH_LOG}"
set +e
post_verify_output="$(PATH="${mock_bin}:${system_path}" \
  MOCK_GIT_SCENARIO=post-verify-collector-tamper \
  "${safe_merge}" --dry-run 1 2>&1)"
post_verify_rc=$?
set -e
if [ "${post_verify_rc}" -ne 2 ] \
  || ! grep -q 'trusted-main-asset-changed-after-verification' <<<"${post_verify_output}" \
  || grep -q 'pr view\|pr merge' "${GH_LOG}"; then
  printf '%s\n' "${post_verify_output}" >&2
  fail 'post-verify-tamper: changed materialized collector reached execution'
fi

# A caller-forged implementation-stage environment has no cleanup authority.
forged_cleanup_root="${tmp_dir}/forged-cleanup-root"
mkdir -p "${forged_cleanup_root}"
printf 'preserve\n' >"${forged_cleanup_root}/user-file"
set +e
forged_stage_output="$(PATH="${mock_bin}:${system_path}" \
  RPM_SAFE_DIRECT_MERGE_STAGE=implementation \
  RPM_SAFE_DIRECT_MERGE_TRUSTED_ROOT="${forged_cleanup_root}" \
  "${safe_merge}" --dry-run 1 2>&1)"
forged_stage_rc=$?
set -e
if [ "${forged_stage_rc}" -ne 2 ] || [ ! -f "${forged_cleanup_root}/user-file" ]; then
  printf '%s\n' "${forged_stage_output}" >&2
  fail 'forged-stage-cleanup: caller-selected cleanup root was removed'
fi

# The launcher always reads immutable materialized assets from trusted main.
# Mutations in the current checkout must therefore have no effect.
for trust_asset in scripts/safe-direct-merge.sh \
  .agents/workflows/backlog-policy.json scripts/collect-pr-review-context.sh; do
  cp "${trusted_source}/${trust_asset}" "${mock_repo}/${trust_asset}"
  case "${trust_asset}" in
    scripts/safe-direct-merge.sh) printf '\n# mutable checkout fixture\n' >> "${mock_repo}/${trust_asset}" ;;
    .agents/workflows/backlog-policy.json) printf '%s\n' '{}' > "${mock_repo}/${trust_asset}" ;;
    scripts/collect-pr-review-context.sh) printf '\nexit 99\n' >> "${mock_repo}/${trust_asset}" ;;
  esac
  MOCK_WORKTREE_CASE="${mock_worktree}"
  trust_output="$(run_case "immutable-${trust_asset}" 0 ok ok "" 2>&1)"
  unset MOCK_WORKTREE_CASE
  if ! grep -q '(dry-run) gates satisfied' <<<"${trust_output}" || grep -q 'pr merge' "${GH_LOG}"; then
    printf '%s\n' "${trust_output}" >&2
    fail "immutable-${trust_asset}: mutable checkout asset was executed"
  fi
done

# A second checks response that fails blocks before any linked worktree removal.
: > "${WORKTREE_LOG}"
: > "${CHECK_CALL_LOG}"
set +e
check_race_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=check-race \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" 1 2>&1)"
check_race_rc=$?
set -e
if [ "${check_race_rc}" -ne 1 ] || ! grep -q 'required checks failed' <<<"${check_race_output}" || [ -s "${WORKTREE_LOG}" ] || grep -q 'pr merge' "${GH_LOG}"; then
  printf '%s\n' "${check_race_output}" >&2
  fail 'check-race: degraded checks did not block before worktree removal'
fi

# A second review response with an unresolved thread also blocks before cleanup.
: > "${WORKTREE_LOG}"
: > "${REVIEW_CALL_LOG}"
set +e
review_race_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=review-race MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" 1 2>&1)"
review_race_rc=$?
set -e
if [ "${review_race_rc}" -ne 1 ] || ! grep -q 'unresolved review thread' <<<"${review_race_output}" || [ -s "${WORKTREE_LOG}" ] || grep -q 'pr merge' "${GH_LOG}"; then
  printf '%s\n' "${review_race_output}" >&2
  fail 'review-race: newly unresolved review did not block before worktree removal'
fi

# Dry-runs perform the same worktree safety scan. A dirty primary worktree
# blocks, while a clean primary worktree is retained and remains successful.
set +e
primary_dirty_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_repo}" \
  MOCK_WORKTREE_STATUS=' M primary-file' "${safe_merge}" --dry-run 1 2>&1)"
primary_dirty_rc=$?
set -e
if [ "${primary_dirty_rc}" -ne 1 ] || ! grep -q 'dirty worktree' <<<"${primary_dirty_output}"; then
  printf '%s\n' "${primary_dirty_output}" >&2
  fail 'dry-run-primary-dirty: dirty primary worktree did not block'
fi
: > "${WORKTREE_LOG}"
primary_clean_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_repo}" \
  MOCK_WORKTREE_STATUS='' "${safe_merge}" --dry-run 1 2>&1)"
if ! grep -q '(dry-run) gates satisfied' <<<"${primary_clean_output}" || [ -s "${WORKTREE_LOG}" ]; then
  printf '%s\n' "${primary_clean_output}" >&2
  fail 'dry-run-primary-clean: clean primary worktree was not retained'
fi

for git_scenario in inventory-failure branch-failure; do
  set +e
  failure_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
    MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
    MOCK_WORKTREE_STATUS='' MOCK_GIT_SCENARIO="${git_scenario}" \
    "${safe_merge}" --dry-run 1 2>&1)"
  failure_rc=$?
  set -e
  if [ "${failure_rc}" -ne 1 ] || ! grep -q 'refusing to merge' <<<"${failure_output}"; then
    printf '%s\n' "${failure_output}" >&2
    fail "${git_scenario}: worktree failure was suppressed"
  fi
done

# The head SHA is pinned at the merge API boundary. A deterministic change
# between preflight and the final lookup blocks the merge invocation.
: > "${GH_LOG}"
: > "${HEAD_OID_LOG}"
set +e
race_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=head-race \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" "${safe_merge}" 1 2>&1)"
race_rc=$?
set -e
if [ "${race_rc}" -ne 1 ] || ! grep -q 'head revision changed' <<<"${race_output}"; then
  printf '%s\n' "${race_output}" >&2
  fail 'head-race: changed head revision did not block merge'
fi
if grep -q 'pr merge' "${GH_LOG}"; then
  fail 'head-race: merge was invoked after head revision changed'
fi

# GitHub can preserve the head while a concurrent actor changes the PR base.
# The mock would record that base redirection if a merge call occurred. With no
# atomic expected-base condition, non-dry-run must stop before every mutation.
: > "${GH_LOG}"
: > "${PUSH_LOG}"
: > "${LOCAL_REF_LOG}"
: > "${WORKTREE_LOG}"
rm -f "${BASE_RACE_LOG}"
set +e
base_race_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=base-race \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" 1 2>&1)"
base_race_rc=$?
set -e
if [ "${base_race_rc}" -ne 1 ] \
  || ! grep -q 'base branch develop is not protected main' <<<"${base_race_output}" \
  || grep -q 'pr merge' "${GH_LOG}" \
  || [ -e "${BASE_RACE_LOG}" ] \
  || [ -s "${PUSH_LOG}" ] \
  || [ -s "${LOCAL_REF_LOG}" ] \
  || [ -s "${WORKTREE_LOG}" ]; then
  printf '%s\n' "${base_race_output}" >&2
  fail 'base-race: non-transactional target mutation was reachable'
fi

# The PR can close or become a draft after the final collector/check pass.
# Recheck both fields immediately before reporting readiness.
for final_state_scenario in final-state-race final-draft-race; do
  : > "${GH_LOG}"
  set +e
  final_state_output="$(PATH="${mock_bin}:${system_path}" \
    MOCK_GH_SCENARIO="${final_state_scenario}" MOCK_COLLECTOR_SCENARIO=ok \
    MOCK_WORKTREE="${mock_worktree}" "${safe_merge}" --dry-run 1 2>&1)"
  final_state_rc=$?
  set -e
  if [ "${final_state_rc}" -ne 1 ] \
    || ! grep -q 'refusing readiness report' <<<"${final_state_output}" \
    || grep -q '(dry-run) gates satisfied' <<<"${final_state_output}"; then
    printf '%s\n' "${final_state_output}" >&2
    fail "${final_state_scenario}: final PR eligibility was reported stale"
  fi
done

# A main-branch update can make a previously mergeable PR conflicting, blocked,
# or temporarily unknown after the initial gate pass. Final mergeability and
# merge-state fields must prevent a stale readiness report.
for final_merge_scenario in final-conflicting-race final-blocked-race final-unknown-race; do
  : > "${GH_LOG}"
  set +e
  final_merge_output="$(PATH="${mock_bin}:${system_path}" \
    MOCK_GH_SCENARIO="${final_merge_scenario}" MOCK_COLLECTOR_SCENARIO=ok \
    MOCK_WORKTREE="${mock_worktree}" "${safe_merge}" --dry-run 1 2>&1)"
  final_merge_rc=$?
  set -e
  if [ "${final_merge_rc}" -ne 1 ] \
    || ! grep -q 'refusing readiness report' <<<"${final_merge_output}" \
    || grep -q '(dry-run) gates satisfied' <<<"${final_merge_output}"; then
    printf '%s\n' "${final_merge_output}" >&2
    fail "${final_merge_scenario}: final mergeability was reported stale"
  fi
done

# A stable main base still cannot reach mutation without the transactional
# expected-base primitive. The final report is followed by a deterministic
# fail-closed blocker, with no merge or remote cleanup invocation.
: > "${GH_LOG}"
: > "${PUSH_LOG}"
: > "${LOCAL_REF_LOG}"
set +e
non_dry_run_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" 1 2>&1)"
non_dry_run_rc=$?
set -e
if [ "${non_dry_run_rc}" -ne 1 ] \
  || ! grep -q 'transactional expected-base primitive is unavailable' <<<"${non_dry_run_output}" \
  || grep -q 'pr merge' "${GH_LOG}" \
  || [ -s "${PUSH_LOG}" ] || [ -s "${LOCAL_REF_LOG}" ]; then
  printf '%s\n' "${non_dry_run_output}" >&2
  fail 'non-dry-run-blocker: mutation was reachable without expected-base primitive'
fi

# Branch names with URL fragment characters remain read-only audit data.
: > "${GH_LOG}"
: > "${PUSH_LOG}"
: > "${LOCAL_REF_LOG}"
hash_branch_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=hash-branch \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  "${safe_merge}" --dry-run 1 2>&1)"
if ! grep -q '(dry-run) gates satisfied for branch feature#probe' \
    <<<"${hash_branch_output}" \
  || grep -q 'pr merge' "${GH_LOG}" \
  || [ -s "${PUSH_LOG}" ] \
  || [ -s "${LOCAL_REF_LOG}" ]; then
  printf '%s\n' "${hash_branch_output}" >&2
  fail 'fragment-branch: audit attempted a ref mutation'
fi

# The primary checkout is the first inventory record, even when the current
# repo root is a different worktree. A clean primary is never removed.
: > "${GH_LOG}"
: > "${HEAD_OID_LOG}"
: > "${WORKTREE_LOG}"
primary_merge_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  MOCK_WORKTREE_STATUS='' "${safe_merge}" --dry-run 1 2>&1)"
if ! grep -q '(dry-run) gates satisfied' <<<"${primary_merge_output}" \
  || [ -s "${WORKTREE_LOG}" ]; then
  printf '%s\n' "${primary_merge_output}" >&2
  fail 'primary-worktree: clean primary was removed or audit did not proceed'
fi

# Both the inventory primary and the current checkout are preserved when the
# current checkout is a second linked worktree.
: > "${GH_LOG}"
: > "${HEAD_OID_LOG}"
: > "${WORKTREE_LOG}"
primary_current_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_worktree}" \
  MOCK_CURRENT_WORKTREE="${mock_repo}" MOCK_WORKTREE_STATUS='' \
  "${safe_merge}" --dry-run 1 2>&1)"
if ! grep -q '(dry-run) gates satisfied' <<<"${primary_current_output}" \
  || [ -s "${WORKTREE_LOG}" ]; then
  printf '%s\n' "${primary_current_output}" >&2
  fail 'primary-and-current-worktrees: one of the protected paths was removed'
fi

# A linked worktree can gain ignored content after reporting a clean status.
# Automatic removal is forbidden, so the late file and worktree stay intact.
: > "${GH_LOG}"
: > "${HEAD_OID_LOG}"
: > "${WORKTREE_LOG}"
rm -f "${mock_worktree}/late-ignored"
set +e
remove_failure_output="$(PATH="${mock_bin}:${system_path}" MOCK_GH_SCENARIO=ok \
  MOCK_COLLECTOR_SCENARIO=ok MOCK_WORKTREE="${mock_repo}" \
  MOCK_CURRENT_WORKTREE="${mock_worktree}" MOCK_WORKTREE_STATUS='' \
  MOCK_CONCURRENT_WORKTREE="${mock_worktree}" MOCK_GIT_SCENARIO=concurrent-ignored \
  "${safe_merge}" 1 2>&1)"
remove_failure_rc=$?
set -e
if [ "${remove_failure_rc}" -ne 1 ] || ! grep -q 'remove it manually and retry' <<<"${remove_failure_output}" \
  || grep -q 'pr merge' "${GH_LOG}" \
  || [ -s "${WORKTREE_LOG}" ] || [ ! -f "${mock_worktree}/late-ignored" ]; then
  printf '%s\n' "${remove_failure_output}" >&2
  fail 'concurrent-dirty-worktree: late ignored content was not preserved'
fi

printf 'safe-direct-merge.status=ok\n'
