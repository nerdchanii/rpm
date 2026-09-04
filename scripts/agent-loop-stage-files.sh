#!/usr/bin/env bash
set -euo pipefail

# Inspect the complete worktree after Codex and add only safe new files as
# intent-to-add entries. This script is copied from the trusted workflow
# checkout before an untrusted review head is checked out.

max_new_files=100
max_file_bytes=$((1024 * 1024))
max_total_bytes=$((10 * 1024 * 1024))
max_changed_files=200
new_count=0
changed_count=0
total_bytes=0

fail() {
  printf 'agent_loop_stage.error=%s\n' "$1" >&2
  exit 1
}

case "$PWD" in
  /*) checkout_root="$(pwd -P)" ;;
  *) fail "checkout-root-unavailable" ;;
esac

is_protected_path() {
  case "$1" in
    AGENTS.md|*/AGENTS.md|AGENTS.override.md|*/AGENTS.override.md|justfile|*/justfile|.github/*|.agents/*|.codex/*|.githooks/*|scripts/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_relative_path() {
  local path="$1"
  case "$path" in
    ""|/*|.|./*|../*|*/../*|*/..|.git|.git/*)
      fail "unsafe-path:${path:-empty}"
      ;;
  esac
}

check_ancestors() {
  local path="$1" parent resolved
  parent="$(dirname -- "$path")"
  while [ "$parent" != "." ] && [ "$parent" != "/" ]; do
    if [ -L "$parent" ]; then
      fail "ancestor-symlink:$parent"
    fi
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then
      fail "ancestor-not-directory:$parent"
    fi
    if [ -e "$parent" ]; then
      resolved="$(realpath -- "$parent" 2>/dev/null || true)"
      case "$resolved" in
        "$checkout_root"|"$checkout_root"/*) ;;
        *) fail "ancestor-outside-checkout:$parent" ;;
      esac
    fi
    parent="$(dirname -- "$parent")"
  done
}

link_count() {
  local path="$1" count
  count="$(stat -c '%h' -- "$path" 2>/dev/null || stat -f '%l' -- "$path" 2>/dev/null || true)"
  printf '%s\n' "$count"
}

check_regular_file() {
  local path="$1" resolved bytes links
  check_relative_path "$path"
  if is_protected_path "$path"; then
    fail "protected-path:$path"
  fi
  check_ancestors "$path"

  # A missing tracked path is a normal deletion. A missing untracked path is
  # a race or an unsafe path and must stop the package. Check -L first so a
  # dangling symlink cannot pass through the missing-file branch.
  if [ -L "$path" ]; then
    fail "symlink:$path"
  fi
  if [ ! -e "$path" ]; then
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      return 0
    fi
    fail "missing-path:$path"
  fi
  if [ ! -f "$path" ]; then
    fail "non-regular-file:$path"
  fi
  resolved="$(realpath -- "$path" 2>/dev/null || true)"
  case "$resolved" in
    "$checkout_root"/*) ;;
    *) fail "outside-checkout:$path" ;;
  esac
  links="$(link_count "$path")"
  if ! printf '%s' "$links" | grep -Eq '^[0-9]+$' || [ "$links" -ne 1 ]; then
    fail "hardlink-or-link-count-unavailable:$path"
  fi
  bytes="$(wc -c <"$path" | tr -d '[:space:]')"
  if ! printf '%s' "$bytes" | grep -Eq '^[0-9]+$'; then
    fail "file-size-unavailable:$path"
  fi
  total_bytes=$((total_bytes + bytes))
  if [ "$total_bytes" -gt "$max_total_bytes" ]; then
    fail "changed-file-size-limit"
  fi
}

count_changed_path() {
  changed_count=$((changed_count + 1))
  if [ "$changed_count" -gt "$max_changed_files" ]; then
    fail "changed-file-count-limit"
  fi
}

check_new_file_limits() {
  local path="$1" bytes
  bytes="$(wc -c <"$path" | tr -d '[:space:]')"
  if ! printf '%s' "$bytes" | grep -Eq '^[0-9]+$'; then
    fail "file-size-unavailable:$path"
  fi
  if [ "$bytes" -gt "$max_file_bytes" ]; then
    fail "file-too-large:$path"
  fi
  new_count=$((new_count + 1))
  if [ "$new_count" -gt "$max_new_files" ]; then
    fail "new-file-count-limit"
  fi
  if [ "$total_bytes" -gt "$max_total_bytes" ]; then
    fail "new-file-size-limit"
  fi
}

stage_file() {
  local path="$1"
  check_regular_file "$path"
  check_new_file_limits "$path"
}

# Inspect every tracked change before producing a patch. Protected paths and
# unsafe filesystem objects are rejected even when the change is a deletion.
while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  count_changed_path
  check_regular_file "$path"
done < <(git diff --name-only --no-renames --no-ext-diff --no-textconv -z HEAD --)

# A model may stage a newly added file before this helper runs. Apply the same
# per-file and count limits to index additions as to ordinary untracked files.
while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  check_new_file_limits "$path"
done < <(git diff --diff-filter=A --name-only --no-renames --no-ext-diff --no-textconv -z HEAD --)

# Enumerate only untracked paths that Git would include in a patch. Ignored
# build output is intentionally outside this artifact boundary; the same
# symlink, containment, size, and count checks apply to every unignored file.
while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  count_changed_path
  stage_file "$path"
done < <(git ls-files --others --exclude-standard -z)

if [ "$new_count" -gt 0 ]; then
  # The caller controls the temporary checkout; disable repository hooks while
  # adding intent-to-add entries so a model-created hook cannot run here.
  new_files=()
  while IFS= read -r -d '' path; do
    new_files+=("$path")
  done < <(git ls-files --others --exclude-standard -z)
  if [ "${#new_files[@]}" -gt 0 ]; then
    git -c core.hooksPath=/dev/null add -N -f -- "${new_files[@]}"
  fi
fi

printf 'agent_loop_stage.status=ok new_files=%s changed_files=%s bytes=%s\n' "$new_count" "$changed_count" "$total_bytes"
