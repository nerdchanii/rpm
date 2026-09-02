#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/scripts/create-review-followup-issue.sh"

fail() {
  printf 'review_followup_test.FAIL=%s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'review_followup_test.PASS=%s\n' "$1"
}

assert_result() {
  local output="$1"
  local status="$2"
  local reason="$3"
  printf '%s\n' "${output}" | jq -e --arg status "${status}" --arg reason "${reason}" \
    'select(.type == "review_followup_result") | .data.status == $status and .data.reason == $reason' \
    >/dev/null || fail "result was not ${status}/${reason}: ${output}"
}

fingerprint_for() {
  local title_value="$1"
  local source_value="$2"
  local content="$3"
  local source_marker="<!-- rpm-agent-followup-source: ${source_value} -->"
  local canonical_body="${source_marker}"
  local digest
  if [ -n "${content}" ]; then
    canonical_body="${canonical_body}"$'\n'"${content}"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\0%s' "${title_value}" "${canonical_body}" | sha256sum | awk '{print $1}')"
  else
    digest="$(printf '%s\0%s' "${title_value}" "${canonical_body}" | shasum -a 256 | awk '{print $1}')"
  fi
  printf 'sha256:%s\n' "${digest}"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-review-followup-test.XXXXXX")"
run_token="$$-${RANDOM}"
secure_files=()
cleanup() {
  rm -rf "${tmp_dir}"
  if [ "${#secure_files[@]}" -gt 0 ]; then
    rm -f -- "${secure_files[@]}"
  fi
}
trap cleanup EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

issues_file="${GH_FAKE_ISSUES_FILE:?GH_FAKE_ISSUES_FILE is required}"

case "${1:-} ${2:-}" in
  "label list")
    if [ "${GH_FAKE_FAIL_LABEL_LIST:-false}" = "true" ]; then
      exit 42
    fi
    case " $* " in
      *" --repo nerdchanii/rpm "*) ;;
      *) exit 96 ;;
    esac
    printf '%s\n' "${GH_FAKE_LABELS:-[]}"
    ;;
  "issue list")
    if [ "${GH_FAKE_FAIL_ISSUE_LIST:-false}" = "true" ]; then
      exit 43
    fi
    case " $* " in
      *" --repo nerdchanii/rpm "*) ;;
      *) exit 96 ;;
    esac
    case " $* " in
      *" --label process:agent-followup "*) ;;
      *) exit 98 ;;
    esac
    jq --arg label process:agent-followup \
      '[.[] | select((.labels // []) | index($label) != null) | del(.labels)]' "${issues_file}"
    ;;
  "issue create")
    if [ "${GH_FAKE_FAIL_ISSUE_CREATE:-false}" = "true" ]; then
      exit 44
    fi
    title=""
    body_file=""
    identity_label="false"
    repo=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --label)
          if [ "$2" = "process:agent-followup" ]; then identity_label="true"; fi
          shift 2
          ;;
        *) shift ;;
      esac
    done
    [ "${repo}" = "nerdchanii/rpm" ] || exit 96
    [ "${identity_label}" = "true" ] || exit 97
    number="$(jq '([.[].number] | max // 0) + 1' "${issues_file}")"
    body="$(<"${body_file}")"
    url="https://github.com/nerdchanii/rpm/issues/${number}"
    jq --argjson number "${number}" --arg title "${title}" --arg body "${body}" --arg url "${url}" \
      '. + [{number:$number,title:$title,url:$url,state:"OPEN",body:$body,labels:["process:agent-followup"]}]' "${issues_file}" >"${issues_file}.next"
    mv "${issues_file}.next" "${issues_file}"
    count_file="${GH_FAKE_CREATE_COUNT_FILE:?GH_FAKE_CREATE_COUNT_FILE is required}"
    count="$(cat "${count_file}" 2>/dev/null || printf '0')"
    printf '%s\n' "$((count + 1))" >"${count_file}"
    printf '%s\n' "${url}"
    ;;
  "issue view")
    repo=""
    url=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    [ "${repo}" = "nerdchanii/rpm" ] || exit 96
    jq --arg url "${url}" \
      '.[] | select(.url == $url) | . + {labels:[.labels[]? | {name:.}]}' "${issues_file}"
    ;;
  *)
    printf 'unexpected fake gh call: %s\n' "$*" >&2
    exit 99
    ;;
