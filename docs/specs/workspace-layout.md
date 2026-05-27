# Spec: Workspace Layout

Status: Draft
Owner: repository
Last reviewed: 2026-05-28

## Purpose

RPM needs explicit ownership boundaries before large behavior changes move code
across CLI parsing, core install behavior, npm registry access, lockfile
handling, and `node_modules` linking.

## Contract

The repository is a Cargo workspace. The first workspace member is the current
root `rpm` package.

The first crate split is deferred. The current codebase remains in one package
until the next split can be done as a mechanical move with no behavior changes.

The intended crate boundaries are:

- `rpm-cli`: owns argument parsing, process exit codes, and user-facing command
  output.
- `rpm-core`: owns package-manager workflows, project filesystem mutation,
  lockfile loading/saving, install recovery, and `node_modules` linking.
- `rpm-npm`: owns npm package metadata interpretation, registry HTTP access,
  tarball cache writes, and npm ecosystem compatibility rules.

Until those crates exist, the current module boundaries are authoritative:

- `src/main.rs`, `src/lib/opt`, and `src/lib/command/mod.rs` are the CLI
  boundary.
- `src/lib/command/working_process`, `src/lib/lockfile`,
  `src/lib/package_manifest`, and `src/lib/node_linker` are the core install
  boundary. The nested `working_process` modules are not owned by the CLI
  boundary despite living under `src/lib/command` today.
- `src/lib/api` and `src/lib/registry` are the npm registry boundary.

Core install logic must remain callable from the library without depending on
CLI argument parsing. Registry/network code must not directly mutate project
filesystem state outside its tarball cache responsibility.

## Error Cases

Workspace layout changes must not change command behavior, lockfile format,
manifest interpretation, registry selection, tarball cache layout, or
`node_modules` layout unless the owning SPEC is updated in the same change.

## Test Fixtures

No fixtures are required for the workspace decision. Build validation must
cover the workspace root.

## Open Questions

- Whether `rpm-core` should own package manifest parsing or delegate it to a
  future ecosystem crate.
- Whether cache storage should live in `rpm-core` or the future `rpm-npm`
  crate.
