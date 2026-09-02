#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
validator="${repo_root}/scripts/validate-cloud-diff.sh"
base_sha=''
head_sha=''
patch_base_sha=''
patch_head_sha=''
validator_checkout=''

fail() {
  printf 'validate_cloud_diff_test.FAIL=%s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'validate_cloud_diff_test.PASS=%s\n' "$1"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/validate-cloud-diff-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

git_init() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q || fail 'git-init'
  git -C "$path" config user.email test@example.invalid
  git -C "$path" config user.name 'Cloud Diff Test'
}

test_checkout="$tmp_dir/test-checkout"
git_init "$test_checkout"
printf 'before\n' >"$test_checkout/src.txt"
git -C "$test_checkout" add src.txt
git -C "$test_checkout" commit -qm base
base_sha="$(git -C "$test_checkout" rev-parse HEAD)"
validator_checkout="$test_checkout"

result_json() {
  local lane="$1"
  local status="$2"
  local issue="$3"
  local pr="$4"
  local sha="$5"
  local head="${6:-$sha}"
  local next_state=unchanged
  local correction=null
  local actionable=false

  case "$lane:$status" in
    issue:patch)
      next_state=review-pending
      correction='agent:correction-0'
      ;;
    review:no-work)
      next_state=awaiting-merge
      ;;
    review:patch)
      next_state=review-pending
      correction='agent:correction-1'
      actionable=true
      ;;
    merge:merge)
      next_state=awaiting-merge
      ;;
    merge:blocked)
      next_state=blocked
      ;;
    *:blocked)
      next_state=blocked
      ;;
  esac

  python3 - "$lane" "$status" "$issue" "$pr" "$sha" "$head" \
    "$next_state" "$correction" "$actionable" <<'PY'
import json
import sys

lane, status, issue, pr, sha, head, next_state, correction, actionable = sys.argv[1:]
value = {
    "version": 1,
    "lane": lane,
    "status": status,
    "issue": int(issue),
    "pr": int(pr) if lane in {"review", "merge"} else None,
    "base_sha": sha,
    "head_sha": head if lane in {"review", "merge"} else None,
    "summary": "cloud result",
    "validation": ["test"],
    "actionable_findings_remaining": actionable == "true",
    "next_state": next_state,
    "correction_label": correction if correction != "null" else None,
    "resolved_thread_ids": [],
    "followups": [],
}
print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
PY
}

make_git_patch() {
  local destination="$1"
  local lane="${2:-issue}"
  local status="${3:-patch}"
  local issue="${4:-42}"
  local pr="${5:-7}"
  local sha="${6:-$base_sha}"
  local head="${7:-$sha}"
  local repo="${tmp_dir}/repo-${RANDOM}-${RANDOM}"

  git_init "$repo"
  printf 'before\n' >"${repo}/src.txt"
  git -C "$repo" add src.txt
  git -C "$repo" commit -qm base
  local commit_sha
  commit_sha="$(git -C "$repo" rev-parse HEAD)"
  if [ "$lane" = issue ]; then
    sha="$commit_sha"
    patch_base_sha="$commit_sha"
    patch_head_sha=''
  else
    sha="$commit_sha"
    head="$commit_sha"
    patch_base_sha="$sha"
    patch_head_sha="$commit_sha"
  fi
  if [ "$lane" = review ]; then
    git -C "$repo" add src.txt
    git -C "$repo" commit --allow-empty -qm review-head
    commit_sha="$(git -C "$repo" rev-parse HEAD)"
    head="$commit_sha"
    patch_head_sha="$commit_sha"
  fi
  if [ "$status" = patch ]; then
    printf 'after\n' >"${repo}/src.txt"
  fi
  result_json "$lane" "$status" "$issue" "$pr" "$sha" "$head" >"${repo}/.codex-cloud-result.json"
  git -C "$repo" add -N .codex-cloud-result.json
  git -C "$repo" diff --binary --no-ext-diff >"$destination"
  git -C "$repo" reset --hard -q HEAD
  git -C "$repo" clean -fdq
  validator_checkout="$repo"
  head_sha="$commit_sha"
}

make_merge_patch() {
  local destination="$1"
  local status="${2:-merge}"
  local issue="${3:-42}"
  local pr="${4:-77}"
  local repo="${tmp_dir}/merge-repo-${RANDOM}-${RANDOM}"
  local merge_head

  git_init "$repo"
  printf 'before\n' >"${repo}/src.txt"
  git -C "$repo" add src.txt
  git -C "$repo" commit -qm base
  merge_head="$(printf 'b%.0s' {1..40})"
  patch_base_sha="$(git -C "$repo" rev-parse HEAD)"
  patch_head_sha="$merge_head"
  result_json merge "$status" "$issue" "$pr" "$patch_base_sha" "$merge_head" \
    >"${repo}/.codex-cloud-result.json"
  git -C "$repo" add -N .codex-cloud-result.json
  git -C "$repo" diff --binary --no-ext-diff >"$destination"
  git -C "$repo" reset --hard -q HEAD
  git -C "$repo" clean -fdq
  validator_checkout="$repo"
  head_sha="$merge_head"
}

replace_result_line() {
  local patch="$1"
  local result_json_file="$2"
  python3 - "$patch" "$result_json_file" <<'PY'
from pathlib import Path
import sys

patch_path, result_path = map(Path, sys.argv[1:])
payload = result_path.read_bytes().rstrip(b"\n")
lines = patch_path.read_bytes().splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith(b"+") and b'"version":' in line and b'"lane":' in line:
        lines[index] = b"+" + payload + b"\n"
        patch_path.write_bytes(b"".join(lines))
        break
else:
    raise SystemExit("result-line-not-found")
PY
}

