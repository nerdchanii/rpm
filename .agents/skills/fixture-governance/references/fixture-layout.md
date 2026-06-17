# Fixture Layout

## Directory Shape

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

Use for integration-style install tests. Each fixture should include:

```text
package.json
registry/
expected/
```

Use `expected/` for lockfile snapshots, resolved versions, or expected filesystem tree.

## Review Checklist

Before finishing a fixture-related change, verify:

- fixture is minimal
- test copies the fixture before mutation
- expected output is committed
- fixture name describes the behavior under test
- fixture does not depend on current date, live network, machine path, or user cache
- test would fail before the intended fix
