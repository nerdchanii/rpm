#!/usr/bin/env bash
set -euo pipefail

hook_name="${1:-}"

if [[ -z "$hook_name" ]]; then
  echo "usage: $0 <pre-commit|pre-push>" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

run_gate() {
  local label="$1"
  shift

  echo "[local-hook] $label"
  "$@"
}

# A ref-deletion-only push (`git push --delete ...`) carries all-zero local
# SHAs on stdin. Such a push changes no committed content, so clippy/test are
# not meaningful and are skipped. Any real (content-bearing) ref falls through
# to the full gate.
is_deletion_only_push() {
  local local_ref local_sha remote_ref remote_sha
  local saw_input=false
  while read -r local_ref local_sha remote_ref remote_sha; do
    saw_input=true
    [[ "$local_sha" =~ ^0{40}$ ]] || return 1
  done
  [[ "$saw_input" == "true" ]]
}

case "$hook_name" in
  pre-commit)
    run_gate "cargo fmt --check" cargo fmt --check
    ;;
  pre-push)
    if is_deletion_only_push; then
      echo "[local-hook] pre-push: ref-deletion-only push, skipping clippy/test gate"
      exit 0
    fi
    run_gate "cargo clippy --all-targets --all-features -- -D warnings" \
      cargo clippy --all-targets --all-features -- -D warnings
    run_gate "cargo test" cargo test
    ;;
  *)
    echo "unsupported hook: $hook_name" >&2
    exit 1
    ;;
esac
