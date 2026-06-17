---
name: fixture-governance
description: Create and review deterministic RPM fixtures for safe, non-mutating tests. Use when tests need package manifests, lockfiles, registry metadata, install projects, expected outputs, or regression fixtures.
---

# Fixture Governance

## Core Rule

Fixtures are immutable test inputs. Tests may copy fixtures into a temporary directory, but must not modify fixture files in place.

Use fixtures to make package-manager behavior reproducible without live network state or root repository files.

## Fixture Categories

- `fixtures/package-json/`: manifest parser tests
- `fixtures/lockfile/`: lockfile parse/write compatibility tests
- `fixtures/registry/`: offline npm metadata tests
- `fixtures/install-projects/`: integration-style install tests with expected output

## Test Workflow

1. Copy fixture into a temporary directory.
2. Run code against the temp directory.
3. Compare output to `expected/` when applicable.
4. Leave the original fixture unchanged.

## Rules

- Keep fixtures small.
- Prefer explicit expected outputs.
- Avoid live network in unit tests and resolver tests.
- Do not use root `package.json` or `rpm.lock` as test input.
- Prefer fake registry metadata over real npm calls for resolver tests.
- Add a fixture when fixing behavior that can regress.

## When To Read References

Read [references/fixture-layout.md](references/fixture-layout.md) when choosing fixture directories, examples, or review checklist details.