run_validator() {
  local patch="$1"
  local lane="$2"
  local issue="$3"
  local pr="$4"
  local sha="$5"
  local result="$6"
  local code="$7"
  local head="${8:-$sha}"
  local output
  local args=(
    --patch "$patch"
    --lane "$lane"
    --expected-issue "$issue"
    --expected-base-sha "$sha"
    --result-out "$result"
    --code-patch-out "$code"
  )
  if [ "$lane" != issue ]; then
    args+=(--expected-pr "$pr")
    args+=(--expected-head-sha "$head")
  fi
  if ! output="$(cd "$validator_checkout" && "$validator" "${args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

expect_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local output
  local status
  set +e
  output="$(cd "$validator_checkout" && "$validator" "$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "accepted-${label}"
  printf '%s\n' "$output" | grep -Fq "$expected" || fail "wrong-reason-${label}:${output}"
  pass "$label"
}

valid_patch="${tmp_dir}/valid.patch"
make_git_patch "$valid_patch"
run_validator "$valid_patch" issue 42 '' "$patch_base_sha" \
  "${tmp_dir}/valid.result" "${tmp_dir}/valid.code" >/dev/null
[ "$(wc -l <"${tmp_dir}/valid.result" | tr -d ' ')" = 1 ] || fail 'issue-result-is-one-line'
[ "$(wc -c <"${tmp_dir}/valid.code" | tr -d ' ')" -gt 0 ] || fail 'issue-code-patch-is-nonempty'
grep -Fq 'diff --git a/src.txt b/src.txt' "${tmp_dir}/valid.code" || fail 'issue-code-path-preserved'
! grep -Fq 'diff --git a/.codex-cloud-result.json' "${tmp_dir}/valid.code" || fail 'result-diff-was-not-removed'
pass 'valid-issue-patch'

review_patch="${tmp_dir}/review.patch"
make_git_patch "$review_patch" review patch 42 77 "$base_sha"
run_validator "$review_patch" review 42 77 "$patch_base_sha" \
  "${tmp_dir}/review.result" "${tmp_dir}/review.code" "$patch_head_sha" >/dev/null
grep -Fq '"head_sha":"'"$patch_head_sha"'"' "${tmp_dir}/review.result" || fail 'review-head-sha-validated'
pass 'valid-review-patch'

mode_only_source="${tmp_dir}/mode-only-source.patch"
make_git_patch "$mode_only_source" issue patch
mode_only_base="$patch_base_sha"
mode_only_patch="${tmp_dir}/mode-only.patch"
python3 - "$mode_only_source" "$mode_only_patch" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_bytes()
result_marker = b"diff --git a/.codex-cloud-result.json b/.codex-cloud-result.json"
result = source[source.index(result_marker):]
mode_only = (
    b"diff --git a/empty.txt b/empty.txt\n"
    b"new file mode 100644\n"
    b"index 0000000..e69de29\n"
    b"--- /dev/null\n"
    b"+++ b/empty.txt\n"
)
Path(sys.argv[2]).write_bytes(mode_only + result)
PY
run_validator "$mode_only_patch" issue 42 '' "$mode_only_base" \
  "${tmp_dir}/mode-only.result" "${tmp_dir}/mode-only.code" >/dev/null
grep -Fq 'diff --git a/empty.txt b/empty.txt' "${tmp_dir}/mode-only.code" || fail 'mode-only-code-preserved'
[ -s "${tmp_dir}/mode-only.code" ] || fail 'mode-only-code-output-empty'
pass 'mode-only-regular-file'

duplicate_key_patch="${tmp_dir}/duplicate-key.patch"
make_git_patch "$duplicate_key_patch" issue patch
duplicate_key_base="$patch_base_sha"
python3 - "$duplicate_key_patch" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b'"status":"patch"'
if data.count(needle) != 1:
    raise SystemExit("status-field-not-found")
path.write_bytes(data.replace(needle, needle + b',"status":"patch"', 1))
PY
expect_failure 'duplicate-json-key' 'result-duplicate-json-key' \
  --patch "$duplicate_key_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$duplicate_key_base" --result-out "${tmp_dir}/duplicate-key.result" \
  --code-patch-out "${tmp_dir}/duplicate-key.code"
[ ! -e "${tmp_dir}/duplicate-key.result" ] || fail 'duplicate-key-result-output-created'
[ ! -e "${tmp_dir}/duplicate-key.code" ] || fail 'duplicate-key-code-output-created'

atomic_patch="${tmp_dir}/atomic.patch"
make_git_patch "$atomic_patch" issue patch
atomic_base="$patch_base_sha"
atomic_result="${tmp_dir}/atomic.result"
atomic_code="${tmp_dir}/atomic.code"
printf 'keep this file\n' >"$atomic_result"
expect_failure 'result-output-existing' 'result-output-target-exists' \
  --patch "$atomic_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$atomic_base" --result-out "$atomic_result" \
  --code-patch-out "$atomic_code"
grep -Fq 'keep this file' "$atomic_result" || fail 'existing-result-overwritten'
[ ! -e "$atomic_code" ] || fail 'atomic-code-output-created'

review_no_work_patch="${tmp_dir}/review-no-work.patch"
make_git_patch "$review_no_work_patch" review no-work 42 77 "$base_sha"
review_no_work_base="$patch_base_sha"
review_no_work_head="$patch_head_sha"
review_no_work_checkout="$validator_checkout"
review_no_work_result="${tmp_dir}/review-no-work.json"
run_validator "$review_no_work_patch" review 42 77 "$review_no_work_base" \
  "${tmp_dir}/review-no-work.result" "${tmp_dir}/review-no-work.code" "$review_no_work_head" >/dev/null
grep -Fq '"next_state":"awaiting-merge"' "${tmp_dir}/review-no-work.result" || fail 'review-no-work-awaiting-merge'
grep -Fq '"resolved_thread_ids":[]' "${tmp_dir}/review-no-work.result" || fail 'review-no-work-thread-array-not-empty'
grep -Fq '"followups":[]' "${tmp_dir}/review-no-work.result" || fail 'review-no-work-followup-array-not-empty'
[ ! -s "${tmp_dir}/review-no-work.code" ] || fail 'review-no-work-code-output-not-empty'
pass 'review-no-work-awaiting-merge'

make_review_followup_result() {
  local result_path="$1"
  python3 - "$result_path" "$review_no_work_base" "$review_no_work_head" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

result_path, base_sha, head_sha = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
title = "capture unrelated work"
body = "<!-- rpm-agent-followup-source: pr:77 -->\nTrack the unrelated discovery."
fingerprint = "sha256:" + hashlib.sha256(
    title.encode("utf-8") + b"\0" + body.encode("utf-8")
).hexdigest()
value = {
    "version": 1,
    "lane": "review",
    "status": "no-work",
    "issue": 42,
    "pr": 77,
    "base_sha": base_sha,
    "head_sha": head_sha,
    "summary": "review had no code changes",
    "validation": ["review checks passed"],
    "actionable_findings_remaining": False,
    "next_state": "awaiting-merge",
    "correction_label": None,
    "resolved_thread_ids": [],
    "followups": [{
        "title": title,
        "body": body,
        "source": "pr:77",
        "fingerprint": fingerprint,
        "labels": ["bug"],
    }],
}
result_path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

review_patch_wrong_state="${tmp_dir}/review-patch-wrong-state.patch"
make_git_patch "$review_patch_wrong_state" review patch 42 77 "$base_sha"
review_patch_wrong_state_base="$patch_base_sha"
review_patch_wrong_state_head="$patch_head_sha"
review_patch_wrong_state_result="${tmp_dir}/review-patch-wrong-state.json"
result_json review patch 42 77 "$review_patch_wrong_state_base" "$review_patch_wrong_state_head" \
  >"$review_patch_wrong_state_result"
python3 - "$review_patch_wrong_state_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["next_state"] = "awaiting-merge"
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$review_patch_wrong_state" "$review_patch_wrong_state_result"
expect_failure 'review-patch-awaiting-merge' 'result-review-patch-state-incoherent' \
  --patch "$review_patch_wrong_state" --lane review --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$review_patch_wrong_state_base" \
  --expected-head-sha "$review_patch_wrong_state_head" \
  --result-out "${tmp_dir}/review-patch-wrong-state.result" \
  --code-patch-out "${tmp_dir}/review-patch-wrong-state.code"

review_no_work_thread_patch="${tmp_dir}/review-no-work-thread.patch"
review_no_work_thread_result="${tmp_dir}/review-no-work-thread.json"
cp "$review_no_work_patch" "$review_no_work_thread_patch"
result_json review no-work 42 77 "$review_no_work_base" "$review_no_work_head" \
  >"$review_no_work_thread_result"
python3 - "$review_no_work_thread_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["resolved_thread_ids"] = ["PRRT_FORBIDDEN"]
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$review_no_work_thread_patch" "$review_no_work_thread_result"
validator_checkout="$review_no_work_checkout"
expect_failure 'review-no-work-thread-ids' 'result-review-no-work-state-incoherent' \
  --patch "$review_no_work_thread_patch" --lane review --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$review_no_work_base" --expected-head-sha "$review_no_work_head" \
  --result-out "${tmp_dir}/review-no-work-thread.result" \
  --code-patch-out "${tmp_dir}/review-no-work-thread.code"

review_no_work_followup_patch="${tmp_dir}/review-no-work-followup.patch"
review_no_work_followup_result="${tmp_dir}/review-no-work-followup.json"
cp "$review_no_work_patch" "$review_no_work_followup_patch"
make_review_followup_result "$review_no_work_followup_result"
replace_result_line "$review_no_work_followup_patch" "$review_no_work_followup_result"
run_validator "$review_no_work_followup_patch" review 42 77 "$review_no_work_base" \
  "${tmp_dir}/review-no-work-followup.result" "${tmp_dir}/review-no-work-followup.code" \
  "$review_no_work_head" >/dev/null
grep -Fq '"next_state":"awaiting-merge"' "${tmp_dir}/review-no-work-followup.result" || \
  fail 'review-no-work-followup-state'
grep -Fq '"followups":[{' "${tmp_dir}/review-no-work-followup.result" || \
  fail 'review-no-work-followup-not-preserved'
[ ! -s "${tmp_dir}/review-no-work-followup.code" ] || \
  fail 'review-no-work-followup-code-output-not-empty'
pass 'review-no-work-followups-allowed'

followup_marker_patch="${tmp_dir}/followup-marker.patch"
followup_marker_result="${tmp_dir}/followup-marker.json"
cp "$review_no_work_patch" "$followup_marker_patch"
validator_checkout="$review_no_work_checkout"
make_review_followup_result "$followup_marker_result"
python3 - "$followup_marker_result" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
followup = value["followups"][0]
followup["body"] += "\n<!-- rpm-agent-followup-fingerprint: forged -->"
followup["fingerprint"] = "sha256:" + hashlib.sha256(
    followup["title"].encode("utf-8") + b"\0" + followup["body"].encode("utf-8")
).hexdigest()
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$followup_marker_patch" "$followup_marker_result"
expect_failure 'followup-fingerprint-marker' 'result-followup-body-contains-fingerprint-marker' \
  --patch "$followup_marker_patch" --lane review --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$review_no_work_base" --expected-head-sha "$review_no_work_head" \
  --result-out "${tmp_dir}/followup-marker.out" --code-patch-out "${tmp_dir}/followup-marker.code"

followup_label_patch="${tmp_dir}/followup-label.patch"
followup_label_result="${tmp_dir}/followup-label.json"
cp "$review_no_work_patch" "$followup_label_patch"
make_review_followup_result "$followup_label_result"
python3 - "$followup_label_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["followups"][0]["labels"] = ["agent:forbidden"]
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$followup_label_patch" "$followup_label_result"
expect_failure 'followup-reserved-label' 'result-followup-label-not-ordinary' \
  --patch "$followup_label_patch" --lane review --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$review_no_work_base" --expected-head-sha "$review_no_work_head" \
  --result-out "${tmp_dir}/followup-label.out" --code-patch-out "${tmp_dir}/followup-label.code"

unchanged_followup_patch="${tmp_dir}/unchanged-followup.patch"
unchanged_followup_result="${tmp_dir}/unchanged-followup.json"
cp "$review_no_work_patch" "$unchanged_followup_patch"
make_review_followup_result "$unchanged_followup_result"
python3 - "$unchanged_followup_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["next_state"] = "unchanged"
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$unchanged_followup_patch" "$unchanged_followup_result"
expect_failure 'review-unchanged-followup' 'result-review-no-work-state-incoherent' \
  --patch "$unchanged_followup_patch" --lane review --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$review_no_work_base" --expected-head-sha "$review_no_work_head" \
  --result-out "${tmp_dir}/unchanged-followup.out" --code-patch-out "${tmp_dir}/unchanged-followup.code"

blocked_followup_patch="${tmp_dir}/blocked-followup.patch"
make_git_patch "$blocked_followup_patch" issue blocked
blocked_followup_base="$patch_base_sha"
blocked_followup_result="${tmp_dir}/blocked-followup.json"
python3 - "$blocked_followup_result" "$blocked_followup_base" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

result_path = Path(sys.argv[1])
base_sha = sys.argv[2]
title = "record unrelated discovery"
body = "<!-- rpm-agent-followup-source: issue:42 -->\nOpen a separate issue for this discovery."
fingerprint = "sha256:" + hashlib.sha256(
    title.encode("utf-8") + b"\0" + body.encode("utf-8")
).hexdigest()
value = {
    "version": 1,
    "lane": "issue",
    "status": "blocked",
    "issue": 42,
    "pr": None,
    "base_sha": base_sha,
    "head_sha": None,
    "summary": "blocked pending an external decision",
    "validation": ["blocked safely"],
    "actionable_findings_remaining": False,
    "next_state": "blocked",
    "correction_label": None,
    "resolved_thread_ids": [],
    "followups": [{
        "title": title,
        "body": body,
        "source": "issue:42",
        "fingerprint": fingerprint,
        "labels": ["bug"],
    }],
}
result_path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$blocked_followup_patch" "$blocked_followup_result"
run_validator "$blocked_followup_patch" issue 42 '' "$blocked_followup_base" \
  "${tmp_dir}/blocked-followup.result" "${tmp_dir}/blocked-followup.code" >/dev/null
grep -Fq '"next_state":"blocked"' "${tmp_dir}/blocked-followup.result" || fail 'blocked-followup-state'
grep -Fq '"followups":[{' "${tmp_dir}/blocked-followup.result" || fail 'blocked-followup-preserved'
[ ! -s "${tmp_dir}/blocked-followup.code" ] || fail 'blocked-followup-code-output-not-empty'
pass 'blocked-followup-allowed'

merge_patch="${tmp_dir}/merge.patch"
make_merge_patch "$merge_patch" merge
merge_base="$patch_base_sha"
merge_head="$patch_head_sha"
merge_result="${tmp_dir}/merge.result"
merge_code="${tmp_dir}/merge.code"
merge_output="$(cd "$validator_checkout" && "$validator" \
  --patch "$merge_patch" \
  --mode merge \
  --expected-issue 42 \
  --expected-pr 77 \
  --expected-base-sha "$merge_base" \
  --expected-head-sha "$merge_head" \
  --result-out "$merge_result" \
  --code-patch-out "$merge_code")"
printf '%s\n' "$merge_output" | grep -Fq 'lane=merge status=merge issue=42 code_paths=0' || \
  fail 'merge-output-metadata'
[ "$(wc -l <"$merge_result" | tr -d ' ')" = 1 ] || fail 'merge-result-is-one-line'
[ ! -s "$merge_code" ] || fail 'merge-code-output-not-empty'
grep -Fq '"lane":"merge"' "$merge_result" || fail 'merge-lane-validated'
grep -Fq '"pr":77' "$merge_result" || fail 'merge-pr-validated'
grep -Fq '"head_sha":"'"$merge_head"'"' "$merge_result" || fail 'merge-head-validated'
grep -Fq '"next_state":"awaiting-merge"' "$merge_result" || fail 'merge-next-state-validated'
grep -Fq '"actionable_findings_remaining":false' "$merge_result" || fail 'merge-actionable-validated'
grep -Fq '"resolved_thread_ids":[]' "$merge_result" || fail 'merge-thread-array-not-empty'
grep -Fq '"followups":[]' "$merge_result" || fail 'merge-followup-array-not-empty'
pass 'valid-merge-result-with-mode-alias'

merge_no_work_patch="${tmp_dir}/merge-no-work.patch"
make_merge_patch "$merge_no_work_patch" no-work
merge_no_work_base="$patch_base_sha"
merge_no_work_head="$patch_head_sha"
run_validator "$merge_no_work_patch" merge 42 77 "$merge_no_work_base" \
  "${tmp_dir}/merge-no-work.result" "${tmp_dir}/merge-no-work.code" "$merge_no_work_head" >/dev/null
[ ! -s "${tmp_dir}/merge-no-work.code" ] || fail 'merge-no-work-code-output-not-empty'
grep -Fq '"status":"no-work"' "${tmp_dir}/merge-no-work.result" || fail 'merge-no-work-status'
pass 'valid-merge-no-work'

merge_blocked_patch="${tmp_dir}/merge-blocked.patch"
make_merge_patch "$merge_blocked_patch" blocked
merge_blocked_base="$patch_base_sha"
merge_blocked_head="$patch_head_sha"
run_validator "$merge_blocked_patch" merge 42 77 "$merge_blocked_base" \
  "${tmp_dir}/merge-blocked.result" "${tmp_dir}/merge-blocked.code" "$merge_blocked_head" >/dev/null
[ ! -s "${tmp_dir}/merge-blocked.code" ] || fail 'merge-blocked-code-output-not-empty'
grep -Fq '"status":"blocked"' "${tmp_dir}/merge-blocked.result" || fail 'merge-blocked-status'
pass 'valid-merge-blocked'

merge_wrong_status_patch="${tmp_dir}/merge-wrong-status.patch"
make_merge_patch "$merge_wrong_status_patch" merge
merge_wrong_status_base="$patch_base_sha"
merge_wrong_status_head="$patch_head_sha"
merge_wrong_status_result="${tmp_dir}/merge-wrong-status.json"
result_json merge merge 42 77 "$merge_wrong_status_base" "$merge_wrong_status_head" \
  >"$merge_wrong_status_result"
python3 - "$merge_wrong_status_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["status"] = "patch"
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$merge_wrong_status_patch" "$merge_wrong_status_result"
expect_failure 'merge-status-patch-forbidden' 'result-merge-status-invalid' \
  --patch "$merge_wrong_status_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_wrong_status_base" --expected-head-sha "$merge_wrong_status_head" \
  --result-out "${tmp_dir}/merge-wrong-status.result" \
  --code-patch-out "${tmp_dir}/merge-wrong-status.code"

merge_arrays_patch="${tmp_dir}/merge-arrays.patch"
make_merge_patch "$merge_arrays_patch" merge
merge_arrays_base="$patch_base_sha"
merge_arrays_head="$patch_head_sha"
merge_arrays_result="${tmp_dir}/merge-arrays.json"
result_json merge merge 42 77 "$merge_arrays_base" "$merge_arrays_head" >"$merge_arrays_result"
python3 - "$merge_arrays_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["resolved_thread_ids"] = ["PRRT_FORBIDDEN"]
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$merge_arrays_patch" "$merge_arrays_result"
expect_failure 'merge-mutation-arrays' 'result-merge-mutation-arrays-must-be-empty' \
  --patch "$merge_arrays_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_arrays_base" --expected-head-sha "$merge_arrays_head" \
  --result-out "${tmp_dir}/merge-arrays.result" --code-patch-out "${tmp_dir}/merge-arrays.code"

merge_duplicate_key_patch="${tmp_dir}/merge-duplicate-key.patch"
make_merge_patch "$merge_duplicate_key_patch" merge
merge_duplicate_key_base="$patch_base_sha"
merge_duplicate_key_head="$patch_head_sha"
python3 - "$merge_duplicate_key_patch" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b'"status":"merge"'
if data.count(needle) != 1:
    raise SystemExit("merge-status-field-not-found")
path.write_bytes(data.replace(needle, needle + b',"status":"merge"', 1))
PY
expect_failure 'merge-duplicate-json-key' 'result-duplicate-json-key' \
  --patch "$merge_duplicate_key_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_duplicate_key_base" --expected-head-sha "$merge_duplicate_key_head" \
  --result-out "${tmp_dir}/merge-duplicate-key.result" \
  --code-patch-out "${tmp_dir}/merge-duplicate-key.code"

merge_additional_key_patch="${tmp_dir}/merge-additional-key.patch"
make_merge_patch "$merge_additional_key_patch" merge
merge_additional_key_base="$patch_base_sha"
merge_additional_key_head="$patch_head_sha"
python3 - "$merge_additional_key_patch" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b'"version":1'
if data.count(needle) != 1:
    raise SystemExit("merge-version-field-not-found")
path.write_bytes(data.replace(needle, needle + b',"unexpected":true', 1))
PY
expect_failure 'merge-additional-json-key' 'result-schema-keys-mismatch' \
  --patch "$merge_additional_key_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_additional_key_base" --expected-head-sha "$merge_additional_key_head" \
  --result-out "${tmp_dir}/merge-additional-key.result" \
  --code-patch-out "${tmp_dir}/merge-additional-key.code"

merge_with_code_patch="${tmp_dir}/merge-with-code.patch"
make_merge_patch "$merge_with_code_patch" merge
merge_with_code_base="$patch_base_sha"
merge_with_code_head="$patch_head_sha"
cat >>"$merge_with_code_patch" <<'EOF'
diff --git a/extra.txt b/extra.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/extra.txt
@@ -0,0 +1 @@
+unexpected
EOF
expect_failure 'merge-with-code' 'no-code-allowed-for-terminal-status' \
  --patch "$merge_with_code_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_with_code_base" --expected-head-sha "$merge_with_code_head" \
  --result-out "${tmp_dir}/merge-with-code.result" --code-patch-out "${tmp_dir}/merge-with-code.code"

merge_identity_patch="${tmp_dir}/merge-identity.patch"
make_merge_patch "$merge_identity_patch" merge
merge_identity_base="$patch_base_sha"
merge_identity_head="$patch_head_sha"
expect_failure 'merge-pr-mismatch' 'result-pr-mismatch' \
  --patch "$merge_identity_patch" --mode merge --expected-issue 42 --expected-pr 78 \
  --expected-base-sha "$merge_identity_base" --expected-head-sha "$merge_identity_head" \
  --result-out "${tmp_dir}/merge-pr-mismatch.result" --code-patch-out "${tmp_dir}/merge-pr-mismatch.code"
expect_failure 'merge-missing-pr' 'merge-requires-expected-pr' \
  --patch "$merge_identity_patch" --mode merge --expected-issue 42 \
  --expected-base-sha "$merge_identity_base" --expected-head-sha "$merge_identity_head" \
  --result-out "${tmp_dir}/merge-missing-pr.result" --code-patch-out "${tmp_dir}/merge-missing-pr.code"
expect_failure 'merge-missing-head' 'merge-requires-expected-head-sha' \
  --patch "$merge_identity_patch" --mode merge --expected-issue 42 --expected-pr 77 \
  --expected-base-sha "$merge_identity_base" \
  --result-out "${tmp_dir}/merge-missing-head.result" --code-patch-out "${tmp_dir}/merge-missing-head.code"

limit_source_patch="${tmp_dir}/limit-source.patch"
make_git_patch "$limit_source_patch" issue patch
limit_base="$patch_base_sha"
limit_result_json="${tmp_dir}/limit-base.json"
result_json issue patch 42 7 "$limit_base" >"$limit_result_json"

summary_limit_patch="${tmp_dir}/summary-limit.patch"
summary_limit_result="${tmp_dir}/summary-limit.json"
cp "$limit_source_patch" "$summary_limit_patch"
cp "$limit_result_json" "$summary_limit_result"
python3 - "$summary_limit_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["summary"] = "x" * 4001
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$summary_limit_patch" "$summary_limit_result"
expect_failure 'summary-byte-limit' 'result-summary-too-long' \
  --patch "$summary_limit_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$limit_base" --result-out "${tmp_dir}/summary-limit.result" \
  --code-patch-out "${tmp_dir}/summary-limit.code"

validation_count_patch="${tmp_dir}/validation-count.patch"
validation_count_result="${tmp_dir}/validation-count.json"
cp "$limit_source_patch" "$validation_count_patch"
cp "$limit_result_json" "$validation_count_result"
python3 - "$validation_count_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["validation"] = ["check"] * 51
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$validation_count_patch" "$validation_count_result"
expect_failure 'validation-count-limit' 'result-validation-too-many-items' \
  --patch "$validation_count_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$limit_base" --result-out "${tmp_dir}/validation-count.result" \
  --code-patch-out "${tmp_dir}/validation-count.code"

validation_bytes_patch="${tmp_dir}/validation-bytes.patch"
validation_bytes_result="${tmp_dir}/validation-bytes.json"
cp "$limit_source_patch" "$validation_bytes_patch"
cp "$limit_result_json" "$validation_bytes_result"
python3 - "$validation_bytes_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["validation"] = ["x" * 2049]
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$validation_bytes_patch" "$validation_bytes_result"
expect_failure 'validation-string-byte-limit' 'result-validation-string-too-long' \
  --patch "$validation_bytes_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$limit_base" --result-out "${tmp_dir}/validation-bytes.result" \
  --code-patch-out "${tmp_dir}/validation-bytes.code"

thread_count_patch="${tmp_dir}/thread-count.patch"
thread_count_result="${tmp_dir}/thread-count.json"
cp "$limit_source_patch" "$thread_count_patch"
cp "$limit_result_json" "$thread_count_result"
python3 - "$thread_count_result" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["resolved_thread_ids"] = [f"THREAD_{index}" for index in range(101)]
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$thread_count_patch" "$thread_count_result"
expect_failure 'thread-count-limit' 'result-resolved-thread-ids-too-many-items' \
  --patch "$thread_count_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$limit_base" --result-out "${tmp_dir}/thread-count.result" \
  --code-patch-out "${tmp_dir}/thread-count.code"

followup_count_patch="${tmp_dir}/followup-count.patch"
followup_count_result="${tmp_dir}/followup-count.json"
cp "$limit_source_patch" "$followup_count_patch"
cp "$limit_result_json" "$followup_count_result"
python3 - "$followup_count_result" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
followups = []
for index in range(6):
    title = f"follow-up {index}"
    body = "<!-- rpm-agent-followup-source: issue:42 -->\nRecord discovery."
    fingerprint = "sha256:" + hashlib.sha256(
        title.encode("utf-8") + b"\0" + body.encode("utf-8")
    ).hexdigest()
    followups.append({
        "title": title,
        "body": body,
        "source": "issue:42",
        "fingerprint": fingerprint,
        "labels": ["bug"],
    })
value["followups"] = followups
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
replace_result_line "$followup_count_patch" "$followup_count_result"
expect_failure 'followup-count-limit' 'result-followups-too-many-items' \
  --patch "$followup_count_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$limit_base" --result-out "${tmp_dir}/followup-count.result" \
  --code-patch-out "${tmp_dir}/followup-count.code"

terminal_patch="${tmp_dir}/terminal.patch"
make_git_patch "$terminal_patch" issue no-work
run_validator "$terminal_patch" issue 42 '' "$patch_base_sha" \
  "${tmp_dir}/terminal.result" "${tmp_dir}/terminal.code" >/dev/null
[ ! -s "${tmp_dir}/terminal.code" ] || fail 'no-work-code-output-not-empty'
pass 'no-work-without-code'

validator_checkout="$test_checkout"
expect_failure 'checkout-head-mismatch' 'checkout-head-mismatch' \
  --patch "$valid_patch" --lane issue --expected-issue 42 \
  --expected-base-sha 0000000000000000000000000000000000000000 \
  --result-out "${tmp_dir}/head-mismatch.result" \
  --code-patch-out "${tmp_dir}/head-mismatch.code"
[ ! -e "${tmp_dir}/head-mismatch.result" ] || fail 'head-mismatch-result-output-created'
[ ! -e "${tmp_dir}/head-mismatch.code" ] || fail 'head-mismatch-code-output-created'

missing_result="${tmp_dir}/missing-result.patch"
git_init "${tmp_dir}/missing-repo"
printf 'before\n' >"${tmp_dir}/missing-repo/src.txt"
git -C "${tmp_dir}/missing-repo" add src.txt
git -C "${tmp_dir}/missing-repo" commit -qm base
printf 'after\n' >"${tmp_dir}/missing-repo/src.txt"
git -C "${tmp_dir}/missing-repo" diff --binary >"$missing_result"
expect_failure 'result-missing' 'result-file-count-must-be-one' \
  --patch "$missing_result" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/missing.result" \
  --code-patch-out "${tmp_dir}/missing.code"

duplicate_result="${tmp_dir}/duplicate-result.patch"
cat >"$duplicate_result" <<EOF
diff --git a/.codex-cloud-result.json b/.codex-cloud-result.json
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/.codex-cloud-result.json
@@ -0,0 +1 @@
+{}
diff --git a/.codex-cloud-result.json b/.codex-cloud-result.json
new file mode 100644
index 0000000..2222222
--- /dev/null
+++ b/.codex-cloud-result.json
@@ -0,0 +1 @@
+{}
EOF
expect_failure 'result-duplicate' 'duplicate-patch-path' \
  --patch "$duplicate_result" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/duplicate.result" \
  --code-patch-out "${tmp_dir}/duplicate.code"

protected_patch="${tmp_dir}/protected.patch"
git_init "${tmp_dir}/protected-repo"
mkdir -p "${tmp_dir}/protected-repo/.github"
printf 'before\n' >"${tmp_dir}/protected-repo/src.txt"
git -C "${tmp_dir}/protected-repo" add src.txt
git -C "${tmp_dir}/protected-repo" commit -qm base
printf 'after\n' >"${tmp_dir}/protected-repo/src.txt"
printf 'unsafe\n' >"${tmp_dir}/protected-repo/.github/workflow.yml"
git -C "${tmp_dir}/protected-repo" add -N .github/workflow.yml
result_json issue patch 42 7 "$base_sha" >"${tmp_dir}/protected-repo/.codex-cloud-result.json"
git -C "${tmp_dir}/protected-repo" add -N .codex-cloud-result.json
git -C "${tmp_dir}/protected-repo" diff --binary >"$protected_patch"
expect_failure 'protected-path' 'protected-path:.github/workflow.yml' \
  --patch "$protected_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/protected.result" \
  --code-patch-out "${tmp_dir}/protected.code"

quoted_path_patch="${tmp_dir}/quoted-path.patch"
cat >"$quoted_path_patch" <<'EOF'
diff --git a/"quoted.txt" b/"quoted.txt"
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/"quoted.txt"
@@ -0,0 +1 @@
+quoted
EOF
expect_failure 'quoted-path' 'path-uses-quoted-or-escaped-form' \
  --patch "$quoted_path_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/quoted.result" \
  --code-patch-out "${tmp_dir}/quoted.code"

invisible_path_patch="${tmp_dir}/invisible-path.patch"
python3 - "$invisible_path_patch" <<'PY'
from pathlib import Path
import sys

path = "hidden-\u200b.txt"
payload = (
    f"diff --git a/{path} b/{path}\n"
    "new file mode 100644\n"
    "index 0000000..1111111\n"
    "--- /dev/null\n"
    f"+++ b/{path}\n"
    "@@ -0,0 +1 @@\n"
    "+hidden\n"
)
Path(sys.argv[1]).write_bytes(payload.encode("utf-8"))
PY
expect_failure 'invisible-path' 'path-contains-invisible-character' \
  --patch "$invisible_path_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/invisible.result" \
  --code-patch-out "${tmp_dir}/invisible.code"

binary_patch="${tmp_dir}/binary.patch"
cat >"$binary_patch" <<'EOF'
diff --git a/image.dat b/image.dat
new file mode 100644
GIT binary patch
literal 0
HcmV?d00001
EOF
expect_failure 'binary-patch' 'binary-patch-forbidden' \
  --patch "$binary_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/binary.result" \
  --code-patch-out "${tmp_dir}/binary.code"

mode_change_patch="${tmp_dir}/mode-change.patch"
cat >"$mode_change_patch" <<'EOF'
diff --git a/src.txt b/src.txt
old mode 100644
new mode 100755
EOF
expect_failure 'mode-change' 'mode-change-forbidden' \
  --patch "$mode_change_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/mode.result" \
  --code-patch-out "${tmp_dir}/mode.code"

submodule_patch="${tmp_dir}/submodule.patch"
cat >"$submodule_patch" <<'EOF'
diff --git a/submodule b/submodule
index 1111111..2222222
--- a/submodule
+++ b/submodule
Subproject commit 2222222222222222222222222222222222222222
EOF
expect_failure 'submodule' 'submodule-forbidden' \
  --patch "$submodule_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/submodule.result" \
  --code-patch-out "${tmp_dir}/submodule.code"

automation_path_patch="${tmp_dir}/automation-path.patch"
cat >"$automation_path_patch" <<'EOF'
diff --git a/scripts/safe-direct-merge.sh b/scripts/safe-direct-merge.sh
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/scripts/safe-direct-merge.sh
@@ -0,0 +1 @@
+unsafe
EOF
expect_failure 'automation-protected-path' 'protected-path:scripts/safe-direct-merge.sh' \
  --patch "$automation_path_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/automation.result" \
  --code-patch-out "${tmp_dir}/automation.code"

expect_protected_path() {
  local label="$1"
  local path="$2"
  local patch="${tmp_dir}/${label}.patch"
  local repo="${tmp_dir}/${label}-repo"

  git_init "$repo"
  printf 'before\n' >"${repo}/src.txt"
  git -C "$repo" add src.txt
  git -C "$repo" commit -qm base
  mkdir -p "${repo}/$(dirname -- "$path")"
  printf 'unsafe\n' >"${repo}/${path}"
  git -C "$repo" add -N -- "$path"
  result_json issue patch 42 7 "$base_sha" >"${repo}/.codex-cloud-result.json"
  git -C "$repo" add -N .codex-cloud-result.json
  git -C "$repo" diff --binary >"$patch"

  expect_failure "${label}-protected-path" "protected-path:${path}" \
    --patch "$patch" --lane issue --expected-issue 42 \
    --expected-base-sha "$base_sha" --result-out "${tmp_dir}/${label}.result" \
    --code-patch-out "${tmp_dir}/${label}.code"
}

expect_protected_path 'cargo-config' '.cargo/config.toml'
expect_protected_path 'clippy-config' 'clippy.toml'
expect_protected_path 'justfile' 'justfile'
expect_protected_path 'rust-toolchain-legacy' 'rust-toolchain'
expect_protected_path 'rust-toolchain' 'rust-toolchain.toml'
expect_protected_path 'rustfmt-config' 'rustfmt.toml'
expect_protected_path 'rustfmt-config-legacy' '.rustfmt.toml'
expect_protected_path 'fixture-audit' 'scripts/audit-fixtures.sh'
expect_protected_path 'benchmark-node-runner' 'scripts/benchmark-node-semver.mjs'
expect_protected_path 'benchmark-runner' 'scripts/benchmark-semver.mjs'
expect_protected_path 'cloud-setup' 'scripts/codex-cloud-setup.sh'
expect_protected_path 'cloud-lane-setup' 'scripts/setup-codex-cloud-lane.sh'
expect_protected_path 'merge-evidence-collector' 'scripts/collect-merge-gate-evidence.sh'
expect_protected_path 'trusted-merge-publisher' 'scripts/publish-cloud-merge.sh'
expect_protected_path 'merge-selector-quarantine' 'scripts/quarantine-merge-selector-anomaly.sh'
expect_protected_path 'review-correction-quarantine' 'scripts/quarantine-review-correction-limit.sh'
expect_protected_path 'review-correction-quarantine-test' 'scripts/test-quarantine-review-correction-limit.sh'
expect_protected_path 'rust-analyzer-helper' 'scripts/codex-rust-analyzer.sh'
expect_protected_path 'git-hook-installer' 'scripts/install-git-hooks.sh'
expect_protected_path 'git-hook-gate' 'scripts/run-local-git-hook-gate.sh'
expect_protected_path 'worktree-cleanup' 'scripts/worktree-cleanup.sh'
expect_protected_path 'worktree-setup' 'scripts/worktree-setup.sh'

metadata_tab_patch="${tmp_dir}/metadata-tab.patch"
python3 - "$metadata_tab_patch" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(
    b"diff --git a/tab.txt b/tab.txt\n"
    b"index 1111111..2222222\n"
    b"--- a/tab.txt\ttimestamp\n"
    b"+++ b/tab.txt\n"
    b"@@ -1 +1 @@\n"
    b"-before\n"
    b"+after\n"
)
PY
expect_failure 'metadata-tab-path' 'path-contains-whitespace' \
  --patch "$metadata_tab_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/metadata-tab.result" \
  --code-patch-out "${tmp_dir}/metadata-tab.code"

traversal_patch="${tmp_dir}/traversal.patch"
cat >"$traversal_patch" <<EOF
diff --git a/../escape b/../escape
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/../escape
@@ -0,0 +1 @@
+escape
EOF
expect_failure 'path-traversal' 'path-traversal-or-empty-component' \
  --patch "$traversal_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/traversal.result" \
  --code-patch-out "${tmp_dir}/traversal.code"

symlink_mode_patch="${tmp_dir}/symlink-mode.patch"
cat >"$symlink_mode_patch" <<EOF
diff --git a/.codex-cloud-result.json b/.codex-cloud-result.json
new file mode 120000
index 0000000..1111111
--- /dev/null
+++ b/.codex-cloud-result.json
@@ -0,0 +1 @@
+target
EOF
expect_failure 'symlink-mode' 'symlink-submodule-or-unsafe-mode-forbidden' \
  --patch "$symlink_mode_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/symlink.result" \
  --code-patch-out "${tmp_dir}/symlink.code"

rename_patch="${tmp_dir}/rename.patch"
cat >"$rename_patch" <<EOF
diff --git a/old.txt b/new.txt
similarity index 100%
rename from old.txt
rename to new.txt
EOF
expect_failure 'rename' 'rename-or-copy-forbidden' \
  --patch "$rename_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/rename.result" \
  --code-patch-out "${tmp_dir}/rename.code"

copy_patch="${tmp_dir}/copy.patch"
cat >"$copy_patch" <<EOF
diff --git a/src.txt b/copy.txt
similarity index 100%
copy from src.txt
copy to copy.txt
EOF
expect_failure 'copy' 'rename-or-copy-forbidden' \
  --patch "$copy_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/copy.result" \
  --code-patch-out "${tmp_dir}/copy.code"

oversized_patch="${tmp_dir}/oversized.patch"
python3 - "$oversized_patch" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b'x' * (10 * 1024 * 1024 + 1))
PY
expect_failure 'oversized' 'patch-too-large' \
  --patch "$oversized_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/oversized.result" \
  --code-patch-out "${tmp_dir}/oversized.code"

path_count_patch="${tmp_dir}/path-count.patch"
python3 - "$path_count_patch" <<'PY'
import pathlib
import sys

parts = []
for number in range(201):
    path = f"file-{number}.txt"
    parts.append(
        f"diff --git a/{path} b/{path}\n"
        "new file mode 100644\n"
        "index 0000000..1111111\n"
        "--- /dev/null\n"
        f"+++ b/{path}\n"
        "@@ -0,0 +1 @@\n"
        "+x\n"
    )
pathlib.Path(sys.argv[1]).write_text("".join(parts), encoding="utf-8")
PY
expect_failure 'path-count' 'patch-section-count-exceeds-200' \
  --patch "$path_count_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/count.result" \
  --code-patch-out "${tmp_dir}/count.code"

schema_patch="${tmp_dir}/schema.patch"
make_git_patch "$schema_patch"
sed 's/"version":1/"version":2/' "$schema_patch" >"${schema_patch}.bad"
mv "${schema_patch}.bad" "$schema_patch"
expect_failure 'schema-mismatch' 'result-version-must-be-1' \
  --patch "$schema_patch" --lane issue --expected-issue 42 \
  --expected-base-sha "$patch_base_sha" --result-out "${tmp_dir}/schema.result" \
  --code-patch-out "${tmp_dir}/schema.code"

no_work_with_code="${tmp_dir}/no-work-with-code.patch"
make_git_patch "$no_work_with_code" issue no-work
cat >>"$no_work_with_code" <<'EOF'
diff --git a/extra.txt b/extra.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/extra.txt
@@ -0,0 +1 @@
+unexpected
EOF
expect_failure 'no-work-with-code' 'no-code-allowed-for-terminal-status' \
  --patch "$no_work_with_code" --lane issue --expected-issue 42 \
  --expected-base-sha "$patch_base_sha" --result-out "${tmp_dir}/nowork-code.result" \
  --code-patch-out "${tmp_dir}/nowork-code.code"

patch_without_code="${tmp_dir}/patch-without-code.patch"
make_git_patch "$patch_without_code" issue patch
python3 - "$patch_without_code" "${patch_without_code}.result-only" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_bytes()
lines = source.splitlines(keepends=True)
result_header = b"diff --git a/.codex-cloud-result.json b/.codex-cloud-result.json"
output = []
keep = False
for line in lines:
    if line.startswith(b"diff --git "):
        keep = line.rstrip(b"\r\n") == result_header
    if keep:
        output.append(line)
pathlib.Path(sys.argv[2]).write_bytes(b"".join(output))
PY
mv "${patch_without_code}.result-only" "$patch_without_code"
expect_failure 'patch-without-code' 'patch-status-requires-code-patch' \
  --patch "$patch_without_code" --lane issue --expected-issue 42 \
  --expected-base-sha "$patch_base_sha" --result-out "${tmp_dir}/patch-only.result" \
  --code-patch-out "${tmp_dir}/patch-only.code"

symlink_input="${tmp_dir}/patch-symlink"
ln -s "$valid_patch" "$symlink_input"
expect_failure 'input-symlink' 'patch-symlink-forbidden' \
  --patch "$symlink_input" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/link.result" \
  --code-patch-out "${tmp_dir}/link.code"

hardlink_input="${tmp_dir}/patch-hardlink"
ln "$valid_patch" "$hardlink_input"
expect_failure 'input-hardlink' 'patch-hardlink-forbidden' \
  --patch "$hardlink_input" --lane issue --expected-issue 42 \
  --expected-base-sha "$base_sha" --result-out "${tmp_dir}/hardlink.result" \
  --code-patch-out "${tmp_dir}/hardlink.code"

printf 'validate_cloud_diff_test.PASS=all\n'
