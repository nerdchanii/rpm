#!/usr/bin/env bash
set -euo pipefail

bench_name="${1:-}"

if [[ -z "$bench_name" ]]; then
  echo "usage: $0 <bench-fixture-name>" >&2
  exit 2
fi

if [[ ! "$bench_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "invalid bench fixture name: $bench_name" >&2
  echo "expected lowercase kebab-case, for example: resolver-wide-graph" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
template="$repo_root/tests/fixtures/install-projects/performance-small"
target="$repo_root/tests/fixtures/install-projects/performance-$bench_name"

if [[ ! -d "$template" ]]; then
  echo "missing benchmark fixture template: tests/fixtures/install-projects/performance-small" >&2
  exit 1
fi

if [[ -e "$target" ]]; then
  echo "bench fixture already exists: tests/fixtures/install-projects/performance-$bench_name" >&2
  exit 1
fi

cp -R "$template" "$target"

echo "created tests/fixtures/install-projects/performance-$bench_name"
echo "next: edit package.json, registry/, and expected/ for the measured scenario"
