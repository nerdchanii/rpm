#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_absent() {
  local path="$1"
  if [ -e "${path}" ]; then
    fail "obsolete file is still present: ${path}"
  fi
}

require_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if ! rg -q --fixed-strings -- "${pattern}" "${path}"; then
    fail "${description} (${path})"
  fi
}

require_no_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if rg -q --fixed-strings -- "${pattern}" "${path}"; then
    fail "${description} (${path})"
  fi
}

run_advisory_case() {
  local name="$1"
  local labels_json="$2"
  local body="$3"
  local expected_labels="$4"
  local expected_reference="$5"
  local output_file="${advisory_tmp}/${name}.out"
  local case_rc

  set +e
  PR_LABELS_JSON="${labels_json}" PR_BODY="${body}" \
    bash "${advisory_run_file}" >"${output_file}" 2>&1
  case_rc=$?
  set -e

  if [ "${case_rc}" -ne 0 ]; then
    fail "advisory case ${name} exited ${case_rc}"
    return
  fi
  require_pattern "${output_file}" \
    "pr_metadata.descriptive_labels=${expected_labels}" \
    "advisory case ${name} reported the wrong descriptive-label count"
  require_pattern "${output_file}" \
    "pr_metadata.closing_reference=${expected_reference}" \
    "advisory case ${name} reported the wrong closing reference status"
  require_pattern "${output_file}" 'pr_metadata.status=advisory' \
    "advisory case ${name} did not report advisory status"
}

# The workflow remains the metadata job, with an event-payload-only advisory
# report. The standalone checker is removed because its result is not a gate.
policy_workflow=".github/workflows/pr-policy.yml"
if [ ! -f "${policy_workflow}" ]; then
  fail "PR policy workflow is missing"
else
  require_pattern "${policy_workflow}" '  metadata:' \
    "PR policy workflow must retain the metadata job"
  require_pattern "${policy_workflow}" 'github.event.pull_request' \
    "PR policy workflow must read the event payload"
  require_pattern "${policy_workflow}" '::notice' \
    "PR policy workflow must report advisory notices"
  require_pattern "${policy_workflow}" 'advisory' \
    "PR policy workflow must report advisory status"
  require_no_pattern "${policy_workflow}" 'exit 1' \
    "PR metadata reporting must not fail on missing metadata"
  require_no_pattern "${policy_workflow}" 'failure()' \
    "PR metadata reporting must not fail on missing metadata"
  require_no_pattern "${policy_workflow}" 'actions/checkout' \
    "PR policy workflow must not checkout the repository"
  require_no_pattern "${policy_workflow}" 'gh ' \
    "PR policy workflow must not query GitHub through gh"
  require_no_pattern "${policy_workflow}" 'scripts/check-pr-policy.sh' \
    "PR policy workflow must not call the removed checker"

  advisory_tmp="$(mktemp -d)"
  advisory_run_file="${advisory_tmp}/metadata-run.sh"
  trap 'rm -rf "${advisory_tmp}"' EXIT
  awk '
    /^        run: \|$/ { in_run=1; next }
    in_run && /^          / { sub(/^          /, ""); print; next }
    in_run && /^[[:space:]]*$/ { print ""; next }
    in_run { exit }
  ' "${policy_workflow}" >"${advisory_run_file}"

  if [ ! -s "${advisory_run_file}" ]; then
    fail "PR policy metadata run block could not be extracted"
  else
    if ! bash -n "${advisory_run_file}"; then
      fail "PR policy metadata run block is not valid bash"
    fi

    run_advisory_case "empty" '[]' '' 0 missing
    require_pattern "${advisory_tmp}/empty.out" 'No descriptive label is present' \
      "empty advisory case must emit a label notice"
    require_pattern "${advisory_tmp}/empty.out" 'No closing issue reference is present' \
      "empty advisory case must emit a closing-reference notice"

    run_advisory_case "agent-only" '[{"name":"agent:claimed"}]' '' 0 missing

    run_advisory_case "descriptive-and-closing" \
      '[{"name":"refactor"},{"name":"agent:claimed"}]' \
      'Closes #206' 1 present

    malicious_marker="${advisory_tmp}/malicious-command-ran"
    malicious_labels="$(printf '[{"name":"$(touch %s)"}]' "${malicious_marker}")"
    malicious_body="$(printf 'literal payload $(touch %s)' "${malicious_marker}")"
    run_advisory_case "malicious-payload" \
      "${malicious_labels}" "${malicious_body}" 1 missing
    if [ -e "${malicious_marker}" ]; then
      fail "malicious advisory payload executed a command"
    fi
    require_no_pattern "${advisory_tmp}/malicious-payload.out" \
      "${malicious_marker}" \
      "malicious advisory payload was logged"
  fi
