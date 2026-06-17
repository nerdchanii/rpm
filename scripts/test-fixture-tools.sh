#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d)"
fixture_name="fixture-smoke"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/tests/fixtures/package_manifest"
mkdir -p "$tmp_root/tests/fixtures/lockfile"
mkdir -p "$tmp_root/tests/fixtures/registry/shared-transitive/metadata"
mkdir -p "$tmp_root/tests/fixtures/registry/shared-transitive/expected"
mkdir -p "$tmp_root/tests/fixtures/install-projects"

git -C "$tmp_root" init -q

cat > "$tmp_root/tests/fixtures/package_manifest/manifest-minimal.json" <<'EOF'
{}
EOF
cat > "$tmp_root/tests/fixtures/package_manifest/manifest-with-fields.json" <<'EOF'
{"name":"fixture"}
EOF
cat > "$tmp_root/tests/fixtures/package_manifest/manifest-invalid.json" <<'EOF'
{
EOF
cat > "$tmp_root/tests/fixtures/lockfile/minimal.rpm.lock" <<'EOF'
lockfile_version = 1
EOF
cat > "$tmp_root/tests/fixtures/registry/shared-transitive/metadata/placeholder.json" <<'EOF'
{}
EOF
cat > "$tmp_root/tests/fixtures/registry/shared-transitive/expected/resolved-packages.txt" <<'EOF'
placeholder
EOF

(
  cd "$tmp_root"
  "$repo_root/scripts/new-install-fixture.sh" "$fixture_name"
  "$repo_root/scripts/audit-fixtures.sh"
)

echo "fixture tool smoke: ok"
