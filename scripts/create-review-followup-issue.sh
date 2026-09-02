#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
policy_file="${script_dir}/../.agents/workflows/backlog-policy.json"

usage() {
  cat <<'USAGE'
usage: create-review-followup-issue.sh --title <title> --body-file <path> [--source <source>] [--fingerprint <fingerprint>] [--label <label>]... [--create] [--format jsonl|text]

Create, or preview, a GitHub follow-up issue from deferred PR review feedback.

Inputs:
  --title <title>        Required issue title.
  --body-file <path>     Required Markdown body file.
  --source <source>      Optional normalized source marker value. It must be
                         pr:<positive integer> or issue:<positive integer>.
                         When omitted, the value is read from the body marker.
  --fingerprint <value>  Optional normalized fingerprint marker value. When
                         omitted, an SHA-256 fingerprint is generated.
  --label <label>        Optional. May be repeated.
  --create               Actually create the issue. Without this flag, preview only.

The source and fingerprint markers are the durable follow-up identity. The
created body starts with the source marker and fingerprint marker in that
order. The canonical body keeps the source marker and removes the fingerprint
marker. The fingerprint is SHA-256 of the final title UTF-8 bytes, one NUL
byte, and the canonical body UTF-8 bytes. Only issues carrying the policy
identity label are trusted as automation-created follow-ups. The inventory
includes both open and closed trusted issues, so a repeated invocation is
idempotent and an old issue still counts toward the policy source limit.

Preview emits result status drafted. A successful creation emits status
created after rereading and verifying the created issue. GitHub issue creation
has no compare-and-set operation; concurrent creators can still race between
inventory and create, so the next run must reconcile any duplicate.

Output:
  Prints JSONL events by default.
  The script mutates GitHub only when --create is present.
USAGE
}

title=""
body_file=""
source_input=""
fingerprint_input=""
create="false"
format="jsonl"
labels=()
run_mode="preview"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-title-value\n' >&2
        exit 2
      fi
      title="$2"
      shift 2
      ;;
    --body-file)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-body-file-value\n' >&2
        exit 2
      fi
      body_file="$2"
      shift 2
      ;;
    --source)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-source-value\n' >&2
        exit 2
      fi
      source_input="$2"
      shift 2
      ;;
    --fingerprint)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-fingerprint-value\n' >&2
        exit 2
      fi
      fingerprint_input="$2"
      shift 2
      ;;
    --label)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-label-value\n' >&2
        exit 2
      fi
      labels+=("$2")
      shift 2
      ;;
    --create)
      create="true"
      shift
      ;;
    --format)
      if [ "$#" -lt 2 ]; then
        printf 'review_followup.error=missing-format-value\n' >&2
        exit 2
      fi
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'review_followup.error=unknown-arg:%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "${create}" = "true" ]; then
  run_mode="create"
fi

if [ "${format}" != "jsonl" ] && [ "${format}" != "text" ]; then
  printf 'review_followup.error=invalid-format:%s\n' "${format}" >&2
  exit 2
fi

if [ -z "${title}" ]; then
  printf 'review_followup.error=missing-title\n' >&2
  exit 2
fi

if [ -z "${body_file}" ]; then
  printf 'review_followup.error=missing-body-file\n' >&2
  exit 2
fi