fi

require_absent "scripts/check-pr-policy.sh"

# Metadata remains a required check; the workflow itself is advisory about
# descriptive labels and issue links.
if ! jq -e '.merge_gate.required_checks == ["metadata", "verify"]' \
  .agents/workflows/backlog-policy.json >/dev/null; then
  fail "merge_gate.required_checks must be exactly [metadata, verify]"
fi

# These validators must encode the same metadata-plus-verify merge contract as
# policy.
require_pattern "scripts/check-agent-organization.py" \
  '"required_checks": ["metadata", "verify"]' \
  "organization validator must require metadata and verify"
require_no_pattern "scripts/check-agent-organization.py" \
  '"required_checks": ["verify"]' \
  "organization validator lost the metadata check"
require_pattern "scripts/validate-agent-workflow-assets.sh" \
  'required_checks:["metadata","verify"]' \
  "asset validator must require metadata and verify"
require_no_pattern "scripts/validate-agent-workflow-assets.sh" \
  'required_checks:["verify"]' \
  "asset validator lost the metadata check"

# The manual merge path follows the policy file at runtime. It must not carry
# a second, hard-coded required-check list.
require_pattern "scripts/safe-direct-merge.sh" \
  '.agents/workflows/backlog-policy.json' \
  "safe-direct-merge must read the merge policy"
require_pattern "scripts/safe-direct-merge.sh" \
  '.merge_gate.required_checks' \
  "safe-direct-merge must read required_checks from policy"
if rg -q 'required_checks[[:space:]]*=[[:space:]]*\([^)]*metadata[^)]*verify[^)]*\)' \
  scripts/safe-direct-merge.sh; then
  fail "safe-direct-merge hard-codes the metadata and verify checks"
fi

# Labels and closing references remain useful PR guidance, with no blocking
# wording in the contribution guide or template.
for path in CONTRIBUTING.md .github/pull_request_template.md; do
  require_no_pattern "${path}" 'must have repository metadata' \
    "PR metadata is described as mandatory"
  require_no_pattern "${path}" 'enforces this metadata' \
    "PR metadata is described as merge-enforced"
  require_no_pattern "${path}" 'apply at least one approved label' \
    "descriptive labels are presented as a blocking checklist item"
  require_no_pattern "${path}" 'replace the `Closes #` placeholder' \
    "closing issue guidance is presented as a blocking checklist item"
  require_no_pattern "${path}" 'PR has at least one approved label' \
    "descriptive labels are presented as a blocking checklist item"
  require_no_pattern "${path}" '`Closes #` below is replaced' \
    "closing issue guidance is presented as a blocking checklist item"
done

# Every merge fixture must model both required checks. This catches stale
# metadata entries in ready, pending, and failed gate scenarios.
for fixture in .agents/fixtures/backlog/merge-*.json; do
  if ! jq -e 'all(.issues[]?.closing_prs[]?; (.checks | keys) == ["metadata", "verify"])' \
    "${fixture}" >/dev/null; then
    fail "merge fixture does not contain exactly metadata and verify: ${fixture}"
  fi
done

# No tracked workflow or documentation may refer to the removed checker.
# Exclude this regression test, which names the obsolete checker intentionally.
if rg -n --hidden --glob '!.git/**' \
  --glob '!scripts/test-issue-206-pr-policy.sh' \
  'check-pr-policy|pr_policy' . >/dev/null; then
  fail "obsolete PR policy checker references remain in the repository"
fi

if [ "${failures}" -ne 0 ]; then
  printf 'issue-206-pr-policy.status=fail failures=%s\n' "${failures}" >&2
  exit 1
fi

printf 'issue-206-pr-policy.status=ok\n'
