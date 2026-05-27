#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

git clone https://github.com/nerdchanii/rpm.git "$tmp_dir/rpm"
cd "$tmp_dir/rpm"
cargo build --release
mkdir -p "$HOME/.rpm"
cp target/release/rpm "$HOME/.rpm/rpm"

echo 'Add $HOME/.rpm to PATH, or run rpm as $HOME/.rpm/rpm.'
echo "rpm has been installed successfully"
