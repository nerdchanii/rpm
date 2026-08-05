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
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y gh
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'claude-cloud-setup: gh is required and could not be installed\n' >&2
  exit 1
fi

if [ -f Cargo.toml ] && [ -x scripts/codex-cloud-setup.sh ]; then
  ./scripts/codex-cloud-setup.sh
fi
