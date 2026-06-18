#!/usr/bin/env bash
set -euo pipefail

allowed_labels=(
  "bug"
  "documentation"
  "enhancement"
  "refactor"
  "planning"
  "milestone-contract"
  "process:metadata-cleanup"
)

print_allowed_labels() {
  local separator=""
  local label

  for label in "${allowed_labels[@]}"; do
    printf '%s%s' "${separator}" "${label}"
    separator=","
  done
}

label_is_allowed() {
  local candidate="$1"
  local label

  for label in "${allowed_labels[@]}"; do
    if [ "${candidate}" = "${label}" ]; then
      return 0
    fi
  done

  return 1
}

has_allowed_label() {
  local labels="$1"
  local label

  while IFS= read -r label; do
    if label_is_allowed "${label}"; then
      return 0
    fi
  done <<< "${labels}"

  return 1
}

if [ "$#" -gt 1 ]; then
  printf 'pr_policy.usage=check-pr-policy.sh [pr-number-or-url]\n'
  exit 2
fi

pr_ref="${1:-${PR_POLICY_PR_REF:-}}"

status="ok"

printf 'pr_policy.allowed_labels=%s\n' "$(print_allowed_labels)"

if [ -n "${PR_POLICY_DRAFT:-}" ]; then
  pr_draft="${PR_POLICY_DRAFT}"
else
  pr_draft="$(gh pr view "${pr_ref}" --json isDraft --jq '.isDraft')"
fi

printf 'pr_policy.draft=%s\n' "${pr_draft}"

if [ "${pr_draft}" = "true" ]; then
  printf 'pr_policy.status=skipped\n'
  exit 0
fi

if [ -z "${pr_ref}" ] && [ -z "${PR_POLICY_LABELS:-}" ]; then
  printf 'pr_policy.usage=check-pr-policy.sh [pr-number-or-url]\n'
  exit 2
fi

if [ -n "${PR_POLICY_LABELS:-}" ]; then
  pr_labels="${PR_POLICY_LABELS}"
else
  pr_labels="$(gh pr view "${pr_ref}" --json labels --jq '.labels[].name')"
fi

if has_allowed_label "${pr_labels}"; then
  printf 'pr_policy.required_label=ok\n'
else
  status="fail"
  printf 'pr_policy.required_label=missing\n'
fi

if [ -n "${PR_POLICY_CLOSING_ISSUES_COUNT:-}" ]; then
  closing_issues_count="${PR_POLICY_CLOSING_ISSUES_COUNT}"
else
  closing_issues_count="$(gh pr view "${pr_ref}" --json closingIssuesReferences --jq '.closingIssuesReferences | length')"
fi

printf 'pr_policy.closing_issues=%s\n' "${closing_issues_count}"

if [ "${closing_issues_count}" -gt 0 ]; then
  printf 'pr_policy.connected_issue=ok\n'
else
  status="fail"
  printf 'pr_policy.connected_issue=missing\n'
fi

printf 'pr_policy.status=%s\n' "${status}"

if [ "${status}" != "ok" ]; then
  exit 1
fi
