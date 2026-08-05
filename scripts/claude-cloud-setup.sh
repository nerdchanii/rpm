#!/usr/bin/env bash
set -euo pipefail

# Claude Code cloud environment setup for RPM.
# Reference this file as the cloud environment's setup script instead of pasting
# its contents, so repository fixes reach the environment. Routines mutate
# GitHub through the MCP plugin that .claude/settings.json enables, and that
# plugin reads GITHUB_PERSONAL_ACCESS_TOKEN from the environment. The gh CLI
# below is only a fallback for that path and is not required on its own.

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if ! command -v gh >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    # Third-party repositories preconfigured in the cloud image (launchpad PPAs)
    # can fail with 403 behind the sandbox network policy, which makes
    # apt-get update exit non-zero even though the Ubuntu indexes were fetched.
    # Treat the refresh as best effort and judge only the install result.
    if ! ${SUDO} apt-get update -y; then
      printf 'claude-cloud-setup: apt-get update reported errors; continuing with the existing package index\n' >&2
    fi
    if ! ${SUDO} apt-get install -y gh; then
      printf 'claude-cloud-setup: apt-get install gh failed\n' >&2
    fi
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'claude-cloud-setup: gh is unavailable; routines must use the GitHub MCP plugin\n' >&2
fi

if [ -f Cargo.toml ] && [ -x scripts/codex-cloud-setup.sh ]; then
  ./scripts/codex-cloud-setup.sh
fi
