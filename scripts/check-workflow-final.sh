#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'workflow_final.usage=check-workflow-final.sh <pr-number>\n'
  exit 2
fi

pr_number="$1"
status="ok"

if [ -n "$(git status --short)" ]; then
  status="fail"
  printf 'workflow_final.worktree=dirty\n'
else
  printf 'workflow_final.worktree=clean\n'
fi

branch="$(git branch --show-current)"
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  ahead_behind="$(git rev-list --left-right --count HEAD...'@{u}')"
  printf 'workflow_final.branch=%s\n' "${branch}"
  printf 'workflow_final.ahead_behind=%s\n' "${ahead_behind}"
  if [ "${ahead_behind}" != "0	0" ]; then
    status="fail"
  fi
else
  status="fail"
  printf 'workflow_final.branch=%s\n' "${branch}"
  printf 'workflow_final.upstream=missing\n'
fi

pr_state="$(gh pr view "${pr_number}" --json state --jq '.state')"
pr_draft="$(gh pr view "${pr_number}" --json isDraft --jq '.isDraft')"
pr_body="$(gh pr view "${pr_number}" --json body --jq '.body')"
pr_url="$(gh pr view "${pr_number}" --json url --jq '.url')"

printf 'workflow_final.pr_url=%s\n' "${pr_url}"
printf 'workflow_final.pr_state=%s\n' "${pr_state}"
printf 'workflow_final.pr_draft=%s\n' "${pr_draft}"

if [ "${pr_state}" != "OPEN" ] && [ "${pr_state}" != "MERGED" ]; then
  status="fail"
fi

if [ "${pr_draft}" != "false" ]; then
  status="fail"
fi

for required in "## Contract" "## Validation" "Closes #"; do
  if printf '%s' "${pr_body}" | grep -Fq "${required}"; then
    printf 'workflow_final.pr_body.%s=ok\n' "$(printf '%s' "${required}" | tr ' #' '__')"
  else
    status="fail"
    printf 'workflow_final.pr_body.%s=missing\n' "$(printf '%s' "${required}" | tr ' #' '__')"
  fi
done

printf 'workflow_final.status=%s\n' "${status}"

if [ "${status}" != "ok" ]; then
  exit 1
fi