esac
FAKE_GH
chmod +x "${fake_bin}/gh"

common_env=(
  PATH="${fake_bin}:${PATH}"
  GH_FAKE_ISSUES_FILE="${tmp_dir}/issues.json"
  GH_FAKE_CREATE_COUNT_FILE="${tmp_dir}/create-count"
  GH_FAKE_LABELS='[{"name":"process:agent-followup"}]'
)

printf '0\n' >"${tmp_dir}/create-count"
preview_title='Deferred finding'
preview_source='pr:219'
preview_details='Deferred finding details.'
preview_fingerprint="$(fingerprint_for "${preview_title}" "${preview_source}" "${preview_details}")"
body_file="/tmp/rpm-review-followup-body-${run_token}.md"
secure_files+=("${body_file}")
printf '%s\n' \
  '<!-- rpm-agent-followup-source: PR:219 -->' \
  'Deferred finding details.' >"${body_file}"

printf '%s\n' '[]' >"${tmp_dir}/issues.json"
preview_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${preview_title}" --body-file "${body_file}" --source PR:219 --format jsonl)"
assert_result "${preview_output}" drafted new-followup
printf '%s\n' "${preview_output}" | jq -e --arg fingerprint "${preview_fingerprint}" \
  'select(.type == "review_followup_result") | .data.mode == "preview" and .data.source_count == 0 and .data.source == "pr:219" and .data.fingerprint == $fingerprint' \
  >/dev/null || fail "preview did not expose the canonical identity"
pass "preview uses drafted status and canonical identity"

set +e
invalid_source_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${preview_title}" --body-file "${body_file}" --source 'owner/repo#219' --format jsonl 2>&1)"
invalid_source_status=$?
set -e
[ "${invalid_source_status}" -eq 2 ] || fail "invalid source was accepted"
printf '%s\n' "${invalid_source_output}" | grep -Fq 'review_followup.error=invalid-source' \
  || fail "invalid source error was missing"
pass "source accepts only pr or issue positive integers"

for reserved_label in agent:ready process:triage process:agent-followup codex-label codex-label:retry; do
  set +e
  reserved_output="$(env "${common_env[@]}" bash "${helper}" \
    --title "${preview_title}" --body-file "${body_file}" --source pr:219 \
    --label "${reserved_label}" --format jsonl 2>&1)"
  reserved_status=$?
  set -e
  [ "${reserved_status}" -eq 2 ] || fail "reserved label was accepted: ${reserved_label}"
  printf '%s\n' "${reserved_output}" | grep -Fq "review_followup.error=reserved-label:${reserved_label}" \
    || fail "reserved label error was missing: ${reserved_label}"
done
pass "queue and trigger labels are rejected"

set +e
mismatch_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${preview_title}" --body-file "${body_file}" --source pr:219 \
  --fingerprint sha256:0000000000000000000000000000000000000000000000000000000000000000 \
  --format jsonl 2>&1)"
mismatch_status=$?
set -e
[ "${mismatch_status}" -eq 2 ] || fail "fingerprint mismatch was accepted"
printf '%s\n' "${mismatch_output}" | grep -Fq 'review_followup.error=fingerprint-mismatch' \
  || fail "fingerprint mismatch error was missing"
pass "fingerprint must match title and canonical body"

