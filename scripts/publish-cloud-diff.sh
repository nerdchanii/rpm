#!/usr/bin/env bash
set -euo pipefail

# Publish one result from a Codex Cloud task.  This script intentionally owns
# the small, guarded mutation surface between a Cloud checkout and GitHub.  It
# is kept as a shell script so the Action can audit the exact git and gh
# commands which are allowed to run.

readonly repository="nerdchanii/rpm"
readonly protected_base="main"
readonly max_result_bytes=1048576
readonly max_patch_bytes=10485760
readonly max_patch_files=200
readonly max_summary_bytes=4000
readonly max_validation_items=50
readonly max_validation_bytes=2048
readonly max_followup_title_bytes=256
readonly max_followup_label_bytes=100
readonly max_followup_labels=20
readonly max_thread_ids=100
readonly max_followups=5
readonly max_graphql_pages=100
readonly trusted_review_actor_bot="chatgpt-codex-connector[bot]"
readonly trusted_review_actor_login="chatgpt-codex-connector"

usage() {
  cat <<'USAGE'
usage: publish-cloud-diff.sh --mode issue|review --result <result.json> \
  --patch <code.patch> --expected-base-sha <40hex> [--expected-head-sha <40hex>] \
  --expected-issue <n> [--expected-pr <n>] \
  [--expected-head-ref <safe-ref>] --run-id <id> [--dry-run]

Apply and publish one validated Codex Cloud result.  The repository must be
nerdchanii/rpm.  --dry-run validates the result, patch, and git apply check;
it does not change the worktree, refs, or GitHub.
USAGE
}

error() {
  printf 'publish_cloud_diff.error=%s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'publish_cloud_diff.error=%s\n' "$1" >&2
  exit 2
}

mode=""
result_path=""
patch_path=""
expected_base_sha=""
expected_head_sha=""
expected_issue=""
expected_pr=""
expected_head_ref=""
run_id=""
dry_run="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      [ "$#" -ge 2 ] || usage_error "missing-mode-value"
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#--mode=}"
      shift
      ;;
    --result)
      [ "$#" -ge 2 ] || usage_error "missing-result-value"
      result_path="$2"
      shift 2
      ;;
    --result=*)
      result_path="${1#--result=}"
      shift
      ;;
    --patch)
      [ "$#" -ge 2 ] || usage_error "missing-patch-value"
      patch_path="$2"
      shift 2
      ;;
    --patch=*)
      patch_path="${1#--patch=}"
      shift
      ;;
    --expected-base-sha)
      [ "$#" -ge 2 ] || usage_error "missing-expected-base-sha-value"
      expected_base_sha="$2"
      shift 2
      ;;
    --expected-base-sha=*)
      expected_base_sha="${1#--expected-base-sha=}"
      shift
      ;;
    --expected-issue)
      [ "$#" -ge 2 ] || usage_error "missing-expected-issue-value"
      expected_issue="$2"
      shift 2
      ;;
    --expected-issue=*)
      expected_issue="${1#--expected-issue=}"
      shift
      ;;
    --expected-pr)
      [ "$#" -ge 2 ] || usage_error "missing-expected-pr-value"
      expected_pr="$2"
      shift 2
      ;;
    --expected-head-sha)
      [ "$#" -ge 2 ] || usage_error "missing-expected-head-sha-value"
      expected_head_sha="$2"
      shift 2
      ;;
    --expected-head-sha=*)
      expected_head_sha="${1#--expected-head-sha=}"
      shift
      ;;
    --expected-pr=*)
      expected_pr="${1#--expected-pr=}"
      shift
      ;;
    --expected-head-ref)
      [ "$#" -ge 2 ] || usage_error "missing-expected-head-ref-value"
      expected_head_ref="$2"
      shift 2
      ;;
    --expected-head-ref=*)
      expected_head_ref="${1#--expected-head-ref=}"
      shift
      ;;
    --run-id)
      [ "$#" -ge 2 ] || usage_error "missing-run-id-value"
      run_id="$2"
      shift 2
      ;;
    --run-id=*)
      run_id="${1#--run-id=}"
      shift
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown-arg:$1"
      ;;
  esac
done

[ "$mode" = "issue" ] || [ "$mode" = "review" ] || usage_error "invalid-mode"
[ -n "$result_path" ] || usage_error "missing-result"
[ -n "$patch_path" ] || usage_error "missing-patch"
[ -n "$expected_base_sha" ] || usage_error "missing-expected-base-sha"
[ -n "$expected_issue" ] || usage_error "missing-expected-issue"
[ -n "$run_id" ] || usage_error "missing-run-id"
[[ "$expected_base_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error "invalid-expected-base-sha"
expected_base_sha="${expected_base_sha,,}"

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_positive_integer "$expected_issue" || usage_error "invalid-expected-issue"

if [ -n "$expected_pr" ]; then
  [[ "$expected_pr" =~ ^[1-9][0-9]*$ ]] || usage_error "invalid-expected-pr"
fi

if [ -n "$expected_head_sha" ]; then
  [[ "$expected_head_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || usage_error "invalid-expected-head-sha"
  expected_head_sha="${expected_head_sha,,}"
fi

if [ "$mode" = "review" ]; then
  [ -n "$expected_pr" ] || usage_error "review-requires-expected-pr"
  [ -n "$expected_head_ref" ] || usage_error "review-requires-expected-head-ref"
  [ -n "$expected_head_sha" ] || usage_error "review-requires-expected-head-sha"
else
  [ -z "$expected_head_sha" ] || usage_error "issue-head-sha-not-allowed"
fi

if [ "$mode" = "review" ]; then
  checkout_sha="$expected_head_sha"
else
  checkout_sha="$expected_base_sha"
fi

if [ "${GITHUB_REPOSITORY:-}" != "$repository" ]; then
  error "repository-mismatch"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
policy_file="${script_dir}/../.agents/workflows/backlog-policy.json"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-publish-cloud-diff.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

validate_input_file() {
  local path="$1"
  local name="$2"
  local maximum="$3"
  local link_count size fd

  [ -e "$path" ] || error "${name}-not-found"
  [ ! -L "$path" ] || error "${name}-symlink"
  [ -f "$path" ] || error "${name}-not-regular"
  link_count="$(stat -c '%h' -- "$path" 2>/dev/null || stat -f '%l' -- "$path" 2>/dev/null || true)"
  [[ "$link_count" =~ ^[0-9]+$ ]] || error "${name}-link-count-unknown"
  [ "$link_count" -eq 1 ] || error "${name}-hardlink"
  size="$(stat -c '%s' -- "$path" 2>/dev/null || stat -f '%z' -- "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || error "${name}-size-unknown"
  [ "$size" -le "$maximum" ] || error "${name}-too-large"

  # Keep an open descriptor while copying.  The second symlink check closes a
  # simple pathname-swap gap; all later validation uses this pinned copy.
  exec {fd}<"$path" || error "${name}-open-failed"
  [ ! -L "$path" ] || {
    exec {fd}<&-
    error "${name}-symlink"
  }
  if ! cat <&"$fd" >"${temporary_dir}/${name}.input"; then
    exec {fd}<&-
    error "${name}-read-failed"
  fi
  exec {fd}<&-
}

validate_input_file "$result_path" result "$max_result_bytes"
validate_input_file "$patch_path" patch "$max_patch_bytes"
result_file="${temporary_dir}/result.input"
patch_file="${temporary_dir}/patch.input"
patch_input_size="$(wc -c <"$patch_file" | tr -d '[:space:]')"
[[ "$patch_input_size" =~ ^[0-9]+$ ]] || error "patch-size-unknown"

[ -f "$policy_file" ] || error "missing-policy"
policy_repository="$(jq -er '.repository | select(type == "string")' "$policy_file" 2>/dev/null)" || error "invalid-policy-repository"
[ "$policy_repository" = "$repository" ] || error "policy-repository-mismatch"

claimed_label="$(jq -er '.labels.claimed | select(type == "string" and length > 0)' "$policy_file" 2>/dev/null)" || error "invalid-policy-claimed-label"
review_pending_label="$(jq -er '.labels["review-pending"] | select(type == "string" and length > 0)' "$policy_file" 2>/dev/null)" || error "invalid-policy-review-label"
awaiting_merge_label="$(jq -er '.labels["awaiting-merge"] | select(type == "string" and length > 0)' "$policy_file" 2>/dev/null)" || error "invalid-policy-awaiting-label"
blocked_label="$(jq -er '.labels.blocked | select(type == "string" and length > 0)' "$policy_file" 2>/dev/null)" || error "invalid-policy-blocked-label"
max_attempts="$(jq -er '.review_correction.max_attempts | select(type == "number" and floor == . and . == 5)' "$policy_file" 2>/dev/null)" || error "invalid-policy-correction-limit"
followup_identity_label="$(jq -er '.followup.identity_label | select(type == "string" and . == "process:agent-followup")' "$policy_file" 2>/dev/null)" || error "invalid-policy-followup-label"
followup_limit="$(jq -er '.followup.max_per_source | select(type == "number" and floor == . and . > 0)' "$policy_file" 2>/dev/null)" || error "invalid-policy-followup-limit"
[ "$followup_limit" -le "$max_followups" ] || error "invalid-policy-followup-limit"

counter_label() {
  local counter="$1"
  jq -er --arg counter "$counter" '.review_correction.counter_labels[$counter] | select(type == "string" and test("^agent:correction-[0-5]$"))' "$policy_file" 2>/dev/null
}

for counter in 0 1 2 3 4 5; do
  counter_label "$counter" >/dev/null || error "invalid-policy-counter-label-$counter"
done

is_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

is_safe_thread_id() {
  [[ "$1" =~ ^[A-Za-z0-9_:-]+$ ]] && [ "${#1}" -le 256 ]
}

is_safe_branch_ref() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  [ "$ref" != "main" ] || return 1
  [ "$ref" != "master" ] || return 1
  [ "$ref" != "develop" ] || return 1
  [ "$ref" != "release" ] || return 1
  [ "$ref" != "HEAD" ] || return 1
  [[ "$ref" != refs/* ]] || return 1
  [[ "$ref" != *..* ]] || return 1
  [[ "$ref" != *'//'* ]] || return 1
  [[ "$ref" != *'@{'* ]] || return 1
  [[ "$ref" != */ ]] || return 1
  [[ "$ref" != /* ]] || return 1
  [[ "$ref" != -* ]] || return 1
  [[ "$ref" != ".git" && "$ref" != ".git/"* && "$ref" != */".git" && "$ref" != */".git/"* ]] || return 1
  [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

is_protected_path() {
  local path="$1"
  case "$path" in
    .agents|.agents/*|.codex|.codex/*|.github|.github/*|.githooks|.githooks/*|\
    .codex-cloud-result.json|result.json|code.patch|\
    .cargo|.cargo/*|clippy.toml|justfile|rust-toolchain|rust-toolchain.toml|\
    rustfmt.toml|.rustfmt.toml|\
    scripts/audit-fixtures.sh|scripts/benchmark-node-semver.mjs|\
    scripts/benchmark-semver.mjs|scripts/codex-cloud-setup.sh|\
    scripts/setup-codex-cloud-lane.sh|\
    scripts/codex-rust-analyzer.sh|scripts/install-git-hooks.sh|\
    scripts/run-local-git-hook-gate.sh|scripts/worktree-cleanup.sh|\
    scripts/worktree-setup.sh|\
    scripts/agent-loop-*|scripts/check-agent-*|scripts/check-cloud-*|\
    scripts/check-merge-*|scripts/check-workflow-*|\
    scripts/collect-pr-review-context*|scripts/create-review-followup-issue*|\
    scripts/collect-merge-gate-evidence*|scripts/publish-cloud-merge*|\
    scripts/quarantine-merge-selector-anomaly*|\
    scripts/safe-direct-merge*|scripts/validate-agent-workflow-assets*|\
    scripts/publish-cloud-diff*|scripts/validate-cloud-diff*|\
    scripts/test-*)
      return 0
      ;;
  esac
  return 1
}

validate_patch_path() {
  local raw="$1"
  local path="$raw"
  [ "$path" != "/dev/null" ] || return 0
  [[ "$path" != '"'* ]] || error "patch-quoted-path"
  [[ "$path" != *$'\r'* ]] || error "patch-path-control"
  [[ "$path" != *$'\t'* ]] || error "patch-path-tab"
  case "$path" in
    a/*|b/*) path="${path:2}" ;;
  esac
  [ -n "$path" ] || error "patch-empty-path"
  [[ "$path" != /* ]] || error "patch-absolute-path"
  [[ "$path" != ./* ]] || error "patch-dot-path"
  [[ "$path" != *'/'../* ]] || error "patch-traversal"
  [[ "$path" != ../* ]] || error "patch-traversal"
  [[ "$path" != *'/..' ]] || error "patch-traversal"
  [[ "$path" != .. ]] || error "patch-traversal"
  [[ "$path" != ".git" && "$path" != ".git/"* && "$path" != */".git" && "$path" != */".git/"* ]] || error "patch-git-internal"
  [[ "$path" != "AGENTS.md" && "$path" != */"AGENTS.md" ]] || error "patch-protected-path:$path"
  is_protected_path "$path" && error "patch-protected-path:$path"
  patch_seen["$path"]=1
}

declare -A patch_seen=()
patch_path_count=0
while IFS= read -r patch_line || [ -n "$patch_line" ]; do
  case "$patch_line" in
    ---\ *)
      patch_raw="${patch_line#--- }"
      patch_raw="${patch_raw%%$'\t'*}"
      validate_patch_path "$patch_raw"
      ;;
    +++\ *)
      patch_raw="${patch_line#+++ }"
      patch_raw="${patch_raw%%$'\t'*}"
      validate_patch_path "$patch_raw"
      ;;
    rename\ from\ *|rename\ to\ *|copy\ from\ *|copy\ to\ *)
      patch_raw="${patch_line#* }"
      validate_patch_path "$patch_raw"
      ;;
    diff\ --git\ *)
      # The ordinary ---/+++ records below provide exact names.  Binary-only
      # records have no such lines, so parse their simple Git header as well.
      patch_header="${patch_line#diff --git }"
      if [[ "$patch_header" =~ ^a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+)$ ]]; then
        validate_patch_path "a/${BASH_REMATCH[1]}"
        validate_patch_path "b/${BASH_REMATCH[2]}"
      fi
      ;;
  esac
