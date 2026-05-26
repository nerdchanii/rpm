---
name: fixture-governance
description: Create and review deterministic fixtures for safe, non-mutating tests.
---

# Fixture Governance

## Core Rule

Fixtures are immutable test inputs. Tests may copy fixtures into a temporary directory, but must not modify fixture files in place.

Use fixtures to make package-manager behavior reproducible without depending on live network state or the root repository files.

## Fixture Categories

Use this structure:

```text
fixtures/
  package-json/
  lockfile/
  registry/
  install-projects/
```

## What Belongs Where

### `fixtures/package-json/`

Use for manifest parser tests.

Examples:

- minimal package
- dependencies and devDependencies
- scripts
- invalid JSON
- unsupported fields

### `fixtures/lockfile/`

Use for lockfile parse/write compatibility tests.

Examples:

- empty lockfile
- v1 basic lockfile
- invalid TOML
- missing required fields
- old schema version

### `fixtures/registry/`

Use for offline npm metadata tests.

Examples:

- package metadata with multiple versions
- scoped package metadata
- tarball URL and integrity fields
- peer dependencies
- optional dependencies

### `fixtures/install-projects/`

Use for integration-style install tests.

Each install fixture should include:

```text
package.json
registry/
expected/
```

Use `expected/` for lockfile snapshots, resolved versions, or expected filesystem tree.

## Test Workflow

1. Copy fixture into a temporary directory.
2. Run code against the temp directory.
3. Compare output to `expected/`.
4. Leave the original fixture unchanged.

## Rules

- Keep fixtures small.
- Prefer explicit expected outputs.
- Avoid live network in unit tests and resolver tests.
- Do not use the repository root `package.json` or `rpm.lock` as test input.
- Prefer fake registry metadata over real npm calls for resolver tests.
- Add a fixture when fixing a behavior that can regress.
- Keep `fixtures/` for tests and `examples/` for human-facing demos.

## Review Checklist

Before finishing a fixture-related change, verify:

- The fixture is minimal.
- The test copies the fixture before mutation.
- Expected output is committed.
- The fixture name describes the behavior under test.
- No fixture depends on current date, live network, machine path, or user cache.
- The test would fail before the intended fix.