created_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${preview_title}" --body-file "${body_file}" --source PR:219 \
  --fingerprint "SHA256:${preview_fingerprint#sha256:}" --create --format jsonl)"
assert_result "${created_output}" created new-followup
printf '%s\n' "${created_output}" | jq -e \
  'select(.type == "review_followup_result") | .data.mode == "create" and .data.source_count == 1' \
  >/dev/null || fail "created follow-up result was incomplete"
[ "$(cat "${tmp_dir}/create-count")" = "1" ] || fail "create count was not one"
created_body="$(jq -r '.[0].body' "${tmp_dir}/issues.json")"
[ "$(printf '%s\n' "${created_body}" | sed -n '1p')" = '<!-- rpm-agent-followup-source: pr:219 -->' ] \
  || fail "created body source marker was not first"
[ "$(printf '%s\n' "${created_body}" | sed -n '2p')" = "<!-- rpm-agent-followup-fingerprint: ${preview_fingerprint} -->" ] \
  || fail "created body fingerprint marker was not second"
pass "created body stores source and fingerprint markers at the top"

second_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${preview_title}" --body-file "${body_file}" --source pr:219 \
  --create --format jsonl)"
assert_result "${second_output}" duplicate existing-followup
[ "$(cat "${tmp_dir}/create-count")" = "1" ] || fail "repeated create was not idempotent"
pass "creation is marker-idempotent"

set +e
identity_label_output="$(env "${common_env[@]}" GH_FAKE_LABELS='[]' bash "${helper}" \
  --title 'Missing identity label' --body-file "${body_file}" --format jsonl)"
identity_label_status=$?
set -e
[ "${identity_label_status}" -eq 1 ] || fail "missing identity label did not block"
assert_result "${identity_label_output}" blocked identity-label-missing
pass "required identity label fails closed"

printf '[]\n' >"${tmp_dir}/issues.json"
for ordinal in 1 2 3 4 5; do
  limit_title="Finding ${ordinal}"
  limit_details="Details ${ordinal}."
  limit_existing_fingerprint="$(fingerprint_for "${limit_title}" pr:219 "${limit_details}")"
  jq --argjson number "${ordinal}" --arg title "${limit_title}" \
    --arg details "${limit_details}" --arg fingerprint "${limit_existing_fingerprint}" \
    '. + [{number:$number,title:$title,url:("https://example.test/" + ($number|tostring)),state:(if $number < 4 then "OPEN" else "CLOSED" end),body:("<!-- rpm-agent-followup-source: pr:219 -->\n<!-- rpm-agent-followup-fingerprint: " + $fingerprint + " -->\n" + $details),labels:["process:agent-followup"]}]' \
    "${tmp_dir}/issues.json" >"${tmp_dir}/issues.next"
  mv "${tmp_dir}/issues.next" "${tmp_dir}/issues.json"
done
limit_body_file="/tmp/rpm-review-followup-limit-${run_token}.md"
secure_files+=("${limit_body_file}")
printf '%s\n' '<!-- rpm-agent-followup-source: pr:219 -->' 'Sixth finding details.' >"${limit_body_file}"
limit_fingerprint="$(fingerprint_for 'sixth finding' pr:219 'Sixth finding details.')"
limit_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'sixth finding' --body-file "${limit_body_file}" --source pr:219 --fingerprint "${limit_fingerprint}" \
  --format jsonl 2>/dev/null || true)"
assert_result "${limit_output}" blocked followup-source-limit-reached
printf '%s\n' "${limit_output}" | jq -e \
  'select(.type == "review_followup_result") | .data.source_count == 5 and .data.url == null' \
  >/dev/null || fail "source limit did not include closed issues"
pass "source limit counts open and closed issues"

printf '%s\n' '[]' >"${tmp_dir}/issues.json"
api_output="$(env "${common_env[@]}" GH_FAKE_FAIL_ISSUE_LIST=true bash "${helper}" \
  --title 'inventory outage' --body-file "${body_file}" --source pr:219 --format jsonl 2>/dev/null || true)"
assert_result "${api_output}" blocked issue-inventory-api-error
pass "inventory API error fails closed"

jq -n '[range(0; 1000) | {number:.,title:"issue",url:("https://example.test/" + (.|tostring)),state:"OPEN",body:"",labels:["process:agent-followup"]}]' >"${tmp_dir}/issues.json"
truncation_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'possibly truncated inventory' --body-file "${body_file}" --source pr:219 --format jsonl 2>/dev/null || true)"
assert_result "${truncation_output}" blocked issue-inventory-may-be-truncated
pass "inventory truncation fails closed"