done <"$patch_file"
patch_path_count="${#patch_seen[@]}"
if [ "$patch_path_count" -gt "$max_patch_files" ]; then
  error "patch-too-many-files"
fi

# The first shell pass above keeps compatibility with the local validator's
# ordinary git-diff output.  This second pass is deliberately stricter and
# validates the artifact as bytes before git sees it.  It rejects every
# governance file, path traversal, rename/copy, and non-regular file mode.
strict_patch_meta="$(python3 - "$patch_file" "$max_patch_files" <<'PY'
import re
import sys
import unicodedata

path, max_files_text = sys.argv[1:]
max_files = int(max_files_text)
protected = (
    ".agents/", ".codex/", ".github/", ".githooks/", ".cargo/", "scripts/agent-loop-",
    "scripts/check-agent-", "scripts/check-cloud-", "scripts/check-merge-",
    "scripts/check-workflow-", "scripts/collect-pr-review-context",
    "scripts/collect-merge-gate-evidence", "scripts/create-review-followup-issue",
    "scripts/publish-cloud-diff", "scripts/publish-cloud-merge",
    "scripts/quarantine-merge-selector-anomaly",
    "scripts/safe-direct-merge", "scripts/validate-agent-workflow-assets",
    "scripts/validate-cloud-diff", "scripts/test-",
    "scripts/test-cloud-automation", "scripts/test-codex-cloud-dispatch",
    "scripts/test-create-review-followup-issue", "scripts/test-issue-labeler",
    "scripts/test-publish-cloud-diff", "scripts/test-safe-direct-merge",
    "scripts/test-validate-cloud-diff",
)

protected_exact = {
    ".cargo", ".codex-cloud-result.json", "result.json", "code.patch",
    "clippy.toml", "justfile", "rust-toolchain", "rust-toolchain.toml",
    "rustfmt.toml", ".rustfmt.toml", "scripts/audit-fixtures.sh",
    "scripts/benchmark-node-semver.mjs", "scripts/benchmark-semver.mjs",
    "scripts/codex-cloud-setup.sh", "scripts/codex-rust-analyzer.sh",
    "scripts/setup-codex-cloud-lane.sh",
    "scripts/install-git-hooks.sh", "scripts/run-local-git-hook-gate.sh",
    "scripts/worktree-cleanup.sh", "scripts/worktree-setup.sh",
    "scripts/collect-merge-gate-evidence.sh", "scripts/publish-cloud-merge.sh",
    "scripts/quarantine-merge-selector-anomaly.sh",
}

def fail(reason):
    raise ValueError(reason)

def decode(raw):
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("path-not-utf8")
    if not value or value.startswith("/") or ":" in value:
        fail("path-absolute-or-invalid")
    if any(char.isspace() for char in value):
        fail("path-whitespace")
    if any(ord(char) < 0x20 or ord(char) == 0x7f for char in value):
        fail("path-control-character")
    if any(unicodedata.category(char).startswith("C") for char in value):
        fail("path-invisible-character")
    if any(char in "\\\"'" for char in value):
        fail("path-quoted-or-escaped")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        fail("path-traversal-or-empty-component")
    if any(part == ".git" for part in parts):
        fail("git-internal-path")
    if value == ".codex-cloud-result.json" or value == "AGENTS.md" or value.endswith("/AGENTS.md") or value in protected_exact or any(value.startswith(item) for item in protected):
        fail(f"protected-path:{value}")
    return value

def side_path(line, prefix, side_prefix):
    if not line.startswith(prefix):
        return None
    value = line[len(prefix):].rstrip(b"\r\n").split(b"\t", 1)[0]
    if value == b"/dev/null":
        return None
    if not value.startswith(side_prefix):
        fail("malformed-file-header")
    return decode(value[len(side_prefix):])

data = open(path, "rb").read()
if b"\x00" in data:
    fail("patch-nul")
sections = []
current_path = None
current_lines = None
for line in data.splitlines(keepends=True):
    if line.startswith(b"diff --git "):
        if current_path is not None:
            sections.append((current_path, current_lines))
        match = re.fullmatch(rb"diff --git (a/[^ \t\r\n]+) (b/[^ \t\r\n]+)", line.rstrip(b"\r\n"))
        if match is None:
            fail("malformed-diff-header")
        old = decode(match.group(1)[2:])
        new = decode(match.group(2)[2:])
        if old != new:
            fail("rename-or-copy")
        current_path = old
        current_lines = [line]
    elif current_lines is not None:
        current_lines.append(line)
    elif line.strip():
        fail("patch-preamble")
if current_path is not None:
    sections.append((current_path, current_lines))
if not sections:
    if data.strip():
        fail("patch-has-no-git-diff-sections")
    print("0\t0")
    raise SystemExit(0)
if len(sections) > max_files:
    fail("patch-too-many-files")
seen = set()
for file_path, lines in sections:
    if file_path in seen:
        fail("duplicate-patch-path")
    seen.add(file_path)
    old_seen = new_seen = False
    old_dev_header = new_dev_header = False
    mode_new = mode_deleted = False
    saw_hunk = False
    metadata_phase = True
    for line in lines:
        stripped = line.rstrip(b"\r\n")
        if stripped.startswith((b"GIT binary patch", b"Binary files ")):
            fail("binary-patch")
        if stripped.startswith((b"rename from ", b"rename to ", b"copy from ", b"copy to ", b"similarity index ", b"dissimilarity index ", b"Subproject commit ")):
            fail("rename-copy-or-submodule")
        if stripped.startswith((b"old mode ", b"new mode ")):
            fail("mode-change")
        for marker in (b"new file mode ", b"deleted file mode "):
            if stripped.startswith(marker):
                mode = stripped[len(marker):].strip()
                if mode != b"100644":
                    fail("symlink-or-submodule-mode")
                if marker.startswith(b"new"):
                    if mode_new or mode_deleted:
                        fail("duplicate-file-mode")
                    mode_new = True
                else:
                    if mode_new or mode_deleted:
                        fail("duplicate-file-mode")
                    mode_deleted = True
                continue
        if stripped.startswith(b"index "):
            if re.fullmatch(rb"index [0-9A-Fa-f]+\.\.[0-9A-Fa-f]+(?: 100644)?", stripped) is None:
                fail("malformed-index")
            continue
        old = side_path(line, b"--- ", b"a/")
        if line.startswith(b"--- "):
            if old_seen:
                fail("duplicate-old-header")
            if old is not None and old != file_path:
                fail("old-header-path-mismatch")
            old_seen = True
            old_dev_header = old is None
        new = side_path(line, b"+++ ", b"b/")
        if line.startswith(b"+++ "):
            if new_seen:
                fail("duplicate-new-header")
            if new is not None and new != file_path:
                fail("new-header-path-mismatch")
            new_seen = True
            new_dev_header = new is None
        if stripped.startswith(b"@@"):
            saw_hunk = True
            metadata_phase = False
            continue
        if stripped == b"\\ No newline at end of file":
            if not saw_hunk:
                fail("malformed-diff-line")
            continue
        if metadata_phase:
            if stripped == b"":
                continue
            if line.startswith((b"diff --git ", b"--- ", b"+++ ")) or stripped.startswith((b"new file mode ", b"deleted file mode ", b"index ")):
                continue
            fail("malformed-diff-line")
        elif not line.startswith((b" ", b"+", b"-")):
            fail("malformed-diff-line")
    if not old_seen or not new_seen:
        fail("missing-file-headers")
    if not saw_hunk:
        fail("missing-hunk")
    if mode_new and not old_dev_header:
        fail("new-file-mode-without-new-file")
    if mode_deleted and not new_dev_header:
        fail("deleted-file-mode-without-deletion")
print(f"{len(sections)}\t{len(sections)}")
PY
)" || error "invalid-code-patch"
read -r strict_section_count strict_path_count strict_extra <<<"$strict_patch_meta"
[ -z "${strict_extra:-}" ] || error "invalid-patch-metadata"
[[ "$strict_section_count" =~ ^[0-9]+$ && "$strict_path_count" =~ ^[0-9]+$ ]] || error "invalid-patch-metadata"
[ "$strict_path_count" = "$patch_path_count" ] || error "patch-path-count-mismatch"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || error "not-a-git-checkout"
cd "$repo_root"

assert_clean_head() {
  local actual branch_name status_output
  actual="$(git rev-parse --verify HEAD^{commit} 2>/dev/null)" || error "missing-head"
  [ "$actual" = "$checkout_sha" ] || error "head-mismatch"
  status_output="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || error "status-read-failed"
  [ -z "$status_output" ] || error "dirty-worktree"
  if ! git diff --quiet; then error "unstaged-changes"; fi
  if ! git diff --cached --quiet; then error "staged-changes"; fi
  branch_name="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$mode" = "issue" ] && [ -n "$branch_name" ] && [ "$branch_name" != "$protected_base" ]; then
    error "issue-base-branch-mismatch"
  fi
}

assert_clean_head

url_identity() {
  case "$1" in
    https://github.com/nerdchanii/rpm|https://github.com/nerdchanii/rpm.git)
      printf 'https://github.com/nerdchanii/rpm.git\n'
      ;;
    git@github.com:nerdchanii/rpm|git@github.com:nerdchanii/rpm.git)
      printf 'ssh://git@github.com/nerdchanii/rpm.git\n'
      ;;
    *)
      return 1
      ;;
  esac
}

