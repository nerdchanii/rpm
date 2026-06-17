#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixtures_root="$repo_root/tests/fixtures"
install_projects_root="$fixtures_root/install-projects"

failures=0

fail() {
  echo "fixture audit failed: $*" >&2
  failures=$((failures + 1))
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "missing file ${path#$repo_root/}"
  elif [[ ! -s "$path" ]]; then
    fail "empty file ${path#$repo_root/}"
  fi
}

require_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    fail "missing directory ${path#$repo_root/}"
  fi
}

require_nonempty_dir() {
  local path="$1"
  require_dir "$path"
  if [[ -d "$path" ]] && ! find "$path" -type f -print -quit | grep -q .; then
    fail "empty directory ${path#$repo_root/}"
  fi
}

require_kebab_name() {
  local name="$1"
  local path="$2"
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "non kebab-case fixture name ${path#$repo_root/}"
  fi
}

require_file "$fixtures_root/package_manifest/manifest-minimal.json"
require_file "$fixtures_root/package_manifest/manifest-with-fields.json"
require_file "$fixtures_root/package_manifest/manifest-invalid.json"

require_nonempty_dir "$fixtures_root/lockfile"
require_nonempty_dir "$fixtures_root/registry/shared-transitive/metadata"
require_nonempty_dir "$fixtures_root/registry/shared-transitive/expected"
require_nonempty_dir "$install_projects_root"

for project in "$install_projects_root"/*; do
  [[ -d "$project" ]] || continue

  project_name="$(basename "$project")"
  require_kebab_name "$project_name" "$project"
  require_file "$project/package.json"
  require_nonempty_dir "$project/expected"
  require_nonempty_dir "$project/registry"

  for expected_file in "$project"/expected/*; do
    [[ -f "$expected_file" ]] || continue
    require_file "$expected_file"
  done

  for registry_file in "$project"/registry/*.json; do
    [[ -f "$registry_file" ]] || continue
    require_file "$registry_file"
  done
done

if [[ "$failures" -gt 0 ]]; then
  echo "fixture audit: $failures failure(s)" >&2
  exit 1
fi

echo "fixture audit: ok"
