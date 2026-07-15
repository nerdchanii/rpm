# CLAUDE.md — RPM Codebase Guide for AI Assistants

This document provides essential context for AI assistants working on RPM, a fast package manager for Node.js written in Rust. It complements `AGENTS.md` (high-level judgment guidance), `CONTRIBUTING.md` (human contribution process), and the structured documentation in `docs/`.

## Quick Navigation

- **Source code**: `src/` — Rust implementation
- **Tests & Fixtures**: `tests/fixtures/` — Test data and scenarios
- **Specifications**: `docs/specs/` — Package-manager contract definitions (SSOT for behavior)
- **Architecture Decisions**: `docs/adrs/` — Long-lived boundary and split decisions
- **Conventions**: `docs/conventions/` — Module and workspace layout rules
- **Build & Validation**: `justfile` — Canonical task runner
- **Configuration**: `Cargo.toml`, `Cargo.lock`, `clippy.toml`, `rustfmt.toml`

---

## Project Overview

**RPM** (Rapid node Package Manager) is a prototype package manager designed to provide fast performance for managing Node.js packages. It is:

- Written in **Rust** for performance
- Designed for **npm ecosystem compatibility** (semver, registry, package.json semantics)
- Organized around a **SPEC-driven contract model** where written specifications are the single source of truth
- Structured with a clear **CLI/Core ownership boundary**

### Core Capabilities

- **install**: Install packages from package.json
- **add**: Add packages with specified versions
- **run**: Execute scripts defined in package.json

### Target Compatibility

Supported libraries: React, React-dom, Vite, Express, Prettier, Vue, Lodash, Svelte. The package manager is designed to be npm-compatible for semver resolution, lockfile format, and registry metadata.

---

## Repository Structure

### Workspace Layout

The repository is currently a **single Cargo package** with a planned `src/cli` / `src/core` ownership boundary (not yet reflected as directory structure).

**Ownership Principles** (from `docs/conventions/workspace_layout.md`):

- **CLI modules** (`src/main.rs`, `src/cli/`, `src/lib/opt`, `src/lib/command/mod.rs`):
  - Owns argument parsing, command dispatch, process exit codes, user-facing output
  - Must be testable as a unit without core functionality
  
- **Core modules** (`src/lib/command/working_process`, `src/lib/lockfile`, `src/lib/package_manifest`, `src/lib/node_linker`, `src/lib/api`, `src/lib/registry`):
  - Owns package-manager workflows, manifest handling, resolver, semver behavior, registry interpretation, tarball cache, lockfile loading/saving, install recovery, node_modules linking
  - **Must remain callable without CLI parsing or terminal output**
  - **No core → cli dependencies allowed**

**Key Rule**: Core must be architecture-independently usable. CLI layers on top; they never call back to core.

### Source Directory Map

```
src/
  main.rs                          # Entry point, command dispatch
  lib/
    mod.rs                         # Library facade and re-exports
    cli/
      mod.rs                       # CLI module (future separate boundary)
      opt/
        mod.rs                     # Argument parsing
        constants.rs               # CLI constant definitions
    command/
      mod.rs                       # Command implementations (future core-owned)
      working_process/
        install.rs                 # Install workflow
        add.rs                     # Add workflow
        run.rs                     # Run workflow
    lockfile/
      mod.rs                       # Lock file handling facade
      constraint.rs                # Lock file constraint types
    package_manifest/
      mod.rs                       # package.json interpretation
    node_linker/                   # node_modules linking logic
    api/
      mod.rs                       # Registry and registry API
      constants.rs                 # API constants
    registry/
      mod.rs                       # Package registry metadata
    parser/
      mod.rs                       # Parsing utilities
    common/
      mod.rs                       # Shared type definitions
      constraint.rs                # Semver constraint types
    util/
      mod.rs                       # Utility functions
```

### Test & Fixture Organization

```
tests/
  fixtures/
    install-projects/              # Full install scenario fixtures
    lockfile/                       # Lockfile format fixtures
    package_manifest/              # package.json interpretation
    registry/                       # Registry metadata fixtures
    semver/                         # Semver resolution fixtures
      node-semver/                 # npm semver baseline fixtures
```

Fixtures use reproducible, auditable structures. Use `just fixture <name>` to create new install-project fixtures and `just bench-fixture <name>` for performance baselines.

---

## Core Architecture

### Specification-Driven Development