one_remote_url() {
  local key="$1"
  local values count value
  values="$(git config --get-all "$key" 2>/dev/null || true)"
  count="$(printf '%s\n' "$values" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -eq 1 ] || return 1
  value="$(printf '%s\n' "$values" | sed -n '1p')"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

verify_remote_identity() {
  local fetch_url push_url fetch_identity push_identity
  fetch_url="$(one_remote_url remote.origin.url)" || error "origin-fetch-url-count"
  push_url="$(git config --get-all remote.origin.pushurl 2>/dev/null || true)"
  if [ -z "$push_url" ]; then
    push_url="$fetch_url"
  else
    local push_count
    push_count="$(printf '%s\n' "$push_url" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$push_count" -eq 1 ] || error "origin-push-url-count"
    push_url="$(printf '%s\n' "$push_url" | sed -n '1p')"
  fi
  fetch_identity="$(url_identity "$fetch_url")" || error "origin-fetch-url-identity"
  push_identity="$(url_identity "$push_url")" || error "origin-push-url-identity"
  [ "$fetch_identity" = "$push_identity" ] || error "origin-url-identity-mismatch"
  # Use a captured, canonical HTTPS endpoint.  The refspec remains explicit,
  # so a later local remote-name mutation cannot redirect the write.
  verified_push_url="https://github.com/nerdchanii/rpm.git"
}

verify_remote_identity

remote_ref_sha() {
  local url="$1"
  local ref="$2"
  local output line count sha
  output="$(git ls-remote --refs "$url" "$ref" 2>/dev/null)" || error "remote-ref-read-failed"
  count="$(printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }')"
  if [ "$count" -eq 0 ]; then
    printf '\n'
    return 0
  fi
  [ "$count" -eq 1 ] || error "remote-ref-ambiguous"
  line="$(printf '%s\n' "$output" | sed -n '1p')"
  sha="${line%%[[:space:]]*}"
  is_sha "${sha,,}" || error "remote-ref-invalid-sha"
  printf '%s\n' "${sha,,}"
}

result_keys='["actionable_findings_remaining","base_sha","correction_label","followups","head_sha","issue","lane","next_state","pr","resolved_thread_ids","status","summary","validation","version"]'
if ! jq -e \
  --argjson expected_keys "$result_keys" \
  --argjson followup_limit "$followup_limit" \
  --argjson summary_limit "$max_summary_bytes" \
  --argjson validation_limit "$max_validation_bytes" \
  --argjson followup_title_limit "$max_followup_title_bytes" \
  --argjson followup_label_limit "$max_followup_label_bytes" \
  --argjson followup_label_count "$max_followup_labels" '
  type == "object" and (keys | sort) == ($expected_keys | sort) and
  .version == 1 and (.lane | type == "string") and (.status | type == "string") and
  (.issue | type == "number" and floor == . and . > 0) and
  ((.pr == null) or (.pr | type == "number" and floor == . and . > 0)) and
  (.base_sha | type == "string" and test("^[0-9a-f]{40}$")) and
  ((.head_sha == null) or (.head_sha | type == "string" and test("^[0-9a-f]{40}$"))) and
  (.summary | type == "string" and length <= $summary_limit) and
  (.validation | type == "array" and length <= 50 and all(.[]; type == "string" and length <= $validation_limit)) and
  (.actionable_findings_remaining | type == "boolean") and
  (.next_state | type == "string") and
  ((.correction_label == null) or (.correction_label | type == "string")) and
  (.resolved_thread_ids | type == "array" and length <= 100 and all(.[]; type == "string" and length > 0 and length <= 256)) and
  (.followups | type == "array" and length <= $followup_limit and all(.[];
    type == "object" and
    (keys | sort) == ["body","fingerprint","labels","source","title"] and
    (.title | type == "string" and length > 0 and length <= $followup_title_limit and (index("\n") == null) and (index("\r") == null)) and
    (.body | type == "string" and length > 0 and length <= 131072) and
    (.source | type == "string" and test("^(pr|issue):[1-9][0-9]*$")) and
    (.fingerprint | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.labels | type == "array" and length <= $followup_label_count and all(.[]; type == "string" and length > 0 and length <= $followup_label_limit and (index("\n") == null) and (index("\r") == null)))
  ))
' "$result_file" >/dev/null 2>&1; then
  error "invalid-result-schema"
fi

if ! jq -e '
  all(.followups[];
    . as $followup |
    (($followup.body | split("\n")[0]) == ("<!-- rpm-agent-followup-source: " + $followup.source + " -->")) and
    (($followup.body | contains("rpm-agent-followup-fingerprint:")) | not)
  )
' "$result_file" >/dev/null 2>&1; then
  error "invalid-followup-canonical-body"
fi

# jq is useful for shape checks, while this independent parser also rejects
# duplicate JSON keys and verifies the follow-up identity bytes.  The result
# file is transport data from Cloud, so the publisher keeps this second gate.
if ! python3 - "$result_file" "$mode" "$expected_base_sha" "$expected_pr" \
  "$max_summary_bytes" "$max_validation_bytes" "$max_followup_title_bytes" \
  "$max_followup_label_bytes" "$max_followup_labels" <<'PY'
import hashlib
import json
import re
import sys

(
    path,
    lane,
    expected_base,
    expected_pr,
    summary_limit,
    validation_limit,
    followup_title_limit,
    followup_label_limit,
    followup_label_count,
) = sys.argv[1:]
summary_limit = int(summary_limit)
validation_limit = int(validation_limit)
followup_title_limit = int(followup_title_limit)
followup_label_limit = int(followup_label_limit)
followup_label_count = int(followup_label_count)

class Invalid(Exception):
    pass

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid("duplicate-json-key")
        result[key] = value
    return result

def reject_constant(value):
    raise Invalid("invalid-json-number:" + value)

def text(value, limit, allow_newlines=False):
    if type(value) is not str or not value or len(value.encode("utf-8")) > limit:
        raise Invalid("invalid-text")
    for char in value:
        if ord(char) < 0x20 or ord(char) == 0x7f:
            if not (allow_newlines and char in "\n\t"):
                raise Invalid("text-control-character")
    return value

try:
    with open(path, "rb") as stream:
        value = json.loads(stream.read().decode("utf-8"), object_pairs_hook=unique, parse_constant=reject_constant)
    keys = {"version", "lane", "status", "issue", "pr", "base_sha", "head_sha", "summary", "validation", "actionable_findings_remaining", "next_state", "correction_label", "resolved_thread_ids", "followups"}
    if type(value) is not dict or set(value) != keys or value["version"] != 1 or value["lane"] != lane:
        raise Invalid("schema-keys-or-version")
    if type(value["issue"]) is not int or value["issue"] <= 0:
        raise Invalid("issue-invalid")
    if value["base_sha"] != expected_base or re.fullmatch(r"[0-9a-f]{40}", value["base_sha"]) is None:
        raise Invalid("base-sha-invalid")
    if lane == "issue":
        if value["pr"] is not None or value["head_sha"] is not None:
            raise Invalid("issue-pr-or-head-invalid")
        allowed_sources = {f"issue:{value['issue']}"}
    else:
        if type(value["pr"]) is not int or value["pr"] <= 0 or str(value["pr"]) != expected_pr:
            raise Invalid("pr-invalid")
        if type(value["head_sha"]) is not str or re.fullmatch(r"[0-9a-f]{40}", value["head_sha"]) is None:
            raise Invalid("head-sha-invalid")
        allowed_sources = {f"issue:{value['issue']}", f"pr:{value['pr']}"}
    text(value["summary"], summary_limit)
    if type(value["validation"]) is not list or len(value["validation"]) > 50:
        raise Invalid("validation-invalid")
    for item in value["validation"]:
        text(item, validation_limit)
    if type(value["actionable_findings_remaining"]) is not bool:
        raise Invalid("actionable-invalid")
    if value["next_state"] not in {"unchanged", "review-pending", "awaiting-merge", "blocked"}:
        raise Invalid("next-state-invalid")
    correction = value["correction_label"]
    if correction is not None and re.fullmatch(r"agent:correction-[0-5]", correction) is None:
        raise Invalid("correction-label-invalid")
    thread_ids = value["resolved_thread_ids"]
    if type(thread_ids) is not list or len(thread_ids) > 100 or len(set(thread_ids)) != len(thread_ids):
        raise Invalid("thread-list-invalid")
    for thread_id in thread_ids:
        if type(thread_id) is not str or re.fullmatch(r"[A-Za-z0-9_:-]{1,256}", thread_id) is None:
            raise Invalid("thread-id-invalid")
    followups = value["followups"]
    if type(followups) is not list or len(followups) > 5:
        raise Invalid("followup-list-invalid")
    seen = set()
    for followup in followups:
        if type(followup) is not dict or set(followup) != {"title", "body", "source", "fingerprint", "labels"}:
            raise Invalid("followup-schema-invalid")
        title = text(followup["title"], followup_title_limit)
        body = text(followup["body"], 131072, True)
        source = followup["source"]
        marker = f"<!-- rpm-agent-followup-source: {source} -->"
        if source not in allowed_sources or not (body == marker or body.startswith(marker + "\n")) or body.count(marker) != 1:
            raise Invalid("followup-source-invalid")
        if re.search(r"^\s*<!--[ \t]*rpm-agent-followup-fingerprint:", body, re.MULTILINE):
            raise Invalid("followup-fingerprint-marker-forbidden")
        fingerprint = followup["fingerprint"]
        if type(fingerprint) is not str or re.fullmatch(r"sha256:[0-9a-f]{64}", fingerprint) is None:
            raise Invalid("followup-fingerprint-invalid")
        expected = "sha256:" + hashlib.sha256(title.encode() + b"\0" + body.encode()).hexdigest()
        if fingerprint != expected or fingerprint in seen:
            raise Invalid("followup-identity-invalid")
        seen.add(fingerprint)
        labels = followup["labels"]
        if type(labels) is not list or len(labels) > followup_label_count or len(set(labels)) != len(labels):
            raise Invalid("followup-labels-invalid")
        for label in labels:
            text(label, followup_label_limit)
            if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._+/&#()'\\-]*", label) is None:
                raise Invalid("followup-label-invalid")
            if label.startswith(("agent:", "process:", "codex-label")):
                raise Invalid("followup-reserved-label")
    status = value["status"]
    actionable = value["actionable_findings_remaining"]
    next_state = value["next_state"]
    if lane == "issue":
        if thread_ids:
            raise Invalid("issue-thread-ids-invalid")
        if status == "patch":
            if next_state != "review-pending" or actionable is not False or correction != "agent:correction-0":
                raise Invalid("issue-patch-state-invalid")
        elif status == "no-work":
            if next_state != "unchanged" or actionable is not False or correction is not None or followups:
                raise Invalid("issue-no-work-state-invalid")
        elif status != "blocked" or next_state != "blocked" or correction is not None:
            raise Invalid("issue-blocked-state-invalid")
    elif status == "patch":
        if correction is None or re.fullmatch(r"agent:correction-[1-5]", correction) is None:
            raise Invalid("review-patch-counter-invalid")
        if next_state != "review-pending" or actionable is not True:
            raise Invalid("review-patch-state-invalid")
    elif status == "no-work":
        if next_state not in {"unchanged", "awaiting-merge"} or actionable is not False or correction is not None:
            raise Invalid("review-no-work-state-invalid")
        if next_state == "unchanged" and (thread_ids or followups):
            raise Invalid("review-no-work-state-invalid")
        if next_state == "awaiting-merge" and thread_ids:
            raise Invalid("review-no-work-thread-ids-invalid")
    elif status != "blocked" or next_state != "blocked" or correction is not None or thread_ids:
        raise Invalid("review-blocked-state-invalid")
except Invalid as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
except Exception as exc:
    print("result-parse-failed:" + type(exc).__name__, file=sys.stderr)
    raise SystemExit(1)
PY
then
  error "invalid-result-integrity"
fi

result_lane="$(jq -r '.lane' "$result_file")"
result_status="$(jq -r '.status' "$result_file")"
result_issue="$(jq -r '.issue | tostring' "$result_file")"
result_pr="$(jq -r 'if .pr == null then "" else (.pr | tostring) end' "$result_file")"
result_base_sha="$(jq -r '.base_sha' "$result_file")"
result_head_sha="$(jq -r 'if .head_sha == null then "" else .head_sha end' "$result_file")"
result_next_state="$(jq -r '.next_state' "$result_file")"
result_correction_label="$(jq -r 'if .correction_label == null then "" else .correction_label end' "$result_file")"
result_summary="$(jq -r '.summary' "$result_file")"
result_actionable="$(jq -r '.actionable_findings_remaining' "$result_file")"

