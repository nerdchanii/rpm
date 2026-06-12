---
adr_id: 0004
title: Keep Semver Standalone-Ready Behind A Facade
status: accepted
date: 2026-06-03
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
  - 67
  - 68
---

# ADR 0004: Keep Semver Standalone-Ready Behind A Facade

Status: Accepted
Date: 2026-06-03

## Context

ADR 0002 keeps RPM as a single Cargo package for now. ADR 0003 keeps
npm-compatible semver owned by RPM until the in-repo implementation is stable
and covered by compatibility fixtures.

Even without extracting a crate now, semver needs a clean boundary so future
crate extraction is a mechanical packaging step instead of a late architecture
rewrite.

## Decision

RPM will manage `src/core/resolver/semver/mod.rs` like the future semver
crate's `lib.rs`.

The semver root module owns the facade. Non-semver RPM code should call semver
through that facade instead of importing implementation modules.

The internal shape is:

- `version/` owns typed version behavior and internals.
- `range/` owns typed range behavior and internals.
- `ops/` implements compatibility convenience operations and is not a consumer
  access path.

Public convenience operations that are part of the supported semver surface are
re-exported through the root facade. Implementation modules may remain visible
inside the semver domain as needed, but they should not become repository-wide
access points.

API documentation for semver belongs in Rust rustdoc on the public Rust API.
Area READMEs may index those docs, but SPECs remain behavior contracts rather
than API documentation checklists.

## Consequences

- Future semver crate extraction should not require changing RPM resolver or
  registry call sites.
- Root facade re-exports should be explicit enough to show the supported
  surface.
- `ops` can keep compatibility-shaped implementation names without becoming a
  stable import path.
- SPECs should describe observable semver behavior and resolver-facing
  contracts, not implementation module layout.
- API documentation work should happen in rustdoc comments and be checked as
  part of standalone-readiness work.

## Follow-Up

- Keep `docs/specs/core/semver/SPEC.md` focused on behavior contracts.
- Keep `docs/specs/core/semver/README.md` as the semver documentation index.
- Add or refine rustdoc when public semver API surface changes.

## Alternatives Considered

- Extract semver as a separate Cargo crate now: rejected by ADR 0002 and ADR
  0003 because the in-repo boundary is not stable enough yet.
- Let consumers import `semver::ops` directly: rejected because it would make
  implementation structure part of the repository-wide API.
- Put API documentation requirements in SPEC: rejected because SPECs define
  behavior contracts, while Rust API documentation belongs in rustdoc.
