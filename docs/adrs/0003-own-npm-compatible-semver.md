---
adr_id: 0003
title: Own npm-Compatible Semver Resolution
status: accepted
date: 2026-05-30
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_specs:
  - docs/specs/core/semver/SPEC.md
related_issues:
  - 42
---

# ADR 0003: Own npm-Compatible Semver Resolution

Status: Accepted
Date: 2026-05-30

## Context

RPM is a Node/npm package manager, and semver resolution is part of the package
manager trust boundary. The resolver must interpret npm registry metadata and
package dependency ranges the same way npm users expect.

Rust has existing semver crates, including crates that target npm-compatible
range behavior. Depending on an external crate would reduce initial
implementation work, but semver compatibility is central enough that stale or
Cargo-oriented behavior would directly affect selected package versions,
lockfiles, and install reproducibility.

The canonical behavior target for RPM is npm's `node-semver` package.
`node-semver` is ISC licensed, and its behavior, fixtures, and compatibility
surface can be used as the reference for RPM's own implementation.

## Decision

RPM will own its npm-compatible semver implementation inside `core`.

The compatibility target is full `node-semver` range and version behavior, not a
small permanent subset. The implementation may land in stages, but accepted
semver work must move toward `node-semver` compatibility instead of defining an
RPM-specific range dialect.

This decision does not split semver into a separate Cargo crate yet. ADR 0002's
single-crate `cli/core` boundary remains active: RPM should first implement and
stabilize semver behavior inside `core`, then decide any crate extraction and
publication in a later ADR after the compatibility boundary is proven.

RPM may adapt behavior, fixtures, and implementation ideas from `node-semver`
when useful. Any copied or derived ISC-licensed material must preserve the
required license notice in the repository.

RPM will not make an external Rust semver crate the long-lived source of truth
for npm range behavior. External crates may still be used as temporary
comparison tools or implementation aids when tests prove they match the active
SPEC.

## Consequences

- Semver behavior is a core package-manager contract owned by RPM.
- Version selection tests should compare RPM behavior against `node-semver`
  semantics and fixtures.
- M1 semver work should not stop at an intentionally weak range subset when the
  issue scope calls for full compatibility.
- Publishing semver as a separate crate is deferred until after the in-repo
  implementation is complete and stable enough to extract cleanly.
- The resolver should call a single semver selection boundary instead of
  duplicating range parsing in registry, lockfile, or CLI paths.
- Maintaining this code becomes RPM's responsibility, including future
  compatibility fixes when npm behavior changes.

## Follow-Up

- Update `docs/specs/core/semver/SPEC.md` to make full `node-semver`
  compatibility the #42 contract.
- Implement the semver module and replacement selector behind the resolver
  boundary.
- Preserve ISC notices for any copied or derived `node-semver` material.
- Revisit crate extraction and publication only after the internal semver
  boundary is implemented and covered by compatibility fixtures.

## Alternatives Considered

- Use an existing Rust npm semver crate: rejected as the long-lived source of
  truth because stale or incomplete npm semantics would affect package
  selection and lockfile reproducibility.
- Use Cargo's `semver` crate directly: rejected because Cargo range behavior is
  not the npm package-manager contract.
- Keep a permanent M1-only subset: rejected because RPM's package-manager
  boundary requires npm-compatible behavior rather than an RPM-specific semver
  dialect.
- Publish a separate semver crate immediately: rejected for the current stage
  because it would undermine ADR 0002's single-crate boundary before RPM has a
  stable extraction point.
