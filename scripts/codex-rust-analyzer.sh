#!/usr/bin/env bash
set -euo pipefail

readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(cd -- "${script_dir}/.." && pwd -P)"

usage() {
  printf 'usage: %s {probe|analyze|cargo-check|diagnose}\n' "${0##*/}" >&2
}

probe() {
  local binary
  local version_output

  binary="$(command -v rust-analyzer 2>/dev/null || true)"
  if [ -z "${binary}" ]; then
    printf 'rust_analyzer.status=unavailable\n'
    printf 'rust_analyzer.reason=not-found-on-path\n'
    printf 'rust_analyzer.install=rustup component add rust-analyzer rust-src --toolchain stable\n'
    return "${EX_UNAVAILABLE}"
  fi

  if version_output="$("${binary}" --version 2>&1)"; then
    printf 'rust_analyzer.status=available\n'
    printf 'rust_analyzer.path=%s\n' "${binary}"
    printf 'rust_analyzer.version=%s\n' "${version_output}"
    return 0
  fi

  printf 'rust_analyzer.status=unavailable\n'
  printf 'rust_analyzer.path=%s\n' "${binary}"
  printf 'rust_analyzer.reason=%s\n' "${version_output//$'\n'/ }"
  if [[ "${binary}" == */.cargo/bin/rust-analyzer ]]; then
    printf 'rust_analyzer.install=rustup component add rust-analyzer rust-src --toolchain stable\n'
  else
    printf 'rust_analyzer.install=see https://rust-analyzer.github.io/book/rust_analyzer_binary.html\n'
  fi
  return "${EX_UNAVAILABLE}"
}

analyze() {
  probe
  printf 'rust_analyzer.mode=batch-analysis-stats\n'
  exec rust-analyzer analysis-stats "${repo_root}"
}

cargo_check() {
  printf 'rust_analyzer.mode=cargo-fallback\n'
  cd -- "${repo_root}"
  exec cargo check --quiet --locked --all-targets
}

diagnose() {
  if probe; then
    printf 'rust_analyzer.mode=batch-analysis-stats\n'
    exec rust-analyzer analysis-stats "${repo_root}"
  fi

  printf 'rust_analyzer.fallback=cargo-check\n'
  cargo_check
}

case "${1:-}" in
  probe)
    [ "$#" -eq 1 ] || {
      usage
      exit "${EX_USAGE}"
    }
    probe
    ;;
  analyze)
    [ "$#" -eq 1 ] || {
      usage
      exit "${EX_USAGE}"
    }
    analyze
    ;;
  cargo-check)
    [ "$#" -eq 1 ] || {
      usage
      exit "${EX_USAGE}"
    }
    cargo_check
    ;;
  diagnose)
    [ "$#" -eq 1 ] || {
      usage
      exit "${EX_USAGE}"
    }
    diagnose
    ;;
  *)
    usage
    exit "${EX_USAGE}"
    ;;
esac