**SPEC is the single source of truth for package-manager contracts.** Code implements SPECs; SPECs do not follow code.

**Key Rule**: When contract behavior changes, update the owning SPEC before or with code changes. Do not let code silently outrun the written contract.

**Stale SPEC Exception**: If prior changes merged without required SPEC updates, the SPEC may be corrected to match established code behavior, but this must be explicitly classified and documented.

**Current Specifications** (`docs/specs/`):

| Specification | Owner | Purpose |
|---|---|---|
| `cli/run/SPEC.md` | CLI | `rpm run` command contract |
| `core/manifest/SPEC.md` | Core | `package.json` interpretation |
| `core/semver/SPEC.md` | Core | npm-compatible semver resolution baseline |
| `core/resolver/SPEC.md` | Core | Dependency graph resolution boundary |
| `core/lockfile/SPEC.md` | Core | `rpm.lock` v1 format and compatibility |
| `core/install/cache/SPEC.md` | Core | Tarball cache filename and registry write boundary |
| `core/install/recovery/SPEC.md` | Core | Staged install replacement and recovery |
| `core/install/performance/SPEC.md` | Core | Installer bottleneck and measurement baseline |
| `core/linker/SPEC.md` | Core | `node_modules` linking contract |

**When working on contract behavior:**
1. Find the owning SPEC first
2. Classify the current state (conforms, violates, stale, or no SPEC exists)
3. Update SPEC before or with implementation changes
4. Keep tests and fixtures aligned with stated contract

### Architecture Decision Records (ADRs)

**ADRs justify architectural and long-lived boundary decisions.** Use ADRs for:

- Product or repository ownership boundaries
- Crate/package split direction
- Long-lived architectural constraints
- Decisions that future SPECs should inherit

Do not use ADRs for routine feature behavior (use SPECs instead).

**Relationship**: ADRs → ownership boundaries → SPECs → implementation

Located in `docs/adrs/` with naming convention: `XXXX-kebab-case-title.md`

---

## Rust Module Layout

Convention documented in `docs/conventions/rust_module_layout.md`.

### Guiding Principles

- **`mod.rs` is an index**: Keep it to child declarations, public re-exports, module docs, and minimal facade code. No long type definitions, impl blocks, trait impls, or domain algorithms here.

- **Type organization**: When a module owns a public type, prefer:
  ```
  module/
    mod.rs          # module index and re-exports
    types.rs        # public and internal types
    construct.rs    # constructors, parsing entrypoints
    display.rs      # Display, formatting traits
    ordering.rs     # Eq, Ord, PartialEq, PartialOrd
    parse.rs        # parser implementation
  ```
  Use domain-specific names when they fit better: `evaluate.rs`, `normalize.rs`, `desugar.rs`, `interval.rs`, `select.rs`.

- **Visibility tiers**:
  - private (default)
  - `pub(super)` for parent-module-only helpers
  - `pub(crate)` for cross-module internals
  - `pub` only for documented API surface

- **Trait impls**: Move non-trivial trait impls to dedicated files, especially `Display`, `FromStr`, `Ord`/`PartialOrd`, and conversion traits.

- **No layout changes with behavior changes**: File splits and reorganizations must not change behavior. Validate with at least `cargo check`.

---

## Development Workflow

### Local Build & Validation

Use `just` as the canonical task runner. Common commands:

```bash
# Quick checks (start with narrowest relevant check)
just check              # cargo check --locked --all-targets
just format-check       # Verify formatting without changes
just lint               # Strict Clippy with repository guardrails
just test               # Run all tests

# Broader validation (before marking PR ready)
just validate           # Run: format-check, audit-fixtures, fixture-smoke, check, lint, test, docs
alias: just verify

# Development
just format             # cargo fmt --all (in-place)
just build              # cargo build --locked (debug)
just bench *args        # Run benchmarks with optional args
just docs               # RUSTDOCFLAGS="-Dwarnings" cargo doc

# Fixture management
just fixture <name>     # Create new install-project fixture
just bench-fixture <name> # Create performance baseline fixture

# Auditing
just audit-fixtures     # ./scripts/audit-fixtures.sh
just fixture-smoke      # ./scripts/test-fixture-tools.sh
```

### Git Hooks (Optional)

Install opt-in local guardrails:

```bash
bash scripts/install-git-hooks.sh
```

