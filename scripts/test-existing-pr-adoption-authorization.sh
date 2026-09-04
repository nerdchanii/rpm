#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

helper="scripts/prepare-existing-pr-adoption-authorization.py"
fixture="tests/fixtures/agent-workflow/existing-pr-adoption.json"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-adoption-authorization-test.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  if [ ! -f "$1" ]; then
    fail "missing file: $1"
  fi
}

require_file "${helper}"
require_file "${fixture}"

approval_id="$(jq -er '.authorization.approval_id' "${fixture}")"
plan_revision="$(jq -er '.authorization.plan_revision' "${fixture}")"
scope_hash="$(jq -er '.authorization.scope_hash' "${fixture}")"
executor="$(jq -er '.authorization.executor' "${fixture}")"
repository="$(jq -er '.repository' "${fixture}")"
issue="$(jq -er '.authorization.issue' "${fixture}")"
pr="$(jq -er '.authorization.pr' "${fixture}")"
base_repository="$(jq -er '.authorization.base.repository' "${fixture}")"
base_ref="$(jq -er '.authorization.base.ref' "${fixture}")"
base_sha="$(jq -er '.authorization.base.sha' "${fixture}")"
head_repository="$(jq -er '.authorization.head.repository' "${fixture}")"
head_ref="$(jq -er '.authorization.head.ref' "${fixture}")"
head_sha="$(jq -er '.authorization.head.sha' "${fixture}")"
expected_evidence_digest="$(jq -er '.authorization.evidence_digest' "${fixture}")"

run_helper() {
  local evidence_file="$1"
  PYTHONDONTWRITEBYTECODE=1 python3 "${helper}" \
    --policy .agents/workflows/backlog-policy.json \
    --evidence-file "${evidence_file}" \
    --approval-id "${approval_id}" \
    --plan-revision "${plan_revision}" \
    --scope-hash "${scope_hash}" \
    --executor "${executor}"
}

valid_output="${tmp_dir}/valid.jsonl"
if ! run_helper "${fixture}" >"${valid_output}"; then
  fail "valid prospective evidence was rejected"
else
  if [ "$(wc -l <"${valid_output}" | tr -d ' ')" -ne 1 ]; then
    fail "valid authorization output is not exactly one JSONL event"
  fi
  jq -e \
    --arg repository "${repository}" \
    --argjson issue "${issue}" \
    --argjson pr "${pr}" \
    --arg digest "${expected_evidence_digest}" \
    --arg approval "${approval_id}" \
    --arg plan "${plan_revision}" \
    --arg scope "${scope_hash}" \
    --arg executor "${executor}" \
    '.type == "existing_pr_adoption_authorization"
     and .data.status == "authorization-required"
     and .data.phase == "authorization-required"
     and .data.repository == $repository
     and .data.issue == $issue
     and .data.pr == $pr
     and .data.evidence_digest == $digest
     and .data.approval_id == $approval
     and .data.plan_revision == $plan
     and .data.scope_hash == $scope
     and .data.executor == $executor
     and .data.mutations == []
     and .data.checkpoint.requires_external_approval == true
     and .data.checkpoint.publish_exact_marker_as_issue_comment == true
     and .data.checkpoint.mutation_count == 0' \
    "${valid_output}" >/dev/null || fail "authorization checkpoint fields are incorrect"

  marker="$(jq -er '.data.marker' "${valid_output}")"
  marker_json="$(printf '%s\n' "${marker}" | sed -E 's/^<!-- rpm-agent-execution: (.*) -->$/\1/')"
  marker_keys='["approval_id","base_ref","base_repository","base_sha","evidence_digest","executor","head_ref","head_repository","head_sha","issue","plan_revision","pr","repository","scope_hash"]'
  printf '%s\n' "${marker_json}" | jq -e \
    --argjson expected_keys "${marker_keys}" \
    --arg repository "${repository}" \
    --argjson issue "${issue}" \
    --argjson pr "${pr}" \
    --arg base_repository "${base_repository}" \
    --arg base_ref "${base_ref}" \
    --arg base_sha "${base_sha}" \
    --arg head_repository "${head_repository}" \
    --arg head_ref "${head_ref}" \
    --arg head_sha "${head_sha}" \
    --arg digest "${expected_evidence_digest}" \
    --arg approval "${approval_id}" \
    --arg plan "${plan_revision}" \
    --arg scope "${scope_hash}" \
    --arg executor "${executor}" \
    'keys == $expected_keys
     and .repository == $repository
     and .issue == $issue
     and .pr == $pr
     and .base_repository == $base_repository
     and .base_ref == $base_ref
     and .base_sha == $base_sha
     and .head_repository == $head_repository
     and .head_ref == $head_ref
     and .head_sha == $head_sha
     and .evidence_digest == $digest
     and .approval_id == $approval
     and .plan_revision == $plan
     and .scope_hash == $scope
     and .executor == $executor' \
    >/dev/null || fail "marker target binding or exact field set is incorrect"

  marker_digest="$(printf '%s' "${marker}" | shasum -a 256 | awk '{print "sha256:" $1}')"
  jq -e --arg marker_digest "${marker_digest}" \
    '.data.marker_digest == $marker_digest' "${valid_output}" >/dev/null \
    || fail "marker digest is not deterministic"
