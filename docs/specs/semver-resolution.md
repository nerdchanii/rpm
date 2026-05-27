# Spec: Semver Resolution

Status: Draft
Owner: resolver/install
Last reviewed: 2026-05-28

## Purpose

RPM must resolve dependency ranges with npm-compatible semver behavior before
installer work depends on selected package versions. The semver contract defines
the M1 baseline and the fixtures that future resolver implementation must pass.

## Contract

M0 does not implement the full resolver. M1 must implement the first supported
semver range baseline before installer behavior depends on range selection.

The M1 baseline supports these request forms:

- exact versions, for example `1.2.3`
- caret ranges, for example `^1.2.3`
- caret ranges for zero-major versions, for example `^0.2.0`
- tilde ranges, for example `~1.2.3`
- wildcard ranges, for example `*`, `1.x`, and `1.2.x`
- common comparator ranges, for example `>=1.0.0 <2.0.0`

For each supported request, the version selector chooses the highest matching
stable version from npm registry metadata. The selected version is recorded in
lockfile `version`; the original request text is preserved in lockfile
`requested`.

Unsatisfied ranges and invalid ranges are resolver failures. They must fail
before tarball download, extraction, linking, lockfile writes, or manifest
writes.

Lockfile v1 already supports this contract by storing both `requested` and
resolved `version` fields for each package record.

## Dependency Decision

The Rust semver/range dependency is explicitly deferred to the M1 resolver
implementation spike. The dependency must be chosen by comparing npm-compatible
range behavior against the fixtures in
`tests/fixtures/install-projects/semver-baseline/`, rather than by matching only
Cargo semver behavior.

A candidate dependency must preserve npm-compatible caret, tilde, wildcard, and
comparator semantics or the implementation must add a compatibility layer around
it. The default should be a Node/npm-compatible Rust range library, not a
Cargo-oriented semver parser, unless fixture results prove compatibility.

## Replacement Targets

Current ad hoc normalization is a replacement target, not the resolver
contract:

- `src/lib/command/working_process/add.rs::registry_request_from_requested`
  strips `^` and `~` and chooses the last disjunct after `||`.
- `src/lib/api/mod.rs::get_registry` strips `^` and `~` and maps `*` to
  `latest` before making a registry request.
- `src/lib/util/mod.rs::parse_library_name` truncates comparator expressions
  such as `>=1.0.0 <2.0.0` before resolver policy can inspect them.
- `src/lib/lockfile/mod.rs::Dependency::get_dependencies_name` extracts names
  with a regex that special-cases caret text.
- `src/lib/registry/mod.rs::Registry::get_latest_version` is only a latest-tag
  helper and must not stand in for highest matching version selection.

These compatibility paths may remain during M0 only to preserve current command
behavior. M1 resolver work must replace them with a single version selection
boundary.

## Error Cases

- An exact version that is absent from metadata fails resolution.
- A range with no matching version fails resolution.
- An invalid range fails resolution.
- Package metadata with no valid versions fails resolution.

All resolver failures must be reported before installer side effects.

## Test Fixtures

The success baseline fixture is
`tests/fixtures/install-projects/semver-baseline/`. It defines direct dependency
requests, offline registry metadata, and expected selected package records for a
project that should resolve completely.

Failing resolver fixtures are separate project scenarios:

- `tests/fixtures/install-projects/semver-unsatisfied/`
- `tests/fixtures/install-projects/semver-invalid-range/`

Required fixture cases:

- exact: `1.2.3` selects `1.2.3`
- caret: `^1.2.3` selects highest `<2.0.0`
- caret zero-major: `^0.2.0` selects highest `<0.3.0`
- tilde: `~1.2.3` selects highest `<1.3.0`
- wildcard any: `*` selects highest available stable version
- wildcard major: `1.x` selects highest `1.*.*`
- wildcard minor: `1.2.x` selects highest `1.2.*`
- comparator: `>=1.0.0 <2.0.0` selects highest matching version
- unsatisfied range returns a resolver error before side effects
- invalid range returns a resolver error before side effects

## Open Questions

- Whether M1 supports npm dist-tags other than `latest`.
- Whether prerelease selection is unsupported or supported only when explicitly
  requested.
