# Capability Boundary

Checked on 2026-07-23 with `codex-cli 0.145.0`.

## Codex

The current Codex plugin documentation lists skills, hooks, apps/connectors,
MCP servers, and presentation assets as plugin components. It does not document
`lspServers`, a native LSP tool, or a rust-analyzer integration.

- Codex plugin structure:
  <https://developers.openai.com/codex/plugins/build#plugin-structure>
- Codex MCP configuration:
  <https://developers.openai.com/codex/mcp>
- Codex skills:
  <https://developers.openai.com/codex/skills>

An LSP server speaks the Language Server Protocol. Codex's documented external
tool interface is MCP. These protocols are not interchangeable, so configuring
`command = "rust-analyzer"` as an MCP server is invalid.

The Claude Code `rust-analyzer-lsp` plugin uses Claude's `lspServers` manifest
field. Marketplace discovery compatibility is not evidence that Codex
implements that field. Do not install or copy that plugin into Codex unless
OpenAI documents support in a later Codex release.

## Project-local Alternative

Codex automatically discovers repository skills under `.agents/skills`.
`scripts/codex-rust-analyzer.sh` gives the agent a deterministic shell entry
point:

- `probe`: distinguish a real rust-analyzer binary from a missing or unusable
  shim.
- `analyze`: run `rust-analyzer analysis-stats` against this repository.
- `cargo-check`: run the repository's locked, all-target Cargo diagnostic
  command.
- `diagnose`: prefer rust-analyzer batch analysis and explicitly fall back to
  Cargo when the binary is unavailable.

The rust-analyzer troubleshooting guide describes `analysis-stats` as batch
type checking that bypasses LSP machinery:
<https://rust-analyzer.github.io/book/troubleshooting.html>.

## Installation

The rust-analyzer installation guide requires the binary, Rust standard-library
sources, and an LSP-capable editor for interactive LSP features:
<https://rust-analyzer.github.io/book/installation.html>.

For a rustup shim without the installed component, the narrow installation is:

```sh
rustup component add rust-analyzer rust-src --toolchain stable
```

On macOS, an alternative standalone installation is:

```sh
brew install rust-analyzer
```

Choose one toolchain owner. A rustup proxy earlier on `PATH` can mask a
Homebrew binary, so verify the selected installation with:

```sh
command -v rust-analyzer
rust-analyzer --version
```

The wrapper never performs either installation.
