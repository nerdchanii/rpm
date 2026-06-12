#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
hooks_path="$repo_root/.githooks"

if [[ ! -d "$hooks_path" ]]; then
  echo "missing hooks directory: $hooks_path" >&2
  exit 1
fi

chmod +x \
  "$hooks_path/pre-commit" \
  "$hooks_path/pre-push" \
  "$repo_root/scripts/run-local-git-hook-gate.sh"

git config --local core.hooksPath .githooks

echo "Installed repo-local git hooks at .githooks"
echo "pre-commit: cargo fmt --check"
echo "pre-push: cargo clippy --all-targets --all-features -- -D warnings"
echo "pre-push: cargo test"
