#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: create-review-followup-issue.sh --title <title> --body-file <path> [--label <label>]... [--create] [--format jsonl|text]

Create, or preview, a GitHub follow-up issue from deferred PR review feedback.

Inputs:
  --title <title>       Required issue title.
  --body-file <path>   Required Markdown body file.
  --label <label>      Optional. May be repeated.
  --create             Actually create the issue. Without this flag, preview only.

Output:
  Prints JSONL events by default.
  The script mutates GitHub only when --create is present.
USAGE
}

title=""
body_file=""
create="false"
format="jsonl"
labels=()

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

if [ ! -f "${body_file}" ]; then
  printf 'review_followup.error=body-file-not-found:%s\n' "${body_file}" >&2
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

emit "review_followup_input" "title" "${title}"
emit "review_followup_input" "body_file" "${body_file}"
emit "review_followup_input" "labels" "$(IFS=,; printf '%s' "${labels[*]-}")"

existing_labels=()
if [ "${#labels[@]}" -gt 0 ]; then
  for label in "${labels[@]}"; do
    if gh label list --search "${label}" --limit 100 --json name --jq '.[].name' | grep -Fxq "${label}"; then
      existing_labels+=("${label}")
    else
      emit "review_followup_label_missing" "label" "${label}"
    fi
  done
fi

candidate_json="$(gh issue list \
  --state open \
  --search "${title}" \
  --limit 10 \
  --json number,title,url \
)"

if [ "${format}" = "jsonl" ]; then
  printf '%s' "${candidate_json}" | jq -c '.[] | {type:"review_followup_candidate", data:.}'
else
  printf 'review_followup.existing_candidates.begin\n'
  printf '%s' "${candidate_json}" | jq -r '.[] | "candidate=#\(.number) \(.url) \(.title)"'
  printf 'review_followup.existing_candidates.end\n'
fi

if [ "${create}" != "true" ]; then
  if [ "${format}" = "jsonl" ]; then
    jq -nc '{type:"review_followup_result", data:{mode:"preview", status:"draft"}}'
  else
    printf 'review_followup.mode=preview\n'
    printf 'review_followup.status=draft\n'
  fi
  exit 0
fi

args=(issue create --title "${title}" --body-file "${body_file}")
for label in "${existing_labels[@]}"; do
  args+=(--label "${label}")
done

url="$(gh "${args[@]}")"
if [ "${format}" = "jsonl" ]; then
  jq -nc --arg url "${url}" '{type:"review_followup_result", data:{mode:"create", url:$url, status:"created"}}'
else
  printf 'review_followup.mode=create\n'
  printf 'review_followup.url=%s\n' "${url}"
  printf 'review_followup.status=created\n'
fi
