#!/usr/bin/env bash
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1; then
  printf 'codex-cloud-setup: cargo is required\n' >&2
  exit 1
fi

if command -v rustup >/dev/null 2>&1; then
  rust_components=()
  command -v rustfmt >/dev/null 2>&1 || rust_components+=(rustfmt)
  command -v cargo-clippy >/dev/null 2>&1 || rust_components+=(clippy)
  if [ "${#rust_components[@]}" -gt 0 ]; then
    rustup component add "${rust_components[@]}"
  fi
fi

if ! command -v just >/dev/null 2>&1; then
  cargo install just --locked
fi

for command_name in jq node python3; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'codex-cloud-setup: %s is required\n' "${command_name}" >&2
    exit 1
  fi
done

cargo fetch --locked
cargo check --locked --all-targets