[ "$result_lane" = "$mode" ] || error "result-lane-mismatch"
[ "$result_issue" = "$expected_issue" ] || error "result-issue-mismatch"
[ "$result_base_sha" = "$expected_base_sha" ] || error "result-base-sha-mismatch"
case "$result_status" in
  patch|no-work|blocked) ;;
  *) error "invalid-result-status" ;;
esac

if [ "$mode" = "issue" ]; then
  [ -z "$result_pr" ] || error "issue-result-pr-must-be-null"
  [ -z "$result_head_sha" ] || error "issue-result-head-must-be-null"
  case "$result_status:$result_next_state" in
    patch:review-pending)
      [ "$result_actionable" = "false" ] || error "issue-patch-has-actionable-findings"
      ;;
    no-work:unchanged)
      [ "$result_actionable" = "false" ] || error "issue-no-work-has-actionable-findings"
      [ -z "$result_correction_label" ] || error "issue-nonpatch-counter-present"
      [ "$(jq '.followups | length' "$result_file")" -eq 0 ] || error "issue-no-work-followups-forbidden"
      ;;
    blocked:blocked) ;;
    *) error "invalid-issue-status-state" ;;
  esac
  if [ "$result_status" = "patch" ]; then
    [ "$result_correction_label" = "$(counter_label 0)" ] || error "issue-patch-counter-mismatch"
  else
    [ -z "$result_correction_label" ] || error "issue-nonpatch-counter-present"
  fi
else
  [ "$result_pr" = "$expected_pr" ] || error "review-result-pr-mismatch"
  [ "$result_head_sha" = "$expected_head_sha" ] || error "review-result-head-mismatch"
  case "$result_status:$result_next_state" in
    patch:review-pending)
      [ "$result_actionable" = "true" ] || error "review-pending-findings-mismatch"
      ;;
    patch:awaiting-merge)
      error "review-patch-awaiting-merge-forbidden"
      ;;
    no-work:unchanged)
      [ "$result_actionable" = "false" ] || error "review-no-work-has-actionable-findings"
      [ -z "$result_correction_label" ] || error "review-nonpatch-counter-present"
      [ "$(jq '.resolved_thread_ids | length' "$result_file")" -eq 0 ] || error "review-no-work-state-incoherent"
      [ "$(jq '.followups | length' "$result_file")" -eq 0 ] || error "review-no-work-state-incoherent"
      ;;
    no-work:awaiting-merge)
      [ "$result_actionable" = "false" ] || error "awaiting-merge-has-actionable-findings"
      [ -z "$result_correction_label" ] || error "review-nonpatch-counter-present"
      [ "$(jq '.resolved_thread_ids | length' "$result_file")" -eq 0 ] || error "review-no-work-thread-ids-invalid"
      ;;
    blocked:blocked) ;;
    *) error "invalid-review-status-state" ;;
  esac
  if [ "$result_status" = "patch" ]; then
    [[ "$result_correction_label" =~ ^agent:correction-[1-5]$ ]] || error "review-patch-counter-invalid"
  fi
fi

if [ "$result_next_state" = "awaiting-merge" ] && [ "$result_actionable" != "false" ]; then
  error "awaiting-merge-has-actionable-findings"
fi

if [ "$result_status" != "patch" ] && [ "$patch_input_size" -ne 0 ]; then
  # A non-patch result may carry an empty handoff patch.  Any actual code
  # patch is rejected so a blocked/no-work result cannot smuggle a mutation.
  error "nonpatch-result-has-code-patch"
fi

if [ "$result_status" = "patch" ]; then
  [ "$patch_path_count" -gt 0 ] || error "patch-result-is-empty"
  if ! git -c core.hooksPath=/dev/null apply --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    error "patch-apply-check-failed"
  fi
fi

# Keep the old-side hunk ranges from the validated patch.  Review thread
# claims are allowed to resolve only when their original line overlaps one of
# these ranges and their path is part of the exact patch being published.
patch_review_context_file="${temporary_dir}/patch-review-context.json"
if ! python3 - "$patch_file" >"$patch_review_context_file" <<'PY'
import json
import re
import sys

data = open(sys.argv[1], "rb").read()
sections = []
current = None
for raw in data.splitlines():
    if raw.startswith(b"diff --git "):
        match = re.fullmatch(rb"diff --git (a/[^ \t\r\n]+) (b/[^ \t\r\n]+)", raw)
        if match is None or match.group(1)[2:] != match.group(2)[2:]:
            raise ValueError("malformed-diff-header")
        path = match.group(1)[2:].decode("utf-8")
        current = {"path": path, "hunks": []}
        sections.append(current)
    elif current is not None and raw.startswith(b"@@"):
        match = re.match(rb"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", raw)
        if match is None:
            raise ValueError("malformed-hunk-header")
        old_start = int(match.group(1))
        old_count = int(match.group(2) or b"1")
        if old_count:
            current["hunks"].append({"start": old_start, "end": old_start + old_count - 1})

print(json.dumps({
    "paths": [section["path"] for section in sections],
    "hunks": [
        {"path": section["path"], **hunk}
        for section in sections
        for hunk in section["hunks"]
    ],
}, separators=(",", ":")))
PY
then
  error "invalid-patch-review-context"
fi

sanitize_run_id() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g')"
  [ -n "$cleaned" ] || cleaned="run"
  printf '%s\n' "${cleaned:0:48}"
}

safe_run_id="$(sanitize_run_id "$run_id")"
if [ "$mode" = "issue" ]; then
  branch_ref="feat/issue-${result_issue}-codex-cloud-${safe_run_id}"
  is_safe_branch_ref "$branch_ref" || error "generated-branch-invalid"
else
  branch_ref="$expected_head_ref"
  is_safe_branch_ref "$branch_ref" || error "unsafe-head-ref"
fi

emit_result() {
  local status="$1"
  local reason="$2"
  local pr_url="${3:-}"
  local head_sha="${4:-}"
  jq -nc \
    --arg mode "$mode" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg issue "$result_issue" \
    --arg pr "$pr_url" \
    --arg branch "$branch_ref" \
    --arg head "$head_sha" \
    '{type:"cloud_diff_publish_result",data:{mode:$mode,status:$status,reason:$reason,issue:($issue|tonumber),pr:(if $pr == "" then null else $pr end),head_ref:$branch,head_sha:(if $head == "" then null else $head end)}}'
}

if [ "$dry_run" = "true" ]; then
  # No gh, branch, index, commit, or remote operation is allowed in dry-run.
  emit_result "$result_status" "dry-run-validated"
  exit 0
fi

[ -n "${GH_TOKEN:-}" ] || error "missing-gh-token"
command -v gh >/dev/null 2>&1 || error "missing-gh"
command -v jq >/dev/null 2>&1 || error "missing-jq"

issue_json=""
pr_json=""

read_issue() {
  [ "$#" -eq 1 ] || error "read-issue-requires-number"
  local issue="$1"
  gh issue view "$issue" --repo "$repository" --json number,state,title,body,labels
}

read_pr() {
  local pr="$1"
  gh pr view "$pr" --repo "$repository" --json number,url,title,body,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,headRepository,headRepositoryOwner,labels
}

validate_issue_json() {
  local json="$1"
  jq -e '
    type == "object" and
    (.number | type == "number" and floor == . and . > 0) and
    (.state | type == "string") and
    (.title | type == "string") and
    ((.body == null) or (.body | type == "string")) and
    (.labels | type == "array" and all(.[]; ((type == "object" and (.name | type == "string")) or type == "string")))
  ' <<<"$json" >/dev/null 2>&1 || error "invalid-issue-response"
  [ "$(jq -r '.number | tostring' <<<"$json")" = "$result_issue" ] || error "issue-number-mismatch"
  [ "$(jq -r '.state' <<<"$json" | tr '[:lower:]' '[:upper:]')" = "OPEN" ] || error "issue-not-open"
}

issue_labels() {
  jq -r '.labels[] | if type == "object" then .name else . end' <<<"$1"
}

ordinary_issue_labels() {
  issue_labels "$1" |
    grep -Fvx -e "$claimed_label" -e "$review_pending_label" \
      -e "$awaiting_merge_label" -e "$blocked_label" | sort || true
}

label_count() {
  local labels="$1"
  local wanted="$2"
  printf '%s\n' "$labels" | awk -v wanted="$wanted" '$0 == wanted { count++ } END { print count + 0 }'
}

validate_exact_issue_state() {
  local json="$1"
  local expected_state_label="$2"
  local labels state_count
  labels="$(issue_labels "$json")"
  for state_label in "$claimed_label" "$review_pending_label" "$awaiting_merge_label" "$blocked_label"; do
    state_count="$(label_count "$labels" "$state_label")"
    [ "$state_count" -le 1 ] || error "duplicate-lifecycle-label"
  done
  [ "$(label_count "$labels" "$expected_state_label")" -eq 1 ] || error "issue-state-mismatch"
  for state_label in "$claimed_label" "$review_pending_label" "$awaiting_merge_label" "$blocked_label"; do
    if [ "$state_label" != "$expected_state_label" ]; then
      [ "$(label_count "$labels" "$state_label")" -eq 0 ] || error "issue-conflicting-lifecycle-label"
    fi
  done
}

verify_awaiting_merge_pr_head() {
  local expected_sha="$1" pr_snapshot actual_head
  [ "$mode" = "review" ] || error "awaiting-merge-review-mode-required"
  is_sha "$expected_sha" || error "awaiting-merge-head-invalid"
  pr_snapshot="$(read_pr "$expected_pr")" || error "awaiting-merge-pr-read-failed"
  actual_head="$(jq -r '.headRefOid' <<<"$pr_snapshot" | tr '[:upper:]' '[:lower:]')"
  [ "$actual_head" = "$expected_sha" ] || error "awaiting-merge-pr-head-mismatch"
  validate_pr_json "$pr_snapshot" "$expected_sha"
}

transition_issue() {
  local from_label="$1" to_label="$2"
  local issue_before issue_after ordinary_before ordinary_after
  issue_before="$(read_issue "$result_issue")" || error "issue-transition-pre-read-failed"
  validate_issue_json "$issue_before"
  validate_exact_issue_state "$issue_before" "$from_label"
  ordinary_before="$(ordinary_issue_labels "$issue_before")"
  if [ "$mode" = "review" ] && [ "$to_label" = "$awaiting_merge_label" ]; then
    verify_pr_closing_issue_binding "$expected_pr"
    verify_live_no_unresolved_review_threads
    verify_awaiting_merge_pr_head "$expected_head_sha"
  fi
  gh issue edit "$result_issue" --repo "$repository" --remove-label "$from_label" --add-label "$to_label" >/dev/null 2>&1 || error "issue-transition-failed"
  issue_after="$(read_issue "$result_issue")" || error "issue-transition-refetch-failed"
  validate_issue_json "$issue_after"
  validate_exact_issue_state "$issue_after" "$to_label"
  ordinary_after="$(ordinary_issue_labels "$issue_after")"
  [ "$ordinary_before" = "$ordinary_after" ] || error "issue-transition-ordinary-labels-changed"
}

pr_labels() {
  jq -r '.labels[] | if type == "object" then .name else . end' <<<"$1"
}

ordinary_pr_labels() {
  pr_labels "$1" | grep -Ev '^agent:correction-[0-5]$' | sort || true
}

validate_pr_correction_inventory() {
  local json="$1" labels correction_labels correction_count
  labels="$(pr_labels "$json")"
  correction_labels="$(printf '%s\n' "$labels" | grep -E '^agent:correction-[0-5]$' || true)"
  correction_count="$(printf '%s\n' "$correction_labels" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$correction_count" -le 1 ] || error "pr-correction-label-conflict"
}