printf '%s\n' '[]' >"${tmp_dir}/issues.json"
printf '0\n' >"${tmp_dir}/create-count"
create_body_file="/tmp/rpm-review-followup-create-${run_token}.md"
secure_files+=("${create_body_file}")
create_title='new deferred finding'
create_source='issue:219'
create_details='Details without identity markers.'
create_fingerprint="$(fingerprint_for "${create_title}" "${create_source}" "${create_details}")"
printf '%s\n' 'Details without identity markers.' >"${create_body_file}"
create_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${create_title}" --body-file "${create_body_file}" \
  --source ISSUE:219 --fingerprint "SHA256:${create_fingerprint#sha256:}" \
  --create --format jsonl)"
assert_result "${create_output}" created new-followup
printf '%s\n' "${create_output}" | jq -e \
  'select(.type == "review_followup_result") | .data.mode == "create" and .data.source_count == 1' \
  >/dev/null || fail "created follow-up result was incomplete"
second_output="$(env "${common_env[@]}" bash "${helper}" \
  --title "${create_title}" --body-file "${create_body_file}" \
  --source issue:219 --fingerprint "${create_fingerprint}" \
  --create --format jsonl)"
assert_result "${second_output}" duplicate existing-followup
[ "$(cat "${tmp_dir}/create-count")" = "1" ] || fail "repeated create was not idempotent"
created_body="$(jq -r '.[0].body' "${tmp_dir}/issues.json")"
printf '%s\n' "${created_body}" | grep -Fq '<!-- rpm-agent-followup-source: issue:219 -->' \
  || fail "created body did not contain normalized source marker"
printf '%s\n' "${created_body}" | grep -Fq "<!-- rpm-agent-followup-fingerprint: ${create_fingerprint} -->" \
  || fail "created body did not contain normalized fingerprint marker"
pass "creation is marker-idempotent"

symlink_body_file="/tmp/rpm-review-followup-symlink-${run_token}.md"
symlink_target="/tmp/rpm-review-followup-symlink-target-${run_token}.md"
secure_files+=("${symlink_body_file}" "${symlink_target}")
printf '%s\n' '<!-- rpm-agent-followup-source: pr:219 -->' 'symlink details' >"${symlink_target}"
ln -s "${symlink_target}" "${symlink_body_file}"
symlink_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'symlink body' --body-file "${symlink_body_file}" --format jsonl 2>&1 || true)"
printf '%s\n' "${symlink_output}" | grep -Fq 'review_followup.error=body-file-symlink:' \
  || fail "symlink body file was not rejected"
pass "symlink body file is rejected"

hardlink_body_file="/tmp/rpm-review-followup-hardlink-${run_token}.md"
hardlink_target="/tmp/rpm-review-followup-hardlink-target-${run_token}.md"
secure_files+=("${hardlink_body_file}" "${hardlink_target}")
printf '%s\n' '<!-- rpm-agent-followup-source: pr:219 -->' 'hardlink details' >"${hardlink_target}"
ln "${hardlink_target}" "${hardlink_body_file}"
hardlink_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'hardlink body' --body-file "${hardlink_body_file}" --format jsonl 2>&1 || true)"
printf '%s\n' "${hardlink_output}" | grep -Fq 'review_followup.error=body-file-link-count:2' \
  || fail "hardlink body file was not rejected"
pass "hardlink body file is rejected"

oversized_body_file="/tmp/rpm-review-followup-oversized-${run_token}.md"
secure_files+=("${oversized_body_file}")
dd if=/dev/zero of="${oversized_body_file}" bs=131073 count=1 2>/dev/null
oversized_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'oversized body' --body-file "${oversized_body_file}" --source pr:219 --format jsonl 2>&1 || true)"
printf '%s\n' "${oversized_output}" | grep -Fq 'review_followup.error=body-file-size:131073' \
  || fail "oversized body file was not rejected"
pass "oversized body file is rejected"

unsafe_path_output="$(env "${common_env[@]}" bash "${helper}" \
  --title 'nested body' --body-file "${tmp_dir}/nested.md" --source pr:219 --format jsonl 2>&1 || true)"
printf '%s\n' "${unsafe_path_output}" | grep -Fq 'review_followup.error=unsafe-body-file-path:' \
  || fail "body file outside the approved path was not rejected"
pass "body path is restricted"

bash -n "${helper}" || fail "helper syntax"
pass "helper syntax"
