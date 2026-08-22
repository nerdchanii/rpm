#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly wrapper="${script_dir}/codex-rust-analyzer.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-codex-rust-analyzer.XXXXXX")"
trap 'rm -rf -- "${temp_dir}"' EXIT

assert_contains() {
  local output="$1"
  local expected="$2"

  if [[ "${output}" != *"${expected}"* ]]; then
    printf 'expected output to contain: %s\nactual output:\n%s\n' \
      "${expected}" "${output}" >&2
    exit 1
  fi
}

cat >"${temp_dir}/rust-analyzer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    printf 'rust-analyzer test-version\n'
    ;;
  analysis-stats)
    printf 'fake-analysis-root=%s\n' "${2:-}"
    ;;
  *)
    exit 64
    ;;
esac
EOF

cat >"${temp_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-cargo-args=%s\n' "$*"
EOF

chmod +x "${temp_dir}/rust-analyzer" "${temp_dir}/cargo"

output="$(PATH="${temp_dir}:${PATH}" bash "${wrapper}" probe)"
assert_contains "${output}" "rust_analyzer.status=available"
assert_contains "${output}" "rust_analyzer.version=rust-analyzer test-version"

output="$(PATH="${temp_dir}:${PATH}" bash "${wrapper}" analyze)"
assert_contains "${output}" "rust_analyzer.mode=batch-analysis-stats"
assert_contains "${output}" "fake-analysis-root="

cat >"${temp_dir}/rust-analyzer" <<'EOF'
#!/usr/bin/env bash
printf 'test rustup shim has no component\n' >&2
exit 1
EOF
chmod +x "${temp_dir}/rust-analyzer"

set +e
output="$(PATH="${temp_dir}:${PATH}" bash "${wrapper}" probe)"
exit_code=$?
set -e
[ "${exit_code}" -eq 69 ] || {
  printf 'expected unavailable probe exit 69, got %s\n' "${exit_code}" >&2
  exit 1
}
assert_contains "${output}" "rust_analyzer.status=unavailable"
assert_contains "${output}" "rust_analyzer.reason=test rustup shim has no component"

output="$(PATH="${temp_dir}:${PATH}" bash "${wrapper}" diagnose)"
assert_contains "${output}" "rust_analyzer.fallback=cargo-check"
assert_contains "${output}" "rust_analyzer.mode=cargo-fallback"
assert_contains "${output}" "fake-cargo-args=check --quiet --locked --all-targets"

printf 'codex_rust_analyzer_tests=ok\n'
