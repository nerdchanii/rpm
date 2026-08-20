#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/worktree-cleanup.sh [--check] [--help]

Remove Cargo build artifacts from this repository's target directory. The
current worktree must be clean. Source files, untracked files outside target/,
other worktrees, and shared Git worktree metadata are never removed.

--check  Validate the cleanup preconditions without removing anything.
--help   Show this help text.
EOF
}

check_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      check_only=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'worktree-cleanup: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  printf 'worktree-cleanup: git is required\n' >&2
  exit 1
fi

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  printf 'worktree-cleanup: run this script inside a Git worktree\n' >&2
  exit 1
fi

cd -- "${repo_root}"

if [ ! -f "${repo_root}/Cargo.toml" ]; then
  printf 'worktree-cleanup: Cargo.toml was not found at %s\n' "${repo_root}" >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  printf 'worktree-cleanup: refusing to run in a dirty worktree (%s)\n' "${repo_root}" >&2
  exit 1
fi

target_dir="${repo_root}/target"
if [ -L "${target_dir}" ]; then
  printf 'worktree-cleanup: refusing symlinked target directory: %s\n' "${target_dir}" >&2
  exit 1
fi

if [ "${check_only}" = true ]; then
  printf 'worktree-cleanup: check passed (%s)\n' "${repo_root}"
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  printf 'worktree-cleanup: cargo is required\n' >&2
  exit 1
fi

# The explicit target directory keeps cleanup confined to this repository.
# In particular, CARGO_TARGET_DIR and Cargo config cannot redirect deletion.
cargo clean --manifest-path "${repo_root}/Cargo.toml" --target-dir "${target_dir}"

printf 'worktree-cleanup: removed Cargo artifacts (%s)\n' "${repo_root}"
