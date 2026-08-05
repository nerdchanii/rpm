#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
readonly shared_settings="${repo_root}/.claude/settings.json"
readonly local_settings="${repo_root}/.claude/settings.local.json"

status=0

fail() {
  printf 'claude security: %s\n' "$1" >&2
  status=1
}

require_rule() {
  local group="$1"
  local rule="$2"

  if ! jq -e --arg group "${group}" --arg rule "${rule}" \
    '(.permissions[$group] // []) | index($rule) != null' \
    "${shared_settings}" >/dev/null; then
    fail "missing permissions.${group} rule: ${rule}"
  fi
}

check_allowlist() {
  local settings="$1"
  local rule

  while IFS= read -r rule; do
    case "${rule}" in
      "Bash(gh auth status --active --hostname github.com)") ;;
      "WebSearch") ;;
      *) fail "${settings#${repo_root}/} contains an unreviewed allow rule: ${rule}" ;;
    esac
  done < <(jq -r '.permissions.allow[]? // empty' "${settings}")
}

if [ ! -f "${shared_settings}" ]; then
  fail "missing .claude/settings.json"
else
  if ! jq -e . "${shared_settings}" >/dev/null; then
    fail ".claude/settings.json is not valid JSON"
  else
    if ! jq -e '
      .permissions.defaultMode == "default"
      and .permissions.disableBypassPermissionsMode == "disable"
      and .permissions.disableAutoMode == "disable"
    ' "${shared_settings}" >/dev/null; then
      fail "shared settings must use default mode and disable auto/bypass modes"
    fi

    check_allowlist "${shared_settings}"

    for rule in \
      "Bash(gh api *)" \
      "Bash(gh issue create *)" \
      "Bash(gh issue comment *)" \
      "Bash(gh issue close *)" \
      "Bash(gh issue delete *)" \
      "Bash(gh issue develop *)" \
      "Bash(gh issue edit *)" \
      "Bash(gh issue lock *)" \
      "Bash(gh issue pin *)" \
      "Bash(gh issue reopen *)" \
      "Bash(gh issue transfer *)" \
      "Bash(gh issue unlock *)" \
      "Bash(gh issue unpin *)" \
      "Bash(gh pr create *)" \
      "Bash(gh pr comment *)" \
      "Bash(gh pr close *)" \
      "Bash(gh pr edit *)" \
      "Bash(gh pr merge *)" \
      "Bash(gh pr ready *)" \
      "Bash(gh pr reopen *)" \
      "Bash(gh pr review *)" \
      "Bash(gh project *)" \
      "Bash(git push *)" \
      "Bash(git reset *)" \
      "Bash(git clean *)" \
      "Bash(rm *)" \
      "Bash(rmdir *)"
    do
      require_rule ask "${rule}"
    done

    for rule in \
      "Read(~/.ssh/**)" \
      "Edit(~/.ssh/**)" \
      "Read(~/.gnupg/**)" \
      "Edit(~/.gnupg/**)" \
      "Read(~/.aws/credentials)" \
      "Edit(~/.aws/credentials)" \
      "Read(~/.config/gh/hosts.yml)" \
      "Edit(~/.config/gh/hosts.yml)" \
      "Read(~/.claude/.credentials.json)" \
      "Edit(~/.claude/.credentials.json)" \
      "Read(~/.claude/history.jsonl)" \
      "Edit(~/.claude/history.jsonl)" \
      "Read(~/.claude/projects/**)" \
      "Edit(~/.claude/projects/**)" \
      "Read(~/.claude/harness-metrics/**)" \
      "Edit(~/.claude/harness-metrics/**)" \
      "Read(/.env)" \
      "Edit(/.env)" \
      "Read(/.env.*)" \
      "Edit(/.env.*)" \
      "Read(/**/.env)" \
      "Edit(/**/.env)" \
      "Read(/**/.env.*)" \
      "Edit(/**/.env.*)"
    do
      require_rule deny "${rule}"
    done
  fi
fi

if [ -f "${local_settings}" ]; then
  if ! jq -e . "${local_settings}" >/dev/null; then
    fail ".claude/settings.local.json is not valid JSON"
  else
    local_mode="$(jq -r '.permissions.defaultMode // empty' "${local_settings}")"
    case "${local_mode}" in
      "" | default | plan | dontAsk) ;;
      *) fail "local settings use an unsafe permission mode: ${local_mode}" ;;
    esac
    check_allowlist "${local_settings}"
  fi
fi

if [ ! -f "${repo_root}/CLAUDE.md" ] ||
  [ "$(cat "${repo_root}/CLAUDE.md")" != "@AGENTS.md" ]; then
  fail "CLAUDE.md must contain exactly @AGENTS.md"
fi

if [ "${status}" -ne 0 ]; then
  exit "${status}"
fi

printf 'claude_security.status=ok\n'
