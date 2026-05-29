---
spec_id: semver_resolution
title: Semver Resolution
status: draft
owner: core/semver
last_reviewed: 2026-05-30
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
  - 0003-own-npm-compatible-semver
related_issues:
  - 42
  - 50
  - 59
---

# Spec: Semver Resolution

Status: Draft
Owner: core/semver
Last reviewed: 2026-05-30

## Purpose

RPM must resolve dependency ranges with npm-compatible semver behavior before
installer work depends on selected package versions. The semver contract defines
the compatibility target, resolver-facing behavior, and fixtures that future
resolver implementation must pass.

## Contract

#42 must implement npm-compatible semver with full `node-semver` compatibility
as the target. Compatibility includes observable range and version behavior and
the public `node-semver` API surface. RPM must not define a permanent
RPM-specific semver dialect.

The semver implementation may land with fixtures grouped by behavior area, but
accepted #42 behavior must be measured against `node-semver` semantics for
versions, comparators, ranges, wildcard and x-ranges, hyphen ranges, tilde,
caret, range unions, prerelease handling, build metadata ordering, and invalid
input handling.

Accepted #42 API work must track the public `node-semver` operations. Rust
internals may use Rust naming conventions and typed `Result` or `Option`
returns, but the core must preserve enough operation shape to expose compatible
Rust, WASM, or npm wrappers without redefining behavior.

The M1 installer path depends on at least the following request forms:

- exact versions, for example `1.2.3`
- caret ranges, for example `^1.2.3`
- caret ranges for zero-major versions, for example `^0.2.0`
- tilde ranges, for example `~1.2.3`
- wildcard ranges, for example `*`, `1.x`, and `1.2.x`
- common comparator ranges, for example `>=1.0.0 <2.0.0`

For each supported request, the version selector chooses the highest matching
version from npm registry metadata according to `node-semver` range semantics.
The selected version is recorded in lockfile `version`; the original request
text is preserved in lockfile `requested`.

Unsatisfied ranges and invalid ranges are resolver failures. They must fail
before tarball download, extraction, linking, lockfile writes, or manifest
writes.

The lockfile contract already supports this baseline by storing both
`requested` and resolved `version` fields for each package record.

## Dependency Decision

ADR 0003 decides that RPM owns its npm-compatible semver implementation inside
`core`. The long-lived behavior source of truth is this SPEC plus
`node-semver` compatibility fixtures, not an external Rust semver crate.

Semver remains inside the current single Cargo package while the compatibility
boundary is implemented. Extracting and publishing a separate crate is deferred
until after the in-repo implementation is stable and covered by compatibility
fixtures.

External crates may be used as comparison tools or temporary implementation
aids only when tests prove they match the active `node-semver` compatibility
contract.

If RPM copies or derives code, tests, or fixtures from `node-semver`, the
repository must preserve the required ISC license notice.

Copied or derived `node-semver` fixtures are allowed for #42 when they are kept
with clear provenance and the required ISC notice. Runtime semver code should
not be a mandatory line-by-line port: it may use a Rust-native parser,
intermediate representation, cache strategy, or selection algorithm when the
compatibility fixtures prove the same observable behavior.

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

These compatibility paths may remain only until the active M1 resolver work
replaces them with a single version selection boundary.

## API Safety

Production semver code must not panic on user-controlled version or range
input. Parsing, comparison, satisfaction, and selection APIs must report invalid
input, unsupported syntax, and unsatisfied ranges through typed errors or
explicit non-match results.

Do not add `panic!`, `unwrap`, or `expect` in production semver code except for
compile-time constants or impossible internal invariants documented with a short
comment. Tests may use them.

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

#42 must add or adapt additional fixtures that cover the full `node-semver`
compatibility target. Fixture groups may be split by behavior area so failures
remain readable.

Imported or derived `node-semver` fixture groups must be clearly separated from
RPM-authored fixtures and must preserve the required ISC notice.

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

- Whether M1 supports npm dist-tags other than `latest`. Tracked by #59.