pr_correction_label() {
  local json="$1" labels correction_labels correction_count
  labels="$(pr_labels "$json")"
  correction_labels="$(printf '%s\n' "$labels" | grep -E '^agent:correction-[0-5]$' || true)"
  correction_count="$(printf '%s\n' "$correction_labels" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$correction_count" -eq 1 ] || error "pr-correction-label-count"
  printf '%s\n' "$correction_labels" | sed -n '1p'
}

validate_pr_json() {
  local json="$1"
  local expected_head="${2:-$expected_head_sha}"
  jq -e '
    type == "object" and
    (.number | type == "number" and floor == . and . > 0) and
    (.url | type == "string") and (.body | type == "string") and
    (.state | type == "string") and (.isDraft | type == "boolean") and
    (.baseRefName | type == "string") and (.baseRefOid | type == "string") and (.headRefName | type == "string") and
    (.headRefOid | type == "string") and (.labels | type == "array")
  ' <<<"$json" >/dev/null 2>&1 || error "invalid-pr-response"
  [ "$(jq -r '.url' <<<"$json")" = "https://github.com/${repository}/pull/$(jq -r '.number | tostring' <<<"$json")" ] || error "pr-url-mismatch"
  [ "$(jq -r '.state' <<<"$json" | tr '[:lower:]' '[:upper:]')" = "OPEN" ] || error "pr-not-open"
  [ "$(jq -r '.baseRefName' <<<"$json")" = "$protected_base" ] || error "pr-base-not-protected-base"
  [ "$(jq -r '.baseRefOid' <<<"$json" | tr '[:upper:]' '[:lower:]')" = "$expected_base_sha" ] || error "pr-base-sha-mismatch"
  [ "$(jq -r '.headRefName' <<<"$json")" = "$branch_ref" ] || error "pr-head-ref-mismatch"
  is_safe_branch_ref "$branch_ref" || error "unsafe-head-ref"
  [ "$(jq -r '.headRefOid' <<<"$json" | tr '[:upper:]' '[:lower:]')" = "$expected_head" ] || error "pr-head-sha-mismatch"
  head_repository="$(jq -r '
    if (.headRepository | type) == "object" then (.headRepository.nameWithOwner // .headRepository.fullName // "")
    elif (.headRepository | type) == "string" then .headRepository
    else "" end
  ' <<<"$json")"
  [ "$head_repository" = "$repository" ] || error "pr-head-repository-mismatch"
  body="$(jq -r '.body' <<<"$json")"
  printf '%s\n' "$body" | grep -Eiq "(^|[^[:alnum:]])(closes|fixes|resolves)[[:space:]]+#${result_issue}([^0-9]|$)" || error "pr-closing-issue-mismatch"
}

# GitHub's closingIssuesReferences connection is the source of truth for the
# issue a PR actually closes.  The PR body and timeline are only hints.  Read
# every connection page and reject malformed, duplicate, or incomplete data.
closing_references_query='query($number:Int!,$after:String){repository(owner:"nerdchanii",name:"rpm"){pullRequest(number:$number){number,repository{nameWithOwner},closingIssuesReferences(first:100,after:$after){pageInfo{hasNextPage,endCursor},nodes{number,repository{nameWithOwner}}}}}}'

verify_pr_closing_issue_binding() {
  local pr_number="$1" response after="" cursor has_next page=0 nodes all_refs='[]'
  local -a gh_args
  is_positive_integer "$pr_number" || error "closing-reference-pr-invalid"
  while :; do
    page=$((page + 1))
    [ "$page" -le "$max_graphql_pages" ] || error "closing-reference-pagination-limit"
    gh_args=(api graphql --repo "$repository" -f query="$closing_references_query" -F number="$pr_number")
    if [ -n "$after" ]; then
      gh_args+=(-f after="$after")
    fi
    response="$(gh "${gh_args[@]}" 2>/dev/null)" || error "closing-reference-read-failed"
    jq -s -e --arg repo "$repository" --argjson pr "$pr_number" '
      (length == 1) and
      (.[0] |
        type == "object" and
        ((.errors? == null) or (.errors | type == "array" and length == 0)) and
        (.data.repository.pullRequest | type == "object") and
        .data.repository.pullRequest.number == $pr and
        .data.repository.pullRequest.repository.nameWithOwner == $repo and
        (.data.repository.pullRequest.closingIssuesReferences | type == "object") and
        (.data.repository.pullRequest.closingIssuesReferences.pageInfo | type == "object") and
        (.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage | type == "boolean") and
        ((.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor // null) == null or
         (.data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor | type == "string")) and
        (.data.repository.pullRequest.closingIssuesReferences.nodes | type == "array") and
        all(.data.repository.pullRequest.closingIssuesReferences.nodes[];
          type == "object" and
          (.number | type == "number" and floor == . and . > 0) and
          (.repository | type == "object") and
          (.repository.nameWithOwner == $repo)
        ))
    ' <<<"$response" >/dev/null 2>&1 || error "closing-reference-response-invalid"
    nodes="$(jq -s -ce '.[0].data.repository.pullRequest.closingIssuesReferences.nodes' <<<"$response")" || error "closing-reference-nodes-invalid"
    all_refs="$(jq -ce --argjson nodes "$nodes" '. + $nodes' <<<"$all_refs")" || error "closing-reference-accumulate-failed"
    has_next="$(jq -s -r '.[0].data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage' <<<"$response")"
    [ "$has_next" = "true" ] || [ "$has_next" = "false" ] || error "closing-reference-page-info-invalid"
    cursor="$(jq -s -r '.[0].data.repository.pullRequest.closingIssuesReferences.pageInfo.endCursor // ""' <<<"$response")"
    if [ "$has_next" = "true" ]; then
      [ -n "$cursor" ] || error "closing-reference-cursor-missing"
      [ "$cursor" != "$after" ] || error "closing-reference-cursor-repeated"
      after="$cursor"
    else
      break
    fi
  done

  jq -e --argjson issue "$result_issue" '
    (length == (unique_by(.number) | length)) and
    ([.[] | select(.number == $issue)] | length == 1)
  ' <<<"$all_refs" >/dev/null 2>&1 || {
    if jq -e --argjson issue "$result_issue" '[.[] | select(.number == $issue)] | length > 0' <<<"$all_refs" >/dev/null 2>&1; then
      error "closing-reference-duplicate"
    fi
    error "closing-issue-binding-missing"
  }
}

if [ "$result_status" = "patch" ] || [ "$result_status" = "blocked" ]; then
  issue_json="$(read_issue "$result_issue")" || error "issue-read-failed"
  validate_issue_json "$issue_json"
fi

if [ "$mode" = "issue" ]; then
  if [ "$result_status" = "no-work" ]; then
    issue_json="$(read_issue "$result_issue")" || error "no-work-issue-read-failed"
    validate_issue_json "$issue_json"
  elif [ "$result_status" = "patch" ]; then
    validate_exact_issue_state "$issue_json" "$claimed_label"
  fi
  if [ "$result_status" = "patch" ]; then
    existing_branch_sha="$(remote_ref_sha "$verified_push_url" "refs/heads/$branch_ref")"
    expected_remote_sha="$existing_branch_sha"
    if [ -n "$existing_branch_sha" ] && [ "$existing_branch_sha" != "$expected_base_sha" ]; then
      error "existing-branch-head-mismatch"
    fi
    if ! pr_list_json="$(gh pr list --repo "$repository" --state open --head "$branch_ref" --base "$protected_base" --limit 100 --json number,url,title,body,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,headRepository,headRepositoryOwner,labels)"; then
      error "pr-list-failed"
    fi
    jq -e 'type == "array" and length <= 100' <<<"$pr_list_json" >/dev/null 2>&1 || error "invalid-pr-list-response"
    matching_pr_json="$(jq -c --arg branch "$branch_ref" --arg base "$protected_base" --arg repo "$repository" '[.[] | select(.baseRefName == $base and .headRefName == $branch and ((.headRepository.nameWithOwner // .headRepository.fullName // .headRepository // "") == $repo))]' <<<"$pr_list_json")"
    matching_pr_count="$(jq 'length' <<<"$matching_pr_json")"
    [ "$matching_pr_count" -le 1 ] || error "multiple-matching-prs"
  fi
else
  if [ "$result_status" != "blocked" ]; then
    pr_json="$(read_pr "$expected_pr")" || error "pr-read-failed"
    validate_pr_json "$pr_json"
    issue_json="$(read_issue "$result_issue")" || error "issue-read-failed"
    validate_issue_json "$issue_json"
    validate_exact_issue_state "$issue_json" "$review_pending_label"
    remote_review_sha="$(remote_ref_sha "$verified_push_url" "refs/heads/$branch_ref")"
    [ "$remote_review_sha" = "$expected_head_sha" ] || error "remote-review-head-mismatch"
    if [ "$result_status" = "patch" ]; then
      labels="$(pr_labels "$pr_json")"
      correction_labels="$(printf '%s\n' "$labels" | grep -E '^agent:correction-[0-5]$' || true)"
      correction_count="$(printf '%s\n' "$correction_labels" | awk 'NF { count++ } END { print count + 0 }')"
      [ "$correction_count" -eq 1 ] || error "pr-correction-label-count"
      current_correction_label="$(printf '%s\n' "$correction_labels" | sed -n '1p')"
      current_counter="${current_correction_label##*-}"
      expected_counter=$((current_counter + 1))
      [ "$expected_counter" -le "$max_attempts" ] || error "correction-limit-exceeded"
      [ "$result_correction_label" = "$(counter_label "$expected_counter")" ] || error "review-counter-sequence-mismatch"
    fi
  fi
fi

apply_and_commit() {
  local commit_message="$1"
  assert_clean_head
  if ! git -c core.hooksPath=/dev/null apply --index --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    error "patch-apply-failed"
  fi

  local staged_path staged_count diff_bytes
  declare -A staged_seen=()
  staged_count=0
  while IFS= read -r -d '' staged_path; do
    validate_patch_path "$staged_path"
    if [ -z "${staged_seen["$staged_path"]+x}" ]; then
      staged_seen["$staged_path"]=1
      staged_count=$((staged_count + 1))
    fi
  done < <(git diff --cached --name-only -z)
  [ "$staged_count" -gt 0 ] || error "applied-patch-empty"
  [ "$staged_count" -le "$max_patch_files" ] || error "applied-patch-too-many-files"
  diff_bytes="$(git diff --cached --binary | wc -c | tr -d '[:space:]')"
  [[ "$diff_bytes" =~ ^[0-9]+$ ]] || error "applied-patch-size-unknown"
  [ "$diff_bytes" -le "$max_patch_bytes" ] || error "applied-patch-too-large"
  git -c core.hooksPath=/dev/null diff --cached --check >/dev/null 2>&1 || error "staged-diff-check-failed"
  git -c core.hooksPath=/dev/null \
    -c user.name='Codex Cloud Publisher' \
    -c user.email='codex-cloud-publisher@users.noreply.github.com' \
    commit -m "$commit_message" >/dev/null 2>&1 || error "commit-failed"
  assert_clean_head_after_commit
}

assert_clean_head_after_commit() {
  local status_output
  status_output="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || error "status-read-failed"
  [ -z "$status_output" ] || error "post-commit-dirty-worktree"
}

push_captured_ref() {
  local ref="$1"
  local expected_remote="$2"
  local current_remote lease_ref lease
  is_safe_branch_ref "$ref" || error "unsafe-push-ref"
  verify_remote_identity
  current_remote="$(remote_ref_sha "$verified_push_url" "refs/heads/$ref")"
  [ "$current_remote" = "$expected_remote" ] || error "pre-push-remote-head-race"

  # A fast-forward-only push by itself does not protect the exact value read
  # above: another writer may advance the branch and our commit could still
  # be accepted as a fast-forward.  Keep the normal ancestry policy while
  # passing the captured old SHA as the server-side lease, so any update after
  # the read is rejected atomically.
  if [ -n "$expected_remote" ] && ! git merge-base --is-ancestor "$expected_remote" HEAD >/dev/null 2>&1; then
    error "non-fast-forward-push"
  fi
  lease_ref="refs/heads/$ref"
  lease="--force-with-lease=${lease_ref}:${expected_remote}"
  if ! git push "$lease" "$verified_push_url" "HEAD:${lease_ref}" >/dev/null 2>&1; then
    error "push-failed"
  fi
  local new_sha remote_sha
  new_sha="$(git rev-parse --verify HEAD^{commit})" || error "post-push-head-read-failed"
  is_sha "$new_sha" || error "post-push-head-invalid"
  remote_sha="$(remote_ref_sha "$verified_push_url" "refs/heads/$ref")"
  [ "$remote_sha" = "$new_sha" ] || error "post-push-head-mismatch"
  printf '%s\n' "$new_sha"
}

managed_body_file="${temporary_dir}/managed-pr-body.md"
make_managed_body() {
  {
    printf '%s\n' '<!-- rpm-agent-cloud-publisher:start -->'
    printf 'Cloud run: %s\n' "$safe_run_id"
    printf 'Issue: #%s\n\n' "$result_issue"
    printf '%s\n' '## Summary'
    printf '%s\n\n' "$result_summary"
    printf '%s\n' '## Validation'
    if ! jq -r '.validation[]' "$result_file" | while IFS= read -r validation_item; do
      printf '%s\n' "- ${validation_item}"
    done; then
      error "validation-read-failed"
    fi
    printf '\nCloses #%s\n' "$result_issue"
    printf '%s\n' '<!-- rpm-agent-cloud-publisher:end -->'
  } >"$managed_body_file"
}

merge_managed_body() {
  local existing="$1"
  local output="$2"
  local start_count end_count
  if [ ! -s "$existing" ]; then
    cp -- "$managed_body_file" "$output"
    return 0
  fi
  start_count="$(grep -Fxc '<!-- rpm-agent-cloud-publisher:start -->' "$existing" || true)"
  end_count="$(grep -Fxc '<!-- rpm-agent-cloud-publisher:end -->' "$existing" || true)"
  if [ "$start_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    {
      cat -- "$managed_body_file"
      printf '\n\n'
      cat -- "$existing"
    } >"$output"
    return 0
  fi
  [ "$start_count" -eq 1 ] && [ "$end_count" -eq 1 ] || error "managed-body-marker-invalid"
  awk -v managed="$managed_body_file" '
    BEGIN {
      while ((getline line < managed) > 0) managed_lines[++managed_count] = line
      close(managed)
    }
    $0 == "<!-- rpm-agent-cloud-publisher:start -->" {
      for (i = 1; i <= managed_count; i++) print managed_lines[i]
      inside = 1
      seen_start++
      next
    }
    $0 == "<!-- rpm-agent-cloud-publisher:end -->" {
      if (!inside) exit 3
      inside = 0
      seen_end++
      next
    }
    !inside { print }
    END {
      if (inside || seen_start != 1 || seen_end != 1) exit 4
    }
  ' "$existing" >"$output" || error "managed-body-merge-failed"
}

pr_body_has_closing_issue() {
  local body_file="$1"
  grep -Eiq "(^|[^[:alnum:]])(closes|fixes|resolves)[[:space:]]+#${result_issue}([^0-9]|$)" "$body_file"
}

publish_issue_pr() {
  local pushed_sha="$1"
  local existing_count pr_number pr_url existing_body_file merged_body_file
  if ! pr_list_json="$(gh pr list --repo "$repository" --state open --head "$branch_ref" --base "$protected_base" --limit 100 --json number,url,title,body,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,headRepository,headRepositoryOwner,labels)"; then
    error "post-push-pr-list-failed"
  fi
  jq -e 'type == "array" and length <= 100' <<<"$pr_list_json" >/dev/null 2>&1 || error "invalid-post-push-pr-list"
  matching_pr_json="$(jq -c --arg branch "$branch_ref" --arg base "$protected_base" --arg repo "$repository" '[.[] | select(.baseRefName == $base and .headRefName == $branch and ((.headRepository.nameWithOwner // .headRepository.fullName // .headRepository // "") == $repo))]' <<<"$pr_list_json")"
  existing_count="$(jq 'length' <<<"$matching_pr_json")"
  [ "$existing_count" -le 1 ] || error "multiple-post-push-prs"
  make_managed_body
  if [ "$existing_count" -eq 1 ]; then
    pr_number="$(jq -r '.[0].number | tostring' <<<"$matching_pr_json")"
    pr_url="$(jq -r '.[0].url' <<<"$matching_pr_json")"
    existing_body_file="${temporary_dir}/existing-pr-body.md"
    merged_body_file="${temporary_dir}/merged-pr-body.md"
    current_pr_json="$(read_pr "$pr_number")" || error "existing-pr-refetch-failed"
    validate_pr_json "$current_pr_json" "$pushed_sha"
    [ "$(jq -r '.headRefOid' <<<"$current_pr_json" | tr '[:upper:]' '[:lower:]')" = "$pushed_sha" ] || error "existing-pr-head-race"
    verify_pr_closing_issue_binding "$pr_number"
    jq -r '.body' <<<"$current_pr_json" >"$existing_body_file"
    pr_body_has_closing_issue "$existing_body_file" || error "existing-pr-closing-issue-mismatch"
    merge_managed_body "$existing_body_file" "$merged_body_file"
    if ! cmp -s "$merged_body_file" <(jq -r '.body' <<<"$current_pr_json"); then
      gh pr edit "$pr_number" --repo "$repository" --body-file "$merged_body_file" >/dev/null 2>&1 || error "pr-body-update-failed"
      current_pr_json="$(read_pr "$pr_number")" || error "pr-body-refetch-failed"
      validate_pr_json "$current_pr_json" "$pushed_sha"
      jq -r '.body' <<<"$current_pr_json" | grep -Fq '<!-- rpm-agent-cloud-publisher:start -->' || error "pr-body-marker-missing"
    fi
  else
    create_output=""
    if create_output="$(gh pr create --repo "$repository" --head "$branch_ref" --base "$protected_base" --title "feat(agent): issue #${result_issue} cloud implementation" --body-file "$managed_body_file" --draft 2>/dev/null)"; then
      pr_url="$(printf '%s\n' "$create_output" | grep -Eo 'https://github.com/nerdchanii/rpm/pull/[1-9][0-9]*' | tail -n 1 || true)"
    else
      pr_url=""
    fi
    if [[ "$pr_url" =~ ^https://github.com/nerdchanii/rpm/pull/[1-9][0-9]*$ ]]; then
      pr_number="${pr_url##*/}"
    else
      # GitHub issue creation has no compare-and-set response.  A timeout or
      # duplicate response may still have created exactly one matching PR, so
      # reconcile by identity before declaring the publication blocked.
      if ! pr_list_json="$(gh pr list --repo "$repository" --state open --head "$branch_ref" --base "$protected_base" --limit 100 --json number,url,title,body,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,headRepository,headRepositoryOwner,labels)"; then
        error "pr-create-failed"
      fi
      jq -e 'type == "array" and length <= 100' <<<"$pr_list_json" >/dev/null 2>&1 || error "invalid-pr-create-reconcile-list"
      matching_pr_json="$(jq -c --arg branch "$branch_ref" --arg base "$protected_base" --arg repo "$repository" '[.[] | select(.baseRefName == $base and .headRefName == $branch and ((.headRepository.nameWithOwner // .headRepository.fullName // .headRepository // "") == $repo))]' <<<"$pr_list_json")"
      [ "$(jq 'length' <<<"$matching_pr_json")" -eq 1 ] || error "pr-create-failed"
      pr_number="$(jq -r '.[0].number | tostring' <<<"$matching_pr_json")"
      pr_url="$(jq -r '.[0].url' <<<"$matching_pr_json")"
    fi
    current_pr_json="$(read_pr "$pr_number")" || error "created-pr-refetch-failed"
    validate_pr_json "$current_pr_json" "$pushed_sha"
    verify_pr_closing_issue_binding "$pr_number"
    jq -r '.body' <<<"$current_pr_json" | grep -Fq '<!-- rpm-agent-cloud-publisher:start -->' || error "created-pr-body-marker-missing"
    jq -r '.body' <<<"$current_pr_json" | grep -Eiq "(^|[^[:alnum:]])(closes|fixes|resolves)[[:space:]]+#${result_issue}([^0-9]|$)" || error "created-pr-closing-issue-mismatch"
  fi

  # Re-fetch after the body/create phase and require the pushed SHA again.
  current_pr_json="$(read_pr "$pr_number")" || error "pr-final-refetch-failed"
  validate_pr_json "$current_pr_json" "$pushed_sha"
  [ "$(jq -r '.headRefOid' <<<"$current_pr_json" | tr '[:upper:]' '[:lower:]')" = "$pushed_sha" ] || error "pr-head-changed"
  verify_pr_closing_issue_binding "$pr_number"

  labels="$(pr_labels "$current_pr_json")"
  correction_labels="$(printf '%s\n' "$labels" | grep -E '^agent:correction-[0-5]$' || true)"
  correction_count="$(printf '%s\n' "$correction_labels" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$correction_count" -le 1 ] || error "pr-correction-label-conflict"
  if [ "$correction_count" -eq 0 ]; then
    verify_pr_closing_issue_binding "$pr_number"
    gh pr edit "$pr_number" --repo "$repository" --add-label "$(counter_label 0)" >/dev/null 2>&1 || error "pr-correction-label-add-failed"
    current_pr_json="$(read_pr "$pr_number")" || error "pr-correction-label-refetch-failed"
    validate_pr_json "$current_pr_json" "$pushed_sha"
  else
    [ "$(printf '%s\n' "$correction_labels" | sed -n '1p')" = "$(counter_label 0)" ] || error "pr-correction-label-conflict"
  fi
  validate_pr_correction_inventory "$current_pr_json"
  labels="$(pr_labels "$current_pr_json")"
  [ "$(label_count "$labels" "$(counter_label 0)")" -eq 1 ] || error "pr-correction-label-not-verified"

  if [ "$(jq -r '.isDraft' <<<"$current_pr_json")" = "true" ]; then
    gh pr ready "$pr_number" --repo "$repository" >/dev/null 2>&1 || error "pr-ready-failed"
    current_pr_json="$(read_pr "$pr_number")" || error "pr-ready-refetch-failed"
    validate_pr_json "$current_pr_json" "$pushed_sha"
  fi
  [ "$(jq -r '.isDraft' <<<"$current_pr_json")" = "false" ] || error "pr-remains-draft"

  # Read immediately before the lifecycle write and preserve every ordinary
  # issue label.  The exact state transition is the only issue mutation.
  issue_before="$(read_issue "$result_issue")" || error "issue-pre-transition-read-failed"
  validate_issue_json "$issue_before"
  validate_exact_issue_state "$issue_before" "$claimed_label"
  ordinary_before="$(ordinary_issue_labels "$issue_before")"
  verify_pr_closing_issue_binding "$pr_number"
  gh issue edit "$result_issue" --repo "$repository" --remove-label "$claimed_label" --add-label "$review_pending_label" >/dev/null 2>&1 || error "issue-review-pending-transition-failed"
  issue_after="$(read_issue "$result_issue")" || error "issue-review-pending-refetch-failed"
  validate_issue_json "$issue_after"
  validate_exact_issue_state "$issue_after" "$review_pending_label"
  ordinary_after="$(ordinary_issue_labels "$issue_after")"
  [ "$ordinary_before" = "$ordinary_after" ] || error "issue-ordinary-labels-changed"

  printf '%s\n%s\n' "$pr_url" "$pushed_sha"
}

comment_body_file="${temporary_dir}/blocked-comment.md"
write_block_comment() {
  local marker="<!-- rpm-agent-cloud-block: issue=${result_issue};run=${safe_run_id} -->"
  {
    printf '%s\n\n' "$marker"
    printf 'Codex Cloud publisher stopped this run safely.\n\nReason: %s\n\n' "$result_status"
    printf '%s\n' "$result_summary"
  } >"$comment_body_file"
}

publish_blocked_state() {
  local issue_before issue_after comments marker
  local from_label
  if [ "$mode" = "issue" ]; then
    from_label="$claimed_label"
  else
    from_label="$review_pending_label"
  fi
  issue_before="$(read_issue "$result_issue")" || error "blocked-issue-read-failed"
  validate_issue_json "$issue_before"
  labels="$(issue_labels "$issue_before")"
  if [ "$(label_count "$labels" "$blocked_label")" -eq 0 ]; then
    validate_exact_issue_state "$issue_before" "$from_label"
    ordinary_before="$(ordinary_issue_labels "$issue_before")"
    gh issue edit "$result_issue" --repo "$repository" --remove-label "$from_label" --add-label "$blocked_label" >/dev/null 2>&1 || error "blocked-state-transition-failed"
    issue_after="$(read_issue "$result_issue")" || error "blocked-state-refetch-failed"
    validate_issue_json "$issue_after"
    validate_exact_issue_state "$issue_after" "$blocked_label"
    ordinary_after="$(ordinary_issue_labels "$issue_after")"
    [ "$ordinary_before" = "$ordinary_after" ] || error "blocked-ordinary-labels-changed"
  else
    validate_exact_issue_state "$issue_before" "$blocked_label"
  fi

  write_block_comment
  marker="<!-- rpm-agent-cloud-block: issue=${result_issue};run=${safe_run_id} -->"
  if ! comments_json="$(gh issue view "$result_issue" --repo "$repository" --json comments)"; then
    error "blocked-comment-inventory-failed"
  fi
  jq -e 'type == "object" and (.comments | type == "array" and all(.[]; ((.body // .) | type == "string")))' <<<"$comments_json" >/dev/null 2>&1 || error "invalid-comment-inventory"
  if ! jq -e --arg marker "$marker" 'any(.comments[]; ((.body // .) | contains($marker)))' <<<"$comments_json" >/dev/null 2>&1; then
    gh issue comment "$result_issue" --repo "$repository" --body-file "$comment_body_file" >/dev/null 2>&1 || error "blocked-comment-write-failed"
    gh issue view "$result_issue" --repo "$repository" --json comments >/dev/null 2>&1 || error "blocked-comment-refetch-failed"
  fi
}

process_followups() {
  local followups_file followup_json index title body source fingerprint
  local helper_result helper_status body_file label_args label
  followups_file="${temporary_dir}/followups.jsonl"
  jq -c '.followups[]' "$result_file" >"$followups_file"
  index=0
  while IFS= read -r followup_json || [ -n "$followup_json" ]; do
    index=$((index + 1))
    title="$(jq -r '.title' <<<"$followup_json")"
    body="$(jq -r '.body' <<<"$followup_json")"
    source="$(jq -r '.source' <<<"$followup_json")"
    fingerprint="$(jq -r '.fingerprint' <<<"$followup_json")"
    body_file="/tmp/rpm-review-followup-publish-${safe_run_id}-${index}.md"
    # The helper accepts this exact /tmp name pattern and performs its own
    # regular-file, marker, fingerprint, and five-per-source checks.
    if [ -L "$body_file" ] || [ -e "$body_file" ]; then
      error "followup-body-path-exists"
    fi
    if ! (set -C; umask 077; printf '%s\n' "$body" >"$body_file") 2>/dev/null; then
      error "followup-body-create-failed"
    fi
    label_args=()
    while IFS= read -r label; do
      [ -n "$label" ] && label_args+=(--label "$label")
    done < <(jq -r '.labels[]' <<<"$followup_json")
    if ! helper_result="$(bash "${script_dir}/create-review-followup-issue.sh" \
      --title "$title" --body-file "$body_file" --source "$source" \
      --fingerprint "$fingerprint" "${label_args[@]}" --create --format jsonl 2>/dev/null)"; then
      rm -f -- "$body_file"
      error "followup-create-failed"
    fi
    rm -f -- "$body_file"
    helper_status="$(printf '%s\n' "$helper_result" | jq -r 'select(.type == "review_followup_result") | .data.status' | tail -n 1)"
    case "$helper_status" in
      created|duplicate) ;;
      *) error "followup-result-invalid" ;;
    esac
  done <"$followups_file"
}