fi

second_output="${tmp_dir}/second.jsonl"
if run_helper "${fixture}" >"${second_output}" && ! cmp -s "${valid_output}" "${second_output}"; then
  fail "same evidence did not produce deterministic JSONL output"
fi

stdin_output="${tmp_dir}/stdin.jsonl"
if ! cat "${fixture}" | PYTHONDONTWRITEBYTECODE=1 python3 "${helper}" \
  --policy .agents/workflows/backlog-policy.json \
  --evidence-stdin \
  --approval-id "${approval_id}" \
  --plan-revision "${plan_revision}" \
  --scope-hash "${scope_hash}" \
  --executor "${executor}" >"${stdin_output}"; then
  fail "stdin evidence path was rejected"
elif ! cmp -s "${valid_output}" "${stdin_output}"; then
  fail "file and stdin evidence paths differ"
fi

before_digest="$(shasum -a 256 "${fixture}" | awk '{print $1}')"

tampered="${tmp_dir}/tampered.json"
jq '.evidence.review.head_updated_at = "2026-08-25T12:31:00Z"' \
  "${fixture}" >"${tampered}"
set +e
tampered_output="$(run_helper "${tampered}")"
tampered_code=$?
set -e
if [ "${tampered_code}" -eq 0 ] || ! printf '%s\n' "${tampered_output}" | jq -e \
  '.data.status == "blocked" and (.data.reason | test("stale|digest"; "i"))' >/dev/null; then
  fail "evidence digest drift was accepted"
fi

missing="${tmp_dir}/missing.json"
jq 'del(.evidence.pr.head.sha)' "${fixture}" >"${missing}"
set +e
missing_output="$(run_helper "${missing}")"
missing_code=$?
set -e
if [ "${missing_code}" -eq 0 ] || ! printf '%s\n' "${missing_output}" | jq -e \
  '.data.status == "blocked" and (.data.reason | test("sha|head|identity"; "i"))' >/dev/null; then
  fail "missing target field was accepted"
fi

legacy="${tmp_dir}/legacy.json"
jq '.evidence.execution = {
  approval_id: .authorization.approval_id,
  plan_revision: .authorization.plan_revision,
  scope_hash: .authorization.scope_hash,
  executor: .authorization.executor
}' "${fixture}" >"${legacy}"
set +e
legacy_output="$(run_helper "${legacy}")"
legacy_code=$?
set -e
if [ "${legacy_code}" -eq 0 ] || ! printf '%s\n' "${legacy_output}" | jq -e \
  '.data.status == "blocked" and (.data.reason | test("legacy"; "i"))' >/dev/null; then
  fail "legacy execution metadata was accepted"
fi

set +e
missing_metadata_output="$(PYTHONDONTWRITEBYTECODE=1 python3 "${helper}" \
  --policy .agents/workflows/backlog-policy.json \
  --evidence-file "${fixture}" \
  --approval-id "" \
  --plan-revision "${plan_revision}" \
  --scope-hash "${scope_hash}" \
  --executor "${executor}")"
missing_metadata_code=$?
set -e
if [ "${missing_metadata_code}" -eq 0 ] || ! printf '%s\n' "${missing_metadata_output}" | jq -e \
  '.data.status == "blocked" and (.data.reason | test("approval_id|single-line"; "i"))' >/dev/null; then
  fail "missing approval metadata was accepted"
fi

after_digest="$(shasum -a 256 "${fixture}" | awk '{print $1}')"
if [ "${before_digest}" != "${after_digest}" ]; then
  fail "helper modified the evidence packet"
fi

# The helper is deliberately a local read-only transformer.  Keep the check
# explicit so a future change cannot quietly add a GitHub mutation path.
if rg -n -i '(^|[^[:alnum:]_])(gh|curl|wget|requests|urllib|subprocess)([^[:alnum:]_]|$)' \
  "${helper}" >/dev/null; then
  fail "authorization helper contains an external command or network client"
fi

if [ "${failures}" -ne 0 ]; then
  printf 'existing-pr-adoption-authorization.status=fail failures=%s\n' "${failures}" >&2
  exit 1
fi

printf 'existing-pr-adoption-authorization.status=ok\n'
