#!/usr/bin/env bash
set -euo pipefail

status="ok"

current_branch="$(git branch --show-current)"
short_status="$(git status --short)"

printf 'workflow_intake.branch=%s\n' "${current_branch}"

if [ -n "${short_status}" ]; then
  status="fail"
  printf 'workflow_intake.worktree=dirty\n'
else
  printf 'workflow_intake.worktree=clean\n'
fi

if gh auth status >/dev/null 2>&1; then
  printf 'workflow_intake.gh_auth=ok\n'
else
  status="fail"
  printf 'workflow_intake.gh_auth=fail\n'
fi

if git remote get-url origin >/dev/null 2>&1; then
  printf 'workflow_intake.origin=ok\n'
else
  status="fail"
  printf 'workflow_intake.origin=missing\n'
fi

printf 'workflow_intake.status=%s\n' "${status}"

if [ "${status}" != "ok" ]; then
  exit 1
fi