review_thread_query='query($threadId:ID!,$commentsAfter:String){node(id:$threadId){__typename ... on PullRequestReviewThread{id,isResolved,isOutdated,path,line,startLine,originalLine,originalStartLine,diffSide,startDiffSide,pullRequest{number,repository{nameWithOwner}},comments(first:100,after:$commentsAfter){pageInfo{hasNextPage,endCursor}nodes{id,author{login},createdAt,body,path,line,startLine,originalLine,originalStartLine,diffHunk,outdated,side,startSide,commit{oid},originalCommit{oid}}}}}}'

review_threads_query='query($number:Int!,$threadsAfter:String){repository(owner:"nerdchanii",name:"rpm"){pullRequest(number:$number){number,repository{nameWithOwner},reviewThreads(first:100,after:$threadsAfter){pageInfo{hasNextPage,endCursor}nodes{id,isResolved,isOutdated}}}}}'

trusted_review_actor() {
  [ "$1" = "$trusted_review_actor_bot" ] || [ "$1" = "$trusted_review_actor_login" ]
}

fetch_review_thread_snapshot() {
  local thread_id="$1" response after="" page=0 has_next cursor pages_file snapshot
  local -a gh_args
  is_safe_thread_id "$thread_id" || error "unsafe-thread-id"
  pages_file="$(mktemp "${temporary_dir}/review-thread-pages.XXXXXX")" || error "review-thread-temp-failed"
  while :; do
    page=$((page + 1))
    [ "$page" -le "$max_graphql_pages" ] || error "review-thread-pagination-limit"
    gh_args=(api graphql --repo "$repository" -f query="$review_thread_query" -f threadId="$thread_id")
    if [ -n "$after" ]; then
      gh_args+=(-f commentsAfter="$after")
    fi
    response="$(gh "${gh_args[@]}" 2>/dev/null)" || error "review-thread-read-failed"
    printf '%s\n' "$response" >>"$pages_file"
    jq -s -e --arg id "$thread_id" '
      (length == 1) and
      (.[0] |
        type == "object" and
        .data.node.__typename == "PullRequestReviewThread" and
        .data.node.id == $id and
        (.data.node.comments.nodes | type == "array") and
        (.data.node.comments.pageInfo.hasNextPage | type == "boolean") and
        ((.data.node.comments.pageInfo.endCursor // null) == null or
         (.data.node.comments.pageInfo.endCursor | type == "string")))
    ' <<<"$response" >/dev/null 2>&1 || error "review-thread-response-invalid"
    has_next="$(jq -s -r '.[0].data.node.comments.pageInfo.hasNextPage' <<<"$response")"
    [ "$has_next" = "true" ] || break
    cursor="$(jq -s -r '.[0].data.node.comments.pageInfo.endCursor // ""' <<<"$response")"
    [ -n "$cursor" ] || error "review-thread-pagination-cursor-missing"
    [ "$cursor" != "$after" ] || error "review-thread-pagination-cursor-repeated"
    after="$cursor"
  done

  jq -s -e '
    [.[].data.node.comments.nodes[]?.id] as $ids |
    ($ids | length) == ($ids | unique | length)
  ' "$pages_file" >/dev/null 2>&1 || error "review-thread-duplicate-comment"
  snapshot="$(jq -s -c '
    .[0].data.node as $node |
    $node + {comments: {
      nodes: [.[].data.node.comments.nodes[]?],
      pageInfo: .[-1].data.node.comments.pageInfo
    }}
  ' "$pages_file")" || error "review-thread-assemble-failed"
  rm -f -- "$pages_file"
  printf '%s\n' "$snapshot"
}

verify_review_thread_claim() {
  local thread_id="$1" thread_json="$2"
  is_safe_thread_id "$thread_id" || error "unsafe-thread-id"
  jq -e \
    --arg id "$thread_id" \
    --arg repo "$repository" \
    --arg expected "$expected_head_sha" \
    --arg trusted_bot "$trusted_review_actor_bot" \
    --arg trusted_login "$trusted_review_actor_login" \
    --argjson pr "$expected_pr" \
    --slurpfile patch_context "$patch_review_context_file" '
    . as $thread |
    ($thread.comments.nodes) as $comments |
    ($thread.originalStartLine // $thread.originalLine) as $original_start |
    ($thread.originalLine) as $original_end |
    ($thread.path) as $path |
    ($comments | length > 0) and
    $thread.__typename == "PullRequestReviewThread" and
    $thread.id == $id and
    $thread.isResolved == false and
    $thread.isOutdated == false and
    $thread.pullRequest.number == $pr and
    $thread.pullRequest.repository.nameWithOwner == $repo and
    ($path | type == "string" and length > 0) and
    ($thread.line | type == "number" and floor == . and . > 0) and
    (($thread.startLine == null) or ($thread.startLine | type == "number" and floor == . and . > 0 and . <= $thread.line)) and
    ($thread.diffSide == "RIGHT") and
    (($thread.startDiffSide == null) or ($thread.startDiffSide == "RIGHT")) and
    ($original_start | type == "number" and floor == . and . > 0) and
    ($original_end | type == "number" and floor == . and . >= $original_start) and
    (($patch_context[0].paths | index($path)) != null) and
    any($patch_context[0].hunks[];
      .path == $path and $original_start <= .end and $original_end >= .start
    ) and
    all($comments[];
      (.id | type == "string" and length > 0) and
      (.author.login | type == "string" and ( . == $trusted_bot or . == $trusted_login)) and
      .outdated == false and
      .path == $path and
      (.line | type == "number" and floor == . and . > 0) and
      ((.startLine == null) or ((.startLine | type == "number" and floor == . and . > 0) and (.startLine <= .line))) and
      .side == "RIGHT" and
      ((.startSide == null) or (.startSide == "RIGHT")) and
      (.commit.oid | type == "string" and ascii_downcase == $expected) and
      (.originalCommit.oid | type == "string" and ascii_downcase == $expected)
    )
  ' <<<"$thread_json" >/dev/null 2>&1 || error "review-thread-not-bound-or-already-resolved"
}

validate_all_review_thread_claims() {
  local expected_input_head="$1" thread_id thread_json
  [ "$mode" = "review" ] || error "review-thread-claim-review-only"
  [ "$expected_input_head" = "$expected_head_sha" ] || error "review-thread-input-head-mismatch"
  review_claim_snapshots_file="${temporary_dir}/review-claim-snapshots.jsonl"
  : >"$review_claim_snapshots_file"
  while IFS= read -r thread_id || [ -n "$thread_id" ]; do
    [ -n "$thread_id" ] || continue
    thread_json="$(fetch_review_thread_snapshot "$thread_id")" || error "review-thread-read-failed"
    verify_review_thread_claim "$thread_id" "$thread_json"
    printf '%s\n' "$thread_json" >>"$review_claim_snapshots_file"
  done < <(jq -r '.resolved_thread_ids[]' "$result_file")
}

verify_live_no_unresolved_review_threads() {
  local response after="" page=0 has_next cursor pages_file unresolved_count
  local -a gh_args
  pages_file="$(mktemp "${temporary_dir}/review-thread-inventory.XXXXXX")" || error "review-thread-temp-failed"
  while :; do
    page=$((page + 1))
    [ "$page" -le "$max_graphql_pages" ] || error "review-thread-pagination-limit"
    gh_args=(api graphql --repo "$repository" -f query="$review_threads_query" -F number="$expected_pr")
    if [ -n "$after" ]; then
      gh_args+=(-f threadsAfter="$after")
    fi
    response="$(gh "${gh_args[@]}" 2>/dev/null)" || error "review-thread-inventory-read-failed"
    printf '%s\n' "$response" >>"$pages_file"
    jq -s -e --argjson pr "$expected_pr" '
      (length == 1) and
      (.[0] |
        type == "object" and
        .data.repository.pullRequest.number == $pr and
        .data.repository.pullRequest.repository.nameWithOwner == "nerdchanii/rpm" and
        (.data.repository.pullRequest.reviewThreads.nodes | type == "array") and
        (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type == "boolean") and
        all(.data.repository.pullRequest.reviewThreads.nodes[];
          (.id | type == "string" and length > 0) and
          (.isResolved | type == "boolean") and
          (.isOutdated | type == "boolean")
        ))
    ' <<<"$response" >/dev/null 2>&1 || error "review-thread-inventory-invalid"
    has_next="$(jq -s -r '.[0].data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$response")"
    [ "$has_next" = "true" ] || break
    cursor="$(jq -s -r '.[0].data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<<"$response")"
    [ -n "$cursor" ] || error "review-thread-pagination-cursor-missing"
    [ "$cursor" != "$after" ] || error "review-thread-pagination-cursor-repeated"
    after="$cursor"
  done
  unresolved_count="$(jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved != true)] | length' "$pages_file")" || error "review-thread-inventory-assemble-failed"
  rm -f -- "$pages_file"
  [ "$unresolved_count" -eq 0 ] || error "no-work-unresolved-review-threads"
}

verify_review_head_unchanged() {
  local expected_sha="$1" reason_prefix="${2:-review-thread}" current_pr current_head current_remote
  current_pr="$(read_pr "$expected_pr")" || error "${reason_prefix}-pr-read-failed"
  current_head="$(jq -r '.headRefOid // ""' <<<"$current_pr" | tr '[:upper:]' '[:lower:]')"
  [ "$current_head" = "$expected_sha" ] || error "${reason_prefix}-pr-head-race"
  validate_pr_json "$current_pr" "$expected_sha"
  current_remote="$(remote_ref_sha "$verified_push_url" "refs/heads/$branch_ref")"
  [ "$current_remote" = "$expected_sha" ] || error "${reason_prefix}-remote-head-race"
}

verify_resolved_thread() {
  local thread_id="$1" thread_json
  thread_json="$(fetch_review_thread_snapshot "$thread_id")" || error "review-thread-refetch-failed"
  jq -e --arg id "$thread_id" --arg repo "$repository" --argjson pr "$expected_pr" '
    .__typename == "PullRequestReviewThread" and
    .id == $id and .isResolved == true and
    .pullRequest.number == $pr and
    .pullRequest.repository.nameWithOwner == $repo
  ' <<<"$thread_json" >/dev/null 2>&1 || error "review-thread-final-state-invalid"
}

if [ "$result_status" = "no-work" ]; then
  if [ "$mode" = "issue" ]; then
    # A dispatcher-selected issue is expected to be claimed by the Cloud
    # manager.  Leaving it claimed after a no-work handoff would strand it;
    # recover that incoherent state through the same idempotent blocked path.
    issue_json="$(read_issue "$result_issue")" || error "no-work-issue-read-failed"
    validate_issue_json "$issue_json"
    labels="$(issue_labels "$issue_json")"
    if [ "$(label_count "$labels" "$claimed_label")" -eq 1 ]; then
      publish_blocked_state
      emit_result blocked "no-work-left-claimed"
      exit 0
    fi
    emit_result no-work "no-work"
    exit 0
  fi
  if [ "$result_next_state" = "unchanged" ]; then
    emit_result no-work "no-work"
    exit 0
  fi
  # Review no-work/awaiting-merge still needs the guarded lifecycle write.  It
  # is handled below without applying a code patch.
fi

if [ "$result_status" = "blocked" ]; then
  publish_blocked_state
  process_followups
  emit_result blocked "blocked-state-recorded"
  exit 0
fi

if [ "$mode" = "review" ] && [ "$result_status" = "no-work" ]; then
  # A clean review with no code change may still advance the issue after the
  # exact PR/head and review evidence are checked.  The empty patch remains
  # untouched throughout this path.
  pr_json="$(read_pr "$expected_pr")" || error "no-work-pr-read-failed"
  validate_pr_json "$pr_json" "$expected_head_sha"
  issue_json="$(read_issue "$result_issue")" || error "no-work-review-issue-read-failed"
  validate_issue_json "$issue_json"
  validate_exact_issue_state "$issue_json" "$review_pending_label"
  [ "$(remote_ref_sha "$verified_push_url" "refs/heads/$branch_ref")" = "$expected_head_sha" ] || error "no-work-review-head-mismatch"
  validate_pr_correction_inventory "$pr_json"
  verify_pr_closing_issue_binding "$expected_pr"
  if [ "$(jq '.followups | length' "$result_file")" -gt 0 ]; then
    process_followups
  fi
  if [ "$result_next_state" = "awaiting-merge" ]; then
    transition_issue "$review_pending_label" "$awaiting_merge_label"
  fi
  emit_result no-work "review-no-code-change"
  exit 0
fi

if [ "$mode" = "issue" ]; then
  apply_and_commit "feat(agent): implement issue #${result_issue} via Codex Cloud"
  pushed_sha="$(push_captured_ref "$branch_ref" "$expected_remote_sha")"
  publish_output="$(publish_issue_pr "$pushed_sha")"
  pr_url="$(printf '%s\n' "$publish_output" | sed -n '1p')"
  final_sha="$(printf '%s\n' "$publish_output" | sed -n '2p')"
  process_followups
  emit_result published "issue-published" "$pr_url" "$final_sha"
  exit 0
fi

# Review mode: re-read the PR and remote ref immediately before the push.  The
# push uses the exact old SHA as a force-with-lease CAS and separately enforces
# that the new commit remains a fast-forward of that old SHA.
assert_clean_head
pre_push_pr="$(read_pr "$expected_pr")" || error "pre-push-pr-read-failed"
validate_pr_json "$pre_push_pr" "$expected_head_sha"
pre_push_remote_sha="$(remote_ref_sha "$verified_push_url" "refs/heads/$branch_ref")"
[ "$pre_push_remote_sha" = "$expected_head_sha" ] || error "pre-push-remote-head-race"
verify_pr_closing_issue_binding "$expected_pr"
# Validate every claimed thread while the exact PR/head snapshot is still
# unchanged.  This completes the whole claim set before any code mutation, so
# one invalid claim prevents all later resolution calls.
validate_all_review_thread_claims "$expected_head_sha"
verify_pr_closing_issue_binding "$expected_pr"
apply_and_commit "fix(agent): resolve review for PR #${expected_pr} via Codex Cloud"
verify_pr_closing_issue_binding "$expected_pr"
pushed_sha="$(push_captured_ref "$branch_ref" "$expected_head_sha")"
post_push_pr="$(read_pr "$expected_pr")" || error "post-push-pr-read-failed"
validate_pr_json "$post_push_pr" "$pushed_sha"
[ "$(jq -r '.headRefOid' <<<"$post_push_pr" | tr '[:upper:]' '[:lower:]')" = "$pushed_sha" ] || error "post-push-pr-head-race"
verify_pr_closing_issue_binding "$expected_pr"
# Revalidate the complete claim set against live GitHub data after the exact
# push.  No thread mutation is allowed until this second full snapshot passes.
validate_all_review_thread_claims "$expected_head_sha"
verify_review_head_unchanged "$pushed_sha" "review-thread-post-push"

labels="$(pr_labels "$post_push_pr")"
correction_labels="$(printf '%s\n' "$labels" | grep -E '^agent:correction-[0-5]$' || true)"
correction_count="$(printf '%s\n' "$correction_labels" | awk 'NF { count++ } END { print count + 0 }')"
[ "$correction_count" -eq 1 ] || error "post-push-correction-label-count"
current_correction_label="$(printf '%s\n' "$correction_labels" | sed -n '1p')"
ordinary_pr_before="$(ordinary_pr_labels "$post_push_pr")"
if [ "$current_correction_label" != "$result_correction_label" ]; then
  # Labels have no compare-and-set API.  Re-read the exact pre-value directly
  # before the mutation and refuse to replace it when another writer changed
  # the PR in the meantime.  This prevents a stale run from lowering or
  # overwriting a newer correction counter.
  label_guard_pr="$(read_pr "$expected_pr")" || error "correction-label-guard-read-failed"
  validate_pr_json "$label_guard_pr" "$pushed_sha"
  label_guard_correction="$(pr_correction_label "$label_guard_pr")"
  [ "$label_guard_correction" = "$current_correction_label" ] || error "correction-label-race"
  label_guard_ordinary="$(ordinary_pr_labels "$label_guard_pr")"
  [ "$label_guard_ordinary" = "$ordinary_pr_before" ] || error "correction-label-ordinary-race"
  verify_pr_closing_issue_binding "$expected_pr"
  gh pr edit "$expected_pr" --repo "$repository" --remove-label "$current_correction_label" --add-label "$result_correction_label" >/dev/null 2>&1 || error "correction-label-replace-failed"
  post_push_pr="$(read_pr "$expected_pr")" || error "correction-label-refetch-failed"
  validate_pr_json "$post_push_pr" "$pushed_sha"
fi
validate_pr_correction_inventory "$post_push_pr"
labels="$(pr_labels "$post_push_pr")"
[ "$(label_count "$labels" "$result_correction_label")" -eq 1 ] || error "correction-label-not-verified"
ordinary_pr_after="$(ordinary_pr_labels "$post_push_pr")"
[ "$ordinary_pr_before" = "$ordinary_pr_after" ] || error "pr-ordinary-labels-changed"

resolved_ids_file="${temporary_dir}/resolved-thread-ids"
jq -r '.resolved_thread_ids[]' "$result_file" >"$resolved_ids_file"
# A label/body update may have taken time.  Revalidate every claim once more
# before beginning the resolution sequence.
validate_all_review_thread_claims "$expected_head_sha"
verify_review_head_unchanged "$pushed_sha" "review-thread-pre-resolve"
while IFS= read -r thread_id || [ -n "$thread_id" ]; do
  [ -n "$thread_id" ] || continue
  # Each individual mutation has a live claim check and a head check on both
  # sides.  A concurrent head update therefore stops the remaining sequence.
  verify_review_head_unchanged "$pushed_sha" "review-thread-before-resolve"
  thread_json="$(fetch_review_thread_snapshot "$thread_id")" || error "review-thread-read-failed"
  verify_review_thread_claim "$thread_id" "$thread_json"
  verify_review_head_unchanged "$pushed_sha" "review-thread-before-resolve-mutation"
  graphql_query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}'
  if ! thread_result="$(gh api graphql --repo "$repository" -f query="$graphql_query" -f threadId="$thread_id" 2>/dev/null)"; then
    error "review-thread-resolve-failed"
  fi
  jq -e '.data.resolveReviewThread.thread.isResolved == true' <<<"$thread_result" >/dev/null 2>&1 || error "review-thread-not-resolved"
  verify_review_head_unchanged "$pushed_sha" "review-thread-after-resolve"
  verify_resolved_thread "$thread_id"
