#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: check-agent-backlog-access.sh [--format jsonl|text]

Read-only preflight for local RPM backlog preparation. It validates repository
identity, the six lifecycle labels, and read access to the configured
local-roadmap GitHub Project and its items. Cloud ticket execution does not run
this command. It never creates or edits GitHub resources.
USAGE
}

format="jsonl"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      [ "$#" -ge 2 ] || {
        printf 'backlog_access.error=missing-format-value\n' >&2
        exit 2
      }
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
      printf 'backlog_access.error=unknown-argument:%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "${format}" in
  jsonl|text) ;;
  *)
    printf 'backlog_access.error=invalid-format:%s\n' "${format}" >&2
    exit 2
    ;;
esac

command -v gh >/dev/null 2>&1 || {
  printf 'backlog_access.error=missing-gh\n' >&2
  exit 127
}
command -v jq >/dev/null 2>&1 || {
  printf 'backlog_access.error=missing-jq\n' >&2
  exit 127
}

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'backlog_access.error=not-a-git-worktree\n' >&2
  exit 2
}
policy="${root}/.agents/workflows/backlog-policy.json"
[ -f "${policy}" ] || {
  printf 'backlog_access.error=missing-policy:%s\n' "${policy}" >&2
  exit 2
}

if ! jq -e '
  (.version == 3)
  and (.repository | type == "string" and length > 0)
  and (.project.number == 7)
  and (.project.owner | type == "string" and length > 0)
  and (.project.role == "local-roadmap")
  and (.project.required_for_execution == false)
  and (.labels == {
    research:"agent:research",
    ready:"agent:ready",
    claimed:"agent:claimed",
    "review-pending":"agent:review-pending",
    "awaiting-merge":"agent:awaiting-merge",
    blocked:"agent:blocked"
  })
' "${policy}" >/dev/null; then
  printf 'backlog_access.error=invalid-policy-contract:%s\n' "${policy}" >&2
  exit 2
fi

repository="$(jq -r '.repository' "${policy}")"
project_owner="$(jq -r '.project.owner' "${policy}")"
project_number="$(jq -r '.project.number' "${policy}")"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-backlog-access.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT
checks="${temp_dir}/checks.jsonl"
: >"${checks}"
blocked=0

emit_check() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  jq -nc \
    --arg name "${name}" \
    --arg status "${status}" \
    --arg detail "${detail}" \
    '{type:"backlog_access_check",data:{name:$name,status:$status,detail:(if $detail == "" then null else $detail end)}}' \
    >>"${checks}"
}

capture() {
  local destination="$1"
  shift
  local stderr_file="${destination}.stderr"
  if "$@" >"${destination}" 2>"${stderr_file}"; then
    return 0
  fi
  tr '\n' ' ' <"${stderr_file}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
  return 1
}

repo_json="${temp_dir}/repo.json"
if detail="$(capture "${repo_json}" gh repo view --json nameWithOwner)"; then
  actual_repository="$(jq -r '.nameWithOwner // ""' "${repo_json}")"
  if [ "${actual_repository}" = "${repository}" ]; then
    emit_check "repository_identity" "ok" "${actual_repository}"
  else
    blocked=1
    emit_check "repository_identity" "blocked" "expected=${repository} actual=${actual_repository}"
  fi
else
  blocked=1
  emit_check "repository_identity" "blocked" "${detail}"
fi

labels_json="${temp_dir}/labels.json"
if detail="$(capture "${labels_json}" gh label list --limit 1000 --json name)"; then
  missing_labels="$(
    jq -nr \
      --slurpfile actual "${labels_json}" \
      --slurpfile policy "${policy}" '
      ($actual[0] | map(.name)) as $names
      | [$policy[0].labels[] as $required | select(($names | index($required)) == null) | $required]
      | join(",")
    '
  )"
  if [ -z "${missing_labels}" ]; then
    emit_check "queue_labels" "ok"
  else
    blocked=1
    emit_check "queue_labels" "blocked" "missing=${missing_labels}"
  fi
else
  blocked=1
  emit_check "queue_labels" "blocked" "${detail}"
fi

project_json="${temp_dir}/project.json"
if detail="$(capture "${project_json}" gh project view "${project_number}" --owner "${project_owner}" --format json)"; then
  actual_number="$(jq -r '.number // ""' "${project_json}")"
  if [ "${actual_number}" = "${project_number}" ]; then
    emit_check "project_view" "ok" "project=${project_number}"
  else
    blocked=1
    emit_check "project_view" "blocked" "expected=${project_number} actual=${actual_number}"
  fi
else
  blocked=1
  emit_check "project_view" "blocked" "${detail}"
fi

items_json="${temp_dir}/items.json"
if detail="$(capture "${items_json}" gh project item-list "${project_number}" --owner "${project_owner}" --limit 1 --format json)"; then
  if jq -e '.items | type == "array"' "${items_json}" >/dev/null; then
    emit_check "project_items" "ok"
  else
    blocked=1
    emit_check "project_items" "blocked" "response has no items array"
  fi
else
  blocked=1
  emit_check "project_items" "blocked" "${detail}"
fi

if [ "${format}" = "jsonl" ]; then
  cat "${checks}"
  jq -nc \
    --arg status "$([ "${blocked}" -eq 0 ] && printf ok || printf blocked)" \
    --arg repository "${repository}" \
    --argjson project "${project_number}" \
    '{type:"backlog_access_result",data:{status:$status,repository:$repository,project:$project}}'
else
  jq -r '"backlog_access." + .data.name + "=" + .data.status + (if .data.detail then ":" + .data.detail else "" end)' "${checks}"
  printf 'backlog_access.status=%s\n' "$([ "${blocked}" -eq 0 ] && printf ok || printf blocked)"
fi

if [ "${blocked}" -ne 0 ]; then
  exit 3
fi
