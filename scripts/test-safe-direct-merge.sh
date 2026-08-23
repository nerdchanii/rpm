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
printf '{"pullRequest":{"number":1},"reviewThreads":[]}\n'
MOCK_COLLECTOR
chmod +x "${mock_repo}/scripts/collect-pr-review-context.sh"

cat > "${mock_bin}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$*" == *"reviewThreads"* ]]; then
  printf 'gh: unsupported reviewThreads field\n' >&2
  exit 1
fi
case "$*" in
  *"--json state"*) printf 'OPEN\n' ;;
  *"--json isDraft"*) printf 'false\n' ;;
  *"--json mergeable"*) printf 'MERGEABLE\n' ;;
  *"--json mergeStateStatus"*) printf 'CLEAN\n' ;;
  *"--json headRefName"*) printf 'feature/mock\n' ;;
  *"--json isCrossRepository"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "cross-repo" ]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    ;;
  *"pr checks"*)
    if [ "${MOCK_GH_SCENARIO:-ok}" = "duplicate-mixed" ]; then
      printf '[{"name":"metadata","bucket":"pass"},{"name":"metadata","bucket":"fail"},{"name":"verify","bucket":"pass"}]\n'
    else
      printf '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]\n'
    fi
    ;;
  *"pr merge"*) printf 'merged\n' ;;
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
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  printf '%s\n' "${MOCK_REPO}"
  exit 0
fi
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${MOCK_WORKTREE:-}" ]; then
    printf 'worktree %s\n' "${MOCK_WORKTREE}"
    printf 'HEAD deadbeef\n'
    printf 'branch refs/heads/feature/mock\n'
  fi
  exit 0
fi
if [ "${1:-}" = "-C" ]; then
  worktree="$2"
  shift 2
  if [ "${1:-}" = "branch" ] && [ "${2:-}" = "--show-current" ]; then
    printf 'feature/mock\n'
    exit 0
  fi
  if [ "${1:-}" = "status" ]; then
    if [ -n "${MOCK_WORKTREE_STATUS:-}" ]; then
      printf '%s\n' "${MOCK_WORKTREE_STATUS}"
    fi
    exit 0
  fi
  printf 'git mock: unsupported -C command in %s\n' "${worktree}" >&2
  exit 1
fi
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "remove" ]; then
  printf '%s\n' "$*" >> "${WORKTREE_LOG}"
  exit 0
fi
if [ "${1:-}" = "push" ] || [ "${1:-}" = "branch" ]; then
  exit 0
fi
printf 'git mock: unsupported command: %s\n' "$*" >&2
exit 1
MOCK_GIT
chmod +x "${mock_bin}/git"

safe_merge="${mock_repo}/scripts/safe-direct-merge.sh"
system_path="${PATH}"
export MOCK_REPO="${mock_repo}" GH_LOG="${tmp_dir}/gh.log" \
  COLLECTOR_LOG="${tmp_dir}/collector.log" WORKTREE_LOG="${tmp_dir}/worktree.log"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
git -C "${actual_repo}" add .
git -C "${actual_repo}" commit -q -m 'test fixture'
git -C "${actual_repo}" worktree add -q -b feature/mock "${actual_worktree}"
printf 'generated content\n' > "${actual_worktree}/ignored-file"

run_case() {
  local name="$1" expected_rc="$2" scenario="$3" collector_scenario="$4" dirty="$5"
  local output rc
  : > "${GH_LOG}"
  : > "${COLLECTOR_LOG}"
  : > "${WORKTREE_LOG}"
  output="$(MOCK_GH_SCENARIO="${scenario}" MOCK_COLLECTOR_SCENARIO="${collector_scenario}" \
    MOCK_WORKTREE_STATUS="${dirty}" MOCK_WORKTREE="" \
    PATH="${mock_bin}:${system_path}" "${safe_merge}" --dry-run 1 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "${rc}" -ne "${expected_rc}" ]; then
    printf '%s\n' "${output}" >&2
    fail "${name}: expected rc ${expected_rc}, got ${rc}"
  fi
  printf '%s\n' "${output}"
}

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

output="$(run_case malformed-review-context 1 ok malformed "" 2>&1)"
if ! grep -q 'review context payload is invalid' <<<"${output}"; then
  fail 'malformed-review-context: invalid payload was not fail-closed'
fi

output="$(run_case duplicate-mixed-check 1 duplicate-mixed ok "" 2>&1)"
if ! grep -q 'required checks failed: metadata=fail' <<<"${output}"; then
  fail 'duplicate-mixed-check: one failing duplicate did not block merge'
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

output="$(run_case cross-repository 1 cross-repo ok "" 2>&1)"
if ! grep -q 'cross-repository PRs' <<<"${output}"; then
  fail 'cross-repository: cross-repository PR was not rejected'
fi

output="$(run_case normal-dry-run 0 ok ok "" 2>&1)"
if ! grep -q '(dry-run) would squash-merge and delete branch feature/mock' <<<"${output}"; then
  fail 'normal-dry-run: expected successful dry-run output'
fi

printf 'safe-direct-merge.status=ok\n'
