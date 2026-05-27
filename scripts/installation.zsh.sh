#!/usr/bin/env zsh
set -e

cargo build --release
mkdir -p "$HOME/.rpm"
cp target/release/rpm "$HOME/.rpm/rpm"

if ! grep -q 'export PATH="$HOME/.rpm:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.rpm:$PATH"' >> "$HOME/.zshrc"
fi

echo "rpm has been installed successfully"
