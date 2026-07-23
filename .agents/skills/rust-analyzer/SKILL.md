---
name: rust-analyzer
description: Use for Rust semantic analysis in RPM when Codex needs rust-analyzer batch analysis or a deterministic Cargo diagnostic fallback; this is not an LSP client integration.
---

요구 도구: Read·Bash.

# RPM Rust Analyzer

Use the repository wrapper instead of starting `rust-analyzer` as a language
server. Codex does not currently expose a documented native LSP tool, and an LSP
server is not an MCP server.

## Workflow

1. Run `scripts/codex-rust-analyzer.sh probe`.
2. If the probe reports `available`, run
   `scripts/codex-rust-analyzer.sh analyze`.
3. If the probe reports `unavailable`, do not install components automatically.
   Report the command printed by the probe and run
   `scripts/codex-rust-analyzer.sh cargo-check` when Cargo diagnostics are an
   acceptable fallback.
4. Use `scripts/codex-rust-analyzer.sh diagnose` only when a single command that
   performs steps 1–3 is convenient.
5. State whether the result came from rust-analyzer batch analysis or Cargo.
   Never describe this workflow as interactive LSP navigation, completion,
   rename, references, or code actions.

`analyze` runs `rust-analyzer analysis-stats` for the repository root. It
type-checks the project in batch mode without LSP client/server messaging.

## Installation Boundary

The wrapper may detect an unusable rustup shim. Installing the missing
component changes the user's toolchain and is outside this skill's automatic
actions. Ask the user to run the exact command emitted by `probe`, then rerun
the probe.

Read [references/capability-boundary.md](references/capability-boundary.md)
before changing this integration or proposing a Codex plugin/MCP replacement.
