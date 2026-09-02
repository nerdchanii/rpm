#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/semver-benchmarks.yml"

fail() {
  printf 'semver_workflow_security_test.FAIL=%s\n' "$1" >&2
  exit 1
}

python3 - "$workflow" <<'PY' || fail 'workflow-contract'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")

required = (
    "permissions:\n  contents: read",
    "uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2",
    "ref: ${{ github.event.pull_request.head.sha }}",
    "persist-credentials: false",
    "git diff --exit-code -- benches/BENCHMARKS.md benches/histories",
)
for needle in required:
    if needle not in text:
        raise SystemExit(f"missing: {needle}")

for forbidden in (
    "contents: write",
    "git push",
    "git commit",
    "github.event.pull_request.head.ref",
    "uses: actions/checkout@v4",
):
    if forbidden in text:
        raise SystemExit(f"forbidden: {forbidden}")
PY

printf 'semver_workflow_security_test.PASS\n'
