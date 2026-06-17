#!/usr/bin/env bash
set -euo pipefail

fixture_name="${1:-}"

if [[ -z "$fixture_name" ]]; then
  echo "usage: $0 <fixture-name>" >&2
  exit 2
fi

if [[ ! "$fixture_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "invalid fixture name: $fixture_name" >&2
  echo "expected lowercase kebab-case, for example: semver-peer-baseline" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$repo_root/tests/fixtures/install-projects/$fixture_name"
package_name="@rpm-fixture/$fixture_name"
registry_file="$fixture_root/registry/@rpm-fixture__${fixture_name}.json"

if [[ -e "$fixture_root" ]]; then
  echo "fixture already exists: tests/fixtures/install-projects/$fixture_name" >&2
  exit 1
fi

mkdir -p "$fixture_root/registry" "$fixture_root/expected"

cat > "$fixture_root/package.json" <<JSON
{
  "name": "$fixture_name",
  "version": "0.1.0",
  "dependencies": {
    "$package_name": "1.0.0"
  }
}
JSON

cat > "$registry_file" <<JSON
{
  "_id": "$package_name",
  "name": "$package_name",
  "description": "Fixture package $fixture_name",
  "maintainers": [],
  "dist-tags": {
    "latest": "1.0.0"
  },
  "versions": {
    "1.0.0": {
      "name": "$package_name",
      "version": "1.0.0",
      "description": "Fixture package $fixture_name",
      "dist": {
        "tarball": "https://registry.example.invalid/@rpm-fixture/$fixture_name/-/$fixture_name-1.0.0.tgz",
        "shasum": "fixture-$fixture_name-1.0.0"
      },
      "dependencies": {}
    }
  }
}
JSON

cat > "$fixture_root/expected/resolved-packages.txt" <<EOF
$package_name@1.0.0 requested 1.0.0
EOF

echo "created tests/fixtures/install-projects/$fixture_name"
echo "next: expand registry metadata and expected output for the scenario under test"