Installs:
- `pre-commit`: `cargo fmt --check`
- `pre-push`: `cargo clippy` (strict) + `cargo test`

These are *guardrails*, not enforcement. CI remains the shared verification point.

### Commit Discipline

Use **atomic commits**:

- One behavior, bug, or mechanical change per commit
- No cleanup bundled with behavior changes
- No file moves bundled with behavior changes
- Explicit staging when worktree contains unrelated files

**Avoid**: `git add -A` or `git add .` without review. Always verify staged content with `git status` after staging.

### Pull Requests

**Before marking ready**:

1. Run the narrowest relevant validation locally
2. Apply at least one approved label: `bug`, `documentation`, `enhancement`, `refactor`, `planning`, `milestone-contract`, or `process:metadata-cleanup`
3. Replace the `Closes #` placeholder with a real closing issue reference, or document `No closing issue: <reason>` exemption
4. Update the PR checklist
5. Push the branch

**Metadata enforcement**: CI enforces that PRs have an approved label and a closing issue reference before they are ready for review.

**PR Template**: `.github/pull_request_template.md` — review it before creating a PR to match expected structure.

---

## Testing Strategy

### Test Organization

- **Unit tests**: Inline in source modules with `#[cfg(test)]` blocks
- **Integration tests**: Behavior-driven test scenarios in `tests/fixtures/`
- **Fixture-based testing**: Reproducible install projects and dependency scenarios

### Fixture Structure

Fixtures live in `tests/fixtures/` and test:

