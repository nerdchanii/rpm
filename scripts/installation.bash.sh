#!/usr/bin/env bash
set -euo pipefail

cargo build --release
mkdir -p "$HOME/.rpm"
cp target/release/rpm "$HOME/.rpm/rpm"

if ! grep -q 'export PATH="$HOME/.rpm:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.rpm:$PATH"' >> "$HOME/.bashrc"
fi

echo "rpm has been installed successfully"
