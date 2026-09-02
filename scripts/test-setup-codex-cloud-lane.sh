#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script="${script_dir}/setup-codex-cloud-lane.sh"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
temp_dir="$(mktemp -d "/tmp/rpm-cloud-lane-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
  printf 'setup-codex-cloud-lane-test.FAIL=%s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" == *"$expected"* ]] || fail "missing-output:${expected}"
}

assert_failed() {
  local label="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "accepted:${label}"
  [ "$output" = 'codex-cloud-lane: setup failed' ] || fail "failure-output:${label}"
}

init_repo() {
  local directory="$1"
  mkdir -p -- "$directory"
  git -C "$directory" init --quiet || fail "git-init:${directory}"
}

marker_path_for() {
  local directory="$1"
  git -C "$directory" rev-parse --git-path rpm-cloud-lane || fail 'marker-path'
}

absolute_marker_path() {
  local directory="$1"
  local marker
  marker="$(marker_path_for "$directory")"
  case "$marker" in
    /*) printf '%s\n' "$marker" ;;
    *) printf '%s/%s\n' "$directory" "$marker" ;;
  esac
}

file_mode() {
  local file="$1"
  local mode
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  case "$mode" in
    600) printf '%s\n' "$mode" ;;
    *) stat -c '%a' -- "$file" 2>/dev/null || return 1 ;;
  esac
}

run_lane_case() {
  local lane="$1"
  local directory="${temp_dir}/${lane}"
  local output
  local marker

  init_repo "$directory"
  output="$(cd -- "$directory" && "$script" "$lane")" || fail "lane:${lane}"
  assert_contains "$output" "configured lane=${lane}"
  assert_contains "$output" 'Cloud environment setup and maintenance'
  marker="$(absolute_marker_path "$directory")"
  [ -f "$marker" ] || fail "marker-missing:${lane}"
  [ ! -L "$marker" ] || fail "marker-symlink:${lane}"
  [ "$(/bin/cat "$marker")" = "$lane" ] || fail "marker-content:${lane}"
  [ "$(file_mode "$marker")" = 600 ] || fail "marker-mode:${lane}"
  printf '%s\n' "$lane" | cmp -s - "$marker" || fail "marker-bytes:${lane}"

  # The marker is in the Git administrative directory and must not appear in
  # either the worktree diff or the untracked-file list.
  [ -z "$(git -C "$directory" status --porcelain --untracked-files=all)" ] || fail "marker-git-status:${lane}"
  git -C "$directory" diff --quiet --exit-code || fail "marker-git-diff:${lane}"

  # Maintenance is idempotent and refreshes the same exact marker.
  output="$(cd -- "$directory" && "$script" "$lane")" || fail "maintenance:${lane}"
  [ "$(/bin/cat "$marker")" = "$lane" ] || fail "maintenance-content:${lane}"
  [ "$(file_mode "$marker")" = 600 ] || fail "maintenance-mode:${lane}"
}

run_lane_case issue
run_lane_case review
run_lane_case merge

assert_failed missing-argument "$script"
assert_failed invalid-argument "$script" invalid
assert_failed too-many-arguments "$script" issue extra

# A linked worktree stores .git as a file. The script must use Git's resolved
# administrative directory instead of assuming a .git directory exists.
worktree_parent="${temp_dir}/worktree-parent"
worktree_main="${worktree_parent}/main"
worktree_linked="${worktree_parent}/linked"
mkdir -p -- "$worktree_parent"
git init --quiet "$worktree_main" || fail 'worktree-main-init'
git -C "$worktree_main" config user.email fixture@example.invalid
git -C "$worktree_main" config user.name fixture
printf 'fixture\n' >"${worktree_main}/file"
git -C "$worktree_main" add file
git -C "$worktree_main" commit --quiet -m fixture
git -C "$worktree_main" worktree add --quiet "$worktree_linked" || fail 'worktree-add'
worktree_output="$(cd -- "$worktree_linked" && "$script" review)" || fail 'worktree-file'
assert_contains "$worktree_output" 'configured lane=review'
worktree_marker="$(absolute_marker_path "$worktree_linked")"
[ -f "$worktree_marker" ] || fail 'worktree-marker-missing'
[ "$(/bin/cat "$worktree_marker")" = review ] || fail 'worktree-marker-content'
[ "$(file_mode "$worktree_marker")" = 600 ] || fail 'worktree-marker-mode'
[ -z "$(git -C "$worktree_linked" status --porcelain --untracked-files=all)" ] || fail 'worktree-marker-status'

symlink_repo="${temp_dir}/symlink"
init_repo "$symlink_repo"
symlink_marker="$(absolute_marker_path "$symlink_repo")"
symlink_target="${temp_dir}/symlink-target"
printf 'review\n' >"$symlink_target"
ln -s -- "$symlink_target" "$symlink_marker" || fail 'symlink-create'
assert_failed preexisting-symlink bash -c 'cd -- "$1" && "$2" issue' _ "$symlink_repo" "$script"
[ -L "$symlink_marker" ] || fail 'symlink-overwritten'
[ "$(/bin/cat "$symlink_target")" = review ] || fail 'symlink-target-changed'

directory_repo="${temp_dir}/directory-target"
init_repo "$directory_repo"
directory_marker="$(absolute_marker_path "$directory_repo")"
mkdir -- "$directory_marker" || fail 'directory-target-create'
assert_failed preexisting-directory bash -c 'cd -- "$1" && "$2" issue' _ "$directory_repo" "$script"
[ -d "$directory_marker" ] || fail 'directory-target-overwritten'

# An injected Git environment must not redirect setup to an unrelated Git dir.
outside_repo="${temp_dir}/outside-env"
init_repo "$outside_repo"
outside_dir="${temp_dir}/outside-git"
mkdir -- "$outside_dir"
assert_failed git-dir-environment env GIT_DIR="$outside_dir" "$script" issue

bash -n "$script" || fail 'bash-syntax'
git -C "$repo_root" diff --check -- "$script" "${script_dir}/test-setup-codex-cloud-lane.sh" || fail 'diff-check'

printf 'setup-codex-cloud-lane-test: PASS\n'
