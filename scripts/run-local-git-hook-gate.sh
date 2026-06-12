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

case "$hook_name" in
  pre-commit)
    run_gate "cargo fmt --check" cargo fmt --check
    ;;
  pre-push)
    run_gate "cargo clippy --all-targets --all-features -- -D warnings" \
      cargo clippy --all-targets --all-features -- -D warnings
    run_gate "cargo test" cargo test
    ;;
  *)
    echo "unsupported hook: $hook_name" >&2
    exit 1
    ;;
esac
