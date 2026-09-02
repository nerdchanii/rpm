#!/usr/bin/env bash
set -euo pipefail

# Run this script during Codex Cloud environment setup and on every maintenance
# pass. The marker is clone-local evidence for the hook, so it must never be
# written into the worktree or committed to Git.

fail() {
  # Keep repository paths and command output out of failures. The script can
  # run in a shared Cloud log, where those values are not useful to callers.
  printf 'codex-cloud-lane: setup failed\n' >&2
  exit 1
}

[ "$#" -eq 1 ] || fail
lane="$1"
case "$lane" in
  issue|review|merge) ;;
  *) fail ;;
esac

# Git environment overrides can make rev-parse describe a different checkout.
# Cloud setup must identify the checkout from its working directory instead.
[ -z "${GIT_DIR:-}" ] || fail
[ -z "${GIT_WORK_TREE:-}" ] || fail
[ -z "${GIT_COMMON_DIR:-}" ] || fail

git_bin=/usr/bin/git
[ -x "$git_bin" ] || fail
mktemp_bin=/usr/bin/mktemp
chmod_bin=/bin/chmod
mv_bin=/bin/mv
rm_bin=/bin/rm
stat_bin=/usr/bin/stat
cmp_bin=/usr/bin/cmp
for utility in "$mktemp_bin" "$chmod_bin" "$mv_bin" "$rm_bin" "$stat_bin" "$cmp_bin"; do
  [ -x "$utility" ] || fail
done

umask 077

repo_root="$("$git_bin" rev-parse --show-toplevel 2>/dev/null)" || fail
case "$repo_root" in
  ''|*$'\n'|*$'\r') fail ;;
  /*) ;;
  *) fail ;;
esac
[ -d "$repo_root" ] || fail
repo_root="$(cd -- "$repo_root" 2>/dev/null && pwd -P 2>/dev/null)" || fail
current_directory="$(pwd -P 2>/dev/null)" || fail
case "$current_directory" in
  "$repo_root"|"$repo_root"/*) ;;
  *) fail ;;
esac

inside_work_tree="$("$git_bin" -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null)" || fail
[ "$inside_work_tree" = true ] || fail

git_dir_spec="$("$git_bin" -C "$repo_root" rev-parse --git-dir 2>/dev/null)" || fail
case "$git_dir_spec" in
  ''|*$'\n'|*$'\r') fail ;;
  /*) git_dir_candidate="$git_dir_spec" ;;
  *) git_dir_candidate="$repo_root/$git_dir_spec" ;;
esac
[ -d "$git_dir_candidate" ] || fail
git_dir="$(cd -- "$git_dir_candidate" 2>/dev/null && pwd -P 2>/dev/null)" || fail
[ -d "$git_dir" ] || fail

# Resolve the marker through Git itself. The parent must be the canonical
# git-dir, which rejects a config/environment redirect outside this checkout.
marker_spec="$("$git_bin" -C "$repo_root" rev-parse --git-path rpm-cloud-lane 2>/dev/null)" || fail
case "$marker_spec" in
  ''|*$'\n'|*$'\r') fail ;;
  /*) marker_candidate="$marker_spec" ;;
  *) marker_candidate="$repo_root/$marker_spec" ;;
esac
[ "$(basename -- "$marker_candidate")" = rpm-cloud-lane ] || fail
marker_parent="$(dirname -- "$marker_candidate")" || fail
[ -d "$marker_parent" ] || fail
marker_parent="$(cd -- "$marker_parent" 2>/dev/null && pwd -P 2>/dev/null)" || fail
[ "$marker_parent" = "$git_dir" ] || fail
marker_path="$git_dir/rpm-cloud-lane"

# A symlink or non-regular target could redirect an apparently local write.
# Reject it before creating the replacement and check again immediately before
# the rename. Existing regular files are safely replaced atomically.
if [ -L "$marker_path" ] || { [ -e "$marker_path" ] && [ ! -f "$marker_path" ]; }; then
  fail
fi

temp_path=""
cleanup() {
  if [ -n "$temp_path" ] && [ -e "$temp_path" ]; then
    "$rm_bin" -f -- "$temp_path" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# The template is inside the git-dir, so mv below is one-directory atomic.
temp_path="$("$mktemp_bin" "$git_dir/.rpm-cloud-lane.XXXXXX" 2>/dev/null)" || fail
[ -f "$temp_path" ] && [ ! -L "$temp_path" ] || fail
"$chmod_bin" 600 "$temp_path" 2>/dev/null || fail
printf '%s\n' "$lane" >"$temp_path" 2>/dev/null || fail

if [ -L "$marker_path" ] || { [ -e "$marker_path" ] && [ ! -f "$marker_path" ]; }; then
  fail
fi
"$mv_bin" -f -- "$temp_path" "$marker_path" 2>/dev/null || fail
temp_path=""

[ -f "$marker_path" ] && [ ! -L "$marker_path" ] || fail
"$chmod_bin" 600 "$marker_path" 2>/dev/null || fail

marker_mode="$("$stat_bin" -f '%Lp' "$marker_path" 2>/dev/null || true)"
case "$marker_mode" in
  600) ;;
  *) marker_mode="$("$stat_bin" -c '%a' -- "$marker_path" 2>/dev/null)" || fail ;;
esac
[ "$marker_mode" = 600 ] || fail

# cmp verifies the complete byte sequence, including exactly one final LF.
printf '%s\n' "$lane" | "$cmp_bin" -s - "$marker_path" || fail

printf 'codex-cloud-lane: configured lane=%s; run during Cloud environment setup and maintenance\n' "$lane"
