#!/usr/bin/env bash
set -euo pipefail

# Claude Code cloud environment setup for RPM.
# Configure this script as the cloud environment's setup script and set a
# GH_TOKEN environment variable on the same environment (fine-grained PAT for
# nerdchanii/rpm with contents, issues, and pull-requests read/write). The gh
# CLI reads GH_TOKEN automatically, so scheduled routines need no extra login.

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
  printf 'claude-cloud-setup: gh is required and could not be installed\n' >&2
  printf 'claude-cloud-setup: install gh in the environment image or allow the GitHub CLI package source\n' >&2
  exit 1
fi

if [ -f Cargo.toml ] && [ -x scripts/codex-cloud-setup.sh ]; then
  ./scripts/codex-cloud-setup.sh
fi