body_dir="${body_file%/*}"
body_name="${body_file##*/}"
if [ "${body_dir}" != "/tmp" ] || ! [[ "${body_name}" =~ ^rpm-review-followup-[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
  printf 'review_followup.error=unsafe-body-file-path:%s\n' "${body_file}" >&2
  exit 2
fi

if [ -L "${body_file}" ]; then
  printf 'review_followup.error=body-file-symlink:%s\n' "${body_file}" >&2
  exit 2
fi

if [ ! -f "${body_file}" ]; then
  printf 'review_followup.error=body-file-not-found:%s\n' "${body_file}" >&2
  exit 2
fi

file_link_count="$(stat -c '%h' "${body_file}" 2>/dev/null || stat -f '%l' "${body_file}" 2>/dev/null || true)"
if ! [[ "${file_link_count}" =~ ^[0-9]+$ ]] || [ "${file_link_count}" -ne 1 ]; then
  printf 'review_followup.error=body-file-link-count:%s\n' "${file_link_count:-unknown}" >&2
  exit 2
fi

body_file_size="$(stat -c '%s' "${body_file}" 2>/dev/null || stat -f '%z' "${body_file}" 2>/dev/null || true)"
body_file_max_bytes=131072
if ! [[ "${body_file_size}" =~ ^[0-9]+$ ]] || [ "${body_file_size}" -gt "${body_file_max_bytes}" ]; then
  printf 'review_followup.error=body-file-size:%s\n' "${body_file_size:-unknown}" >&2
  exit 2
fi

# Pin the validated file before reading it. A later pathname swap cannot change
# the already-open descriptor.
exec 9<"${body_file}"
if [ -L "${body_file}" ]; then
  exec 9<&-
  printf 'review_followup.error=body-file-symlink:%s\n' "${body_file}" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'review_followup.error=missing-gh\n' >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'review_followup.error=missing-jq\n' >&2
  exit 127
fi

if [ ! -f "${policy_file}" ]; then
  printf 'review_followup.error=missing-policy:%s\n' "${policy_file}" >&2
  exit 2
fi
if ! followup_identity_label="$(jq -er '.followup.identity_label | select(type == "string" and length > 0)' "${policy_file}")"; then
  printf 'review_followup.error=invalid-policy-identity-label\n' >&2
  exit 2
fi
if ! followup_repository="$(jq -er '.repository | select(type == "string" and test("^[^/[:space:]]+/[^/[:space:]]+$"))' "${policy_file}")"; then
  printf 'review_followup.error=invalid-policy-repository\n' >&2
  exit 2
fi
if ! followup_max_per_source="$(jq -er '.followup.max_per_source | select(type == "number" and . > 0 and floor == .)' "${policy_file}")"; then
  printf 'review_followup.error=invalid-policy-source-limit\n' >&2
  exit 2
fi
requested_labels=("${followup_identity_label}")
for label in "${labels[@]}"; do
  case "${label}" in
    agent:*|process:*|codex-label*)
      printf 'review_followup.error=reserved-label:%s\n' "${label}" >&2
      exit 2
      ;;
  esac
  if [ "${label}" != "${followup_identity_label}" ]; then
    requested_labels+=("${label}")
  fi
done

emit() {
  local event="$1"
  local key="$2"
  local value="$3"
  if [ "${format}" = "jsonl" ]; then
    jq -nc --arg type "${event}" --arg key "${key}" --arg value "${value}" '{type:$type, data:{($key):$value}}'
  else
    printf 'review_followup.%s=%s\n' "${key}" "${value}"
  fi
}

result() {
  local mode="$1"
  local status="$2"
  local reason="$3"
  local count="$4"
  local url="${5:-}"
  if [ "${format}" = "jsonl" ]; then
    jq -nc \
      --arg mode "${mode}" \
      --arg status "${status}" \
      --arg reason "${reason}" \
      --arg source "${source_normalized}" \
      --arg fingerprint "${fingerprint_normalized}" \
      --arg url "${url}" \
      --argjson count "${count}" \
      '{type:"review_followup_result",data:{mode:$mode,status:$status,reason:$reason,source:$source,fingerprint:$fingerprint,source_count:$count,url:(if $url == "" then null else $url end)}}'
  else
    printf 'review_followup.mode=%s\n' "${mode}"
    printf 'review_followup.status=%s\n' "${status}"
    printf 'review_followup.reason=%s\n' "${reason}"
    printf 'review_followup.source=%s\n' "${source_normalized}"
    printf 'review_followup.fingerprint=%s\n' "${fingerprint_normalized}"
    printf 'review_followup.source_count=%s\n' "${count}"
    if [ -n "${url}" ]; then
      printf 'review_followup.url=%s\n' "${url}"
    fi
  fi
}

trim_and_lower() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'
}

normalize_source() {
  local value
  value="$(trim_and_lower "$1")"
  if ! [[ "${value}" =~ ^(pr|issue):[1-9][0-9]*$ ]]; then
    return 1
  fi
  printf '%s\n' "${value}"
}

normalize_fingerprint() {
  local value
  value="$(trim_and_lower "$1")"
  if ! [[ "${value}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s\n' "${value}"
}

marker_values() {
  local kind="$1"
  local body="$2"
  printf '%s\n' "${body}" | sed -nE "s/^[[:space:]]*<!--[[:space:]]*rpm-agent-followup-${kind}:[[:space:]]*([^[:space:]<>]+)[[:space:]]*-->[[:space:]]*$/\\1/p"
}

marker_key_present() {
  local kind="$1"
  local body="$2"
  case "${body}" in
    *"rpm-agent-followup-${kind}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

marker_count() {
  local values="$1"
  if [ -z "${values}" ]; then
    printf '0\n'
  else
    printf '%s\n' "${values}" | wc -l | tr -d ' '
  fi
}

followup_fingerprint() {
  local title_value="$1"
  local body_value="$2"
  local canonical_body digest
  canonical_body="$(printf '%s' "${body_value}" | sed -E '/^[[:space:]]*<!--[[:space:]]*rpm-agent-followup-fingerprint:[[:space:]]*sha256:[0-9a-fA-F]{64}[[:space:]]*-->[[:space:]]*$/d')"
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\0%s' "${title_value}" "${canonical_body}" | sha256sum | awk '{print $1}')"
  else
    digest="$(printf '%s\0%s' "${title_value}" "${canonical_body}" | shasum -a 256 | awk '{print $1}')"
  fi
  printf 'sha256:%s\n' "${digest}"
}

strip_marker_lines() {
  local body="$1"
  printf '%s\n' "${body}" | awk '
    /^[[:space:]]*<!--[[:space:]]*rpm-agent-followup-source:[[:space:]]*[^[:space:]<>]+[[:space:]]*-->[[:space:]]*$/ { next }
    /^[[:space:]]*<!--[[:space:]]*rpm-agent-followup-fingerprint:[[:space:]]*sha256:[0-9a-fA-F]{64}[[:space:]]*-->[[:space:]]*$/ { next }
    { sub(/\r$/, ""); print }
  '
}

body="$(cat <&9)"
exec 9<&-
if [ -z "${body}" ]; then
  printf 'review_followup.error=empty-body\n' >&2
  exit 2
fi

source_values="$(marker_values source "${body}")"
source_marker_count="$(marker_count "${source_values}")"
if marker_key_present source "${body}" && [ "${source_marker_count}" -ne 1 ]; then
  printf 'review_followup.error=invalid-source-marker-count:%s\n' "${source_marker_count}" >&2
  exit 2
fi

if [ -n "${source_input}" ]; then
  if ! source_normalized="$(normalize_source "${source_input}")"; then
    printf 'review_followup.error=invalid-source\n' >&2
    exit 2
  fi
  if [ "${source_marker_count}" -eq 1 ]; then
    body_source="$(normalize_source "${source_values}")" || {
      printf 'review_followup.error=invalid-source-marker\n' >&2
      exit 2
    }
    if [ "${body_source}" != "${source_normalized}" ]; then
      printf 'review_followup.error=source-mismatch\n' >&2
      exit 2
    fi
  fi
else
  if [ "${source_marker_count}" -ne 1 ]; then
    printf 'review_followup.error=source-marker-required\n' >&2
    exit 2
  fi
  if ! source_normalized="$(normalize_source "${source_values}")"; then
    printf 'review_followup.error=invalid-source-marker\n' >&2
    exit 2
  fi
fi

fingerprint_values="$(marker_values fingerprint "${body}")"
fingerprint_marker_count="$(marker_count "${fingerprint_values}")"
if marker_key_present fingerprint "${body}" && [ "${fingerprint_marker_count}" -ne 1 ]; then
  printf 'review_followup.error=invalid-fingerprint-marker-count:%s\n' "${fingerprint_marker_count}" >&2
  exit 2
fi

if [ -n "${fingerprint_input}" ]; then
  if ! fingerprint_normalized="$(normalize_fingerprint "${fingerprint_input}")"; then
    printf 'review_followup.error=invalid-fingerprint\n' >&2
    exit 2
  fi
  if [ "${fingerprint_marker_count}" -eq 1 ]; then
    body_fingerprint="$(normalize_fingerprint "${fingerprint_values}")" || {
      printf 'review_followup.error=invalid-fingerprint-marker\n' >&2
      exit 2
    }
    if [ "${body_fingerprint}" != "${fingerprint_normalized}" ]; then
      printf 'review_followup.error=fingerprint-mismatch\n' >&2
      exit 2
    fi
  fi
elif [ "${fingerprint_marker_count}" -eq 1 ]; then
  if ! fingerprint_normalized="$(normalize_fingerprint "${fingerprint_values}")"; then
    printf 'review_followup.error=invalid-fingerprint-marker\n' >&2
    exit 2
  fi
else
  fingerprint_normalized=""
fi

body_content="$(strip_marker_lines "${body}")"
source_marker="<!-- rpm-agent-followup-source: ${source_normalized} -->"
canonical_body="${source_marker}"
if [ -n "${body_content}" ]; then
  canonical_body="${canonical_body}
${body_content}"
fi
computed_fingerprint="$(followup_fingerprint "${title}" "${canonical_body}")"
if [ -n "${fingerprint_normalized}" ] && [ "${fingerprint_normalized}" != "${computed_fingerprint}" ]; then
  printf 'review_followup.error=fingerprint-mismatch\n' >&2
  exit 2
fi
fingerprint_normalized="${computed_fingerprint}"
fingerprint_marker="<!-- rpm-agent-followup-fingerprint: ${fingerprint_normalized} -->"
if [ -n "${body_content}" ]; then
  candidate_body="${source_marker}
${fingerprint_marker}
${body_content}"
else
  candidate_body="${source_marker}
${fingerprint_marker}"
fi

emit "review_followup_input" "title" "${title}"
emit "review_followup_input" "body_file" "${body_file}"
emit "review_followup_input" "source" "${source_normalized}"
emit "review_followup_input" "fingerprint" "${fingerprint_normalized}"
emit "review_followup_input" "labels" "$(IFS=,; printf '%s' "${requested_labels[*]-}")"

temporary_files=()
cleanup() {
  local path
  for path in "${temporary_files[@]}"; do
    [ -n "${path}" ] && rm -f -- "${path}"
  done
}
trap cleanup EXIT

label_inventory_file=""
existing_labels=()
label_inventory_file="$(mktemp "${TMPDIR:-/tmp}/rpm-review-followup-labels.XXXXXX")"
temporary_files+=("${label_inventory_file}")
if ! gh label list --repo "${followup_repository}" --limit 1000 --json name >"${label_inventory_file}" 2>/dev/null; then
  result "${run_mode}" "blocked" "label-inventory-api-error" 0
  exit 1
fi
if ! jq -e 'type == "array" and length < 1000 and all(.[]; (.name | type == "string"))' "${label_inventory_file}" >/dev/null 2>&1; then
  result "${run_mode}" "blocked" "label-inventory-invalid-or-truncated" 0
  exit 1
fi
for label in "${requested_labels[@]}"; do
  if jq -e --arg label "${label}" 'any(.[]; .name == $label)' "${label_inventory_file}" >/dev/null 2>&1; then
    existing_labels+=("${label}")
  elif [ "${label}" = "${followup_identity_label}" ]; then
    result "${run_mode}" "blocked" "identity-label-missing" 0
    exit 1
  else
    emit "review_followup_label_missing" "label" "${label}"
  fi
done

inventory_file="$(mktemp "${TMPDIR:-/tmp}/rpm-review-followup-issues.XXXXXX")"
temporary_files+=("${inventory_file}")
if ! gh issue list --repo "${followup_repository}" --state all --label "${followup_identity_label}" --limit 1000 --json number,title,url,body,state >"${inventory_file}" 2>/dev/null; then
  result "${run_mode}" "blocked" "issue-inventory-api-error" 0
  exit 1
fi

if ! jq -e '
  type == "array" and
  all(.[];
    (.number | type == "number") and
    (.title | type == "string") and
    (.url | type == "string") and
    ((.body == null) or (.body | type == "string")) and
    (.state | type == "string")
  )
' "${inventory_file}" >/dev/null 2>&1; then
  result "${run_mode}" "blocked" "issue-inventory-invalid" 0
  exit 1
fi

inventory_count="$(jq 'length' "${inventory_file}")"
if [ "${inventory_count}" -ge 1000 ]; then
  result "${run_mode}" "blocked" "issue-inventory-may-be-truncated" 0
  exit 1
fi

duplicate_number=""
source_count=0
while IFS= read -r issue_json; do
  issue_title="$(printf '%s' "${issue_json}" | jq -r '.title')"
  issue_body="$(printf '%s' "${issue_json}" | jq -r '.body // ""')"
  issue_source_values="$(marker_values source "${issue_body}")"
  issue_fingerprint_values="$(marker_values fingerprint "${issue_body}")"
  issue_source_count="$(marker_count "${issue_source_values}")"
  issue_fingerprint_count="$(marker_count "${issue_fingerprint_values}")"
  if [ "${issue_source_count}" -ne 1 ] || [ "${issue_fingerprint_count}" -ne 1 ]; then
    result "${run_mode}" "blocked" "issue-inventory-marker-invalid" "${source_count}"
    exit 1
  fi
  if ! issue_source_normalized="$(normalize_source "${issue_source_values}")" || \
     ! issue_fingerprint_normalized="$(normalize_fingerprint "${issue_fingerprint_values}")"; then
    result "${run_mode}" "blocked" "issue-inventory-marker-invalid" "${source_count}"
    exit 1
  fi
  issue_source_marker="<!-- rpm-agent-followup-source: ${issue_source_normalized} -->"
  issue_fingerprint_marker="<!-- rpm-agent-followup-fingerprint: ${issue_fingerprint_normalized} -->"
  issue_first_line="$(printf '%s\n' "${issue_body}" | sed -n '1p')"
  issue_second_line="$(printf '%s\n' "${issue_body}" | sed -n '2p')"
  if [ "${issue_first_line}" != "${issue_source_marker}" ] || \
     [ "${issue_second_line}" != "${issue_fingerprint_marker}" ]; then
    result "${run_mode}" "blocked" "issue-inventory-marker-not-at-top" "${source_count}"
    exit 1
  fi
  issue_body_content="$(strip_marker_lines "${issue_body}")"
  issue_canonical_body="${issue_source_marker}"
  if [ -n "${issue_body_content}" ]; then
    issue_canonical_body="${issue_canonical_body}
${issue_body_content}"
  fi
  issue_expected_fingerprint="$(followup_fingerprint "${issue_title}" "${issue_canonical_body}")"
  if [ "${issue_fingerprint_normalized}" != "${issue_expected_fingerprint}" ]; then
    result "${run_mode}" "blocked" "issue-inventory-fingerprint-mismatch" "${source_count}"
    exit 1
  fi
  if [ "${issue_source_normalized}" = "${source_normalized}" ]; then
    source_count=$((source_count + 1))
    if [ "${issue_fingerprint_normalized}" = "${fingerprint_normalized}" ]; then
      duplicate_number="$(printf '%s' "${issue_json}" | jq -r '.number')"
    fi
  fi
done < <(jq -c '.[]' "${inventory_file}")

if [ -n "${duplicate_number}" ]; then
  if [ "${format}" = "jsonl" ]; then
    jq -nc --arg number "${duplicate_number}" '{type:"review_followup_candidate",data:{number:($number|tonumber),match:"source-and-fingerprint"}}'
  else
    printf 'review_followup.candidate=#%s match=source-and-fingerprint\n' "${duplicate_number}"
  fi
  result "${run_mode}" "duplicate" "existing-followup" "${source_count}"
  exit 0
fi

if [ "${source_count}" -ge "${followup_max_per_source}" ]; then
  result "${run_mode}" "blocked" "followup-source-limit-reached" "${source_count}"
  exit 1
fi

if [ "${format}" = "jsonl" ]; then
  jq -nc --arg source "${source_normalized}" --arg fingerprint "${fingerprint_normalized}" --argjson count "${source_count}" \
    '{type:"review_followup_inventory",data:{source:$source,fingerprint:$fingerprint,source_count:$count,state_scope:"all"}}'
else
  printf 'review_followup.existing_candidates.begin\n'
  printf 'source=%s fingerprint=%s source_count=%s state_scope=all\n' "${source_normalized}" "${fingerprint_normalized}" "${source_count}"
  printf 'review_followup.existing_candidates.end\n'
fi

if [ "${create}" != "true" ]; then
  result "preview" "drafted" "new-followup" "${source_count}"
  exit 0
fi

create_body_file="$(mktemp "${TMPDIR:-/tmp}/rpm-review-followup-body.XXXXXX")"
temporary_files+=("${create_body_file}")
printf '%s' "${candidate_body}" >"${create_body_file}"

args=(issue create --repo "${followup_repository}" --title "${title}" --body-file "${create_body_file}")
for label in "${existing_labels[@]}"; do
  args+=(--label "${label}")
done

create_error_file="$(mktemp "${TMPDIR:-/tmp}/rpm-review-followup-create.XXXXXX")"
temporary_files+=("${create_error_file}")
create_output=""
if ! create_output="$(gh "${args[@]}" 2>"${create_error_file}")"; then
  result "${run_mode}" "blocked" "issue-create-api-error" "${source_count}"
  exit 1
fi
url="$(printf '%s' "${create_output}" | sed '/^[[:space:]]*$/d' | tail -n 1)"
if [ -z "${url}" ]; then
  result "${run_mode}" "blocked" "issue-create-response-invalid" "${source_count}"
  exit 1
fi
verification_file="$(mktemp "${TMPDIR:-/tmp}/rpm-review-followup-verification.XXXXXX")"
temporary_files+=("${verification_file}")
if ! gh issue view --repo "${followup_repository}" "${url}" --json number,title,url,state,body,labels >"${verification_file}" 2>/dev/null; then
  result "${run_mode}" "blocked" "issue-create-verification-failed" "$((source_count + 1))" "${url}"
  exit 1
fi
if ! jq -e \
  --arg expected_title "${title}" \
  --arg expected_url "${url}" \
  --arg expected_body "${candidate_body}" \
  --arg identity_label "${followup_identity_label}" \
  'type == "object"
   and .title == $expected_title
   and .url == $expected_url
   and (.state | ascii_upcase) == "OPEN"
   and .body == $expected_body
   and (.labels | type == "array")
   and all(.labels[]; type == "object" and (.name | type == "string"))
   and any(.labels[]; .name == $identity_label)' \
  "${verification_file}" >/dev/null 2>&1; then
  result "${run_mode}" "blocked" "issue-create-verification-failed" "$((source_count + 1))" "${url}"
  exit 1
fi
result "create" "created" "new-followup" "$((source_count + 1))" "${url}"