done <"$resolved_ids_file"

if [ "$(jq '.followups | length' "$result_file")" -gt 0 ]; then
  process_followups
fi

if [ "$result_next_state" = "awaiting-merge" ]; then
  issue_before="$(read_issue "$result_issue")" || error "review-issue-pre-transition-read-failed"
  validate_issue_json "$issue_before"
  validate_exact_issue_state "$issue_before" "$review_pending_label"
  ordinary_before="$(ordinary_issue_labels "$issue_before")"
  verify_awaiting_merge_pr_head "$pushed_sha"
  gh issue edit "$result_issue" --repo "$repository" --remove-label "$review_pending_label" --add-label "$awaiting_merge_label" >/dev/null 2>&1 || error "awaiting-merge-transition-failed"
  issue_after="$(read_issue "$result_issue")" || error "awaiting-merge-refetch-failed"
  validate_issue_json "$issue_after"
  validate_exact_issue_state "$issue_after" "$awaiting_merge_label"
  ordinary_after="$(ordinary_issue_labels "$issue_after")"
  [ "$ordinary_before" = "$ordinary_after" ] || error "awaiting-merge-ordinary-labels-changed"
else
  issue_after="$(read_issue "$result_issue")" || error "review-pending-final-read-failed"
  validate_issue_json "$issue_after"
  validate_exact_issue_state "$issue_after" "$review_pending_label"
fi

emit_result published "review-published" "" "$pushed_sha"