- **install-projects/**: Full install scenarios (semver resolution, lockfile, recovery)
- **lockfile/**: Lock file parsing, serialization, compatibility
- **package_manifest/**: package.json interpretation
- **registry/**: Package registry metadata
- **semver/**: Semver constraint satisfaction, npm baseline compatibility

**Key contract**: Fixtures must be auditable. Use `just audit-fixtures` before committing fixture changes. Fixture tools are validated with `just fixture-smoke`.

### Coverage Requirements

**Coverage floor**: 90% line coverage (enforced by `just coverage`).

```bash
just coverage  # rustup run stable cargo llvm-cov --fail-under-lines 90
```

Measure with: `cargo llvm-cov --locked --lib --bins --all-features`

---

## Code Quality Standards

### Formatting & Linting

**Formatting** (auto-fixable): `cargo fmt --all` or `just format`

**Linting** (strict guardrails):
```bash
cargo clippy --locked --all-targets --all-features -- \
  -D warnings \
  -D clippy::dbg_macro \
  -D clippy::todo \
  -D clippy::unimplemented \
  -D clippy::wildcard_imports \
  -D clippy::disallowed_methods \
  -D clippy::disallowed_types \
  -D clippy::disallowed_macros
```

Configuration in `clippy.toml` and `rustfmt.toml`.

### Documentation

**Rustdoc**: All public APIs must have documentation comments.

```bash
RUSTDOCFLAGS="-Dwarnings" cargo doc --locked --no-deps
```

Docs are treated as part of the public contract. Documentation warnings are build failures.

---

## Key Behavioral Rules for AI Assistants

### Code Changes

1. **Spec-Driven First**: Check the owning SPEC before implementing contract behavior changes. If the SPEC and code disagree, classify the mismatch (conforms, violates, stale, or no SPEC) before editing.

2. **Small, Reversible Changes**: Keep edits focused on the user's request. Do not add unrelated cleanup, abstractions, or features. One behavior, bug, or mechanical change per commit.

3. **Preserve Unrelated Work**: If the worktree contains unrelated files or changes, preserve them. Stage only what you intend to commit. Use `git status` to verify before committing.

4. **No Cleanup with Behavior Changes**: File moves, renames, and formatting-only changes must be separate commits from behavior changes. Combine them only when the move/rename is the core purpose of the patch.

5. **Visibility & Dependencies**: Respect the CLI/Core boundary. Core must have no dependencies on CLI. Use narrowest visibility (`private` → `pub(super)` → `pub(crate)` → `pub`).

6. **Comments**: Default to no comments. Add a comment only when the WHY is non-obvious: hidden constraints, subtle invariants, workarounds, or behavior that would surprise a reader.

### Testing & Validation

1. **Test Coverage**: Behavior changes should include relevant tests, fixtures, or explicit documentation of why none applies.

2. **Fixture Management**: When adding or modifying fixtures, audit them with `just audit-fixtures` before committing.

3. **Validate Before Committing**: Run the narrowest relevant validation locally:
   - `just format-check` and `just lint` for style/linting
   - `just check` for compilation
   - `just test` for behavior
   - `just validate` for comprehensive gate (runs all checks)

4. **No Half-Finished Work**: Complete implementations before committing. Do not leave TODOs, partial implementations, or feature flags unless the user explicitly asks for staged work.

### Documentation & Communication

1. **SPEC Updates**: When contract behavior changes, update the owning SPEC in the same PR or before implementation. Document the change clearly.

2. **ADR Additions**: If a change affects ownership boundaries, crate splits, or long-lived constraints, create or update the relevant ADR.

3. **Clear Scope**: If narrowing scope, explicitly state what is included, excluded, and why. Refer to specific file paths and line numbers.

4. **No Speculative Work**: Do not design for hypothetical requirements or create abstractions for future use. Build exactly what the user asked for.

---

## Common Development Tasks

### Adding a New Feature or Command

1. Create or update the owning SPEC under `docs/specs/` with the contract
2. Add test fixtures under `tests/fixtures/` demonstrating the behavior
3. Implement in the appropriate module (`src/lib/command/working_process/` for workflows, `src/lib/api/` for registry behavior, etc.)
4. Ensure tests pass and coverage stays above 90%
5. Document public APIs with rustdoc comments
6. Update AGENTS.md if the change affects AI workflows

### Fixing a Bug

1. Identify which SPEC owns the buggy behavior
2. Create a test fixture or unit test that reproduces the bug
3. Fix the bug in the relevant module
4. Verify the fix with `just test` and `just validate`
5. Check coverage remains above 90%

### Refactoring or Layout Changes

1. Ensure changes are purely mechanical (no behavior changes)
2. Validate with at least `just check` (compilation only)
3. Keep file moves and renames separate from behavior changes
4. Do not combine layout refactoring with other contract changes

### Adding Dependencies

Update `Cargo.toml` and verify:
- `cargo check --locked` compiles
- No security issues with `cargo audit`
- Licenses are compatible and recorded in `THIRD_PARTY_NOTICES.md`

---

## Debugging & Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| `Cargo.lock` out of sync | `cargo update` then `just validate` |
| Compilation errors after layout changes | Verify CLI/Core boundary; check `mod.rs` re-exports |
| Test fixtures fail audit | Run `just audit-fixtures` to see specific violations |
| Clippy fails with unknown rule | Check `clippy.toml` and `justfile` for configured rules |
| Coverage below 90% | Add tests or use `cargo llvm-cov` to identify untested paths |

### Investigation Commands

```bash
# Find symbols or keywords in codebase
grep -r "symbol_name" src/

# Check specific test scenarios
cargo test --test fixtures -- specific_fixture_name

# Generate coverage report
cargo llvm-cov --html

# Profile a specific command
time cargo build --release
./target/release/rpm <command>
```

---

## Related Documentation

- **`readme.md`**: User-facing overview and quick-start guide
- **`CONTRIBUTING.md`**: Human contributor workflow and processes
- **`AGENTS.md`**: High-level judgment guidance and source-of-truth rules
- **`docs/specs/`**: Authoritative package-manager contract documents
- **`docs/adrs/`**: Architectural decision records for long-lived boundaries
- **`docs/conventions/`**: Repository layout and module organization rules
- **`.github/pull_request_template.md`**: PR structure and metadata requirements

---

## Summary for Rapid Onboarding

When starting a task:

1. **Understand the Scope**: Read the issue or user request carefully. Reference `AGENTS.md` for judgment guidance.
2. **Find the Owning SPEC**: If touching package-manager behavior, locate and review `docs/specs/core/<domain>/SPEC.md`.
3. **Check Current State**: Does code match SPEC? If not, classify the gap before editing.
4. **Locate Relevant Code**: Use the source map above to find the right module.
5. **Write Tests First**: Add fixtures or unit tests demonstrating the desired behavior.
6. **Implement & Validate**: Make minimal, focused changes. Run `just validate` before committing.
7. **Update Docs**: Sync SPEC, ADRs, and comments with code changes.
8. **Commit Atomically**: One change per commit, with clear message referencing the issue.

---

*Last updated: 2026-07-15*  
*Maintainers: See `.github/CODEOWNERS` (if present) or repository maintainers*
