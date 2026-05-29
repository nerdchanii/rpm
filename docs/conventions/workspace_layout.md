# Convention: Workspace Layout

Status: Draft
Owner: repository
Last reviewed: 2026-05-29

## Purpose

RPM needs explicit ownership boundaries before large behavior changes move code
across CLI parsing, resolver behavior, registry access, lockfile handling, and
`node_modules` linking.

## Rule

The repository remains a single Cargo package for now.

The current codebase should move toward a `src/cli` and `src/core` boundary
before any future Cargo workspace or multi-crate split.

The ownership boundary is:

- `cli`: owns argument parsing, command dispatch, process exit codes, and
  user-facing output.
- `core`: owns package-manager workflows, manifest handling, resolver and
  semver behavior, registry metadata interpretation, tarball/cache behavior,
  lockfile loading/saving, install recovery, and `node_modules` linking.

`core` must remain callable without CLI parsing or terminal output.

`core -> cli` dependencies are forbidden.

`cli -> core` dependencies are allowed.

Until the source tree is reorganized, these current modules map to the intended
boundary:

- `src/main.rs`, `src/lib/opt`, and `src/lib/command/mod.rs` are the current
  CLI boundary.
- `src/lib/command/working_process`, `src/lib/lockfile`,
  `src/lib/package_manifest`, `src/lib/node_linker`, `src/lib/api`, and
  `src/lib/registry` are current core-owned areas even when their paths still
  reflect earlier structure.

There is no separate `rpm-npm` boundary in the current layout. npm registry
handling and npm-compatible semver behavior belong to `core` because they are
part of RPM's package-manager contract.

## Error Cases

Layout changes must not change command behavior, lockfile format, manifest
interpretation, registry selection, tarball cache layout, or `node_modules`
layout unless the owning SPEC is updated in the same change.

## Test Fixtures

No fixtures are required for the layout decision. Build validation must cover
the current single-package root.

## Open Questions

- When the `src/cli` and `src/core` boundary should be reflected as actual
  directories in the source tree.
- What concrete extension or packaging need should trigger a future Cargo
  workspace split.
