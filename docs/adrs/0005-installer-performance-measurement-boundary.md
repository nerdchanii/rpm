---
adr_id: 0005
title: Keep Installer Measurement Under The Install Boundary
status: accepted
date: 2026-06-18
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_specs:
  - docs/specs/core/install/performance/SPEC.md
  - docs/specs/core/lockfile/SPEC.md
related_issues:
  - 60
---

# ADR 0005: Keep Installer Measurement Under The Install Boundary

Status: Accepted
Date: 2026-06-18

## Context

The installer performance baseline SPEC defines the first shared-transitive
measurement fixture, but issue #60 left three accepted questions unresolved:
who owns the first measurement harness, how metadata fetch counts should be
collected, and which integrity field is authoritative before tarball
verification exists.

Those questions affect installer ownership and future test shape. They should
be resolved once and referenced by the SPEC instead of staying as open
questions in the active contract.

## Decision

The first installer measurement harness is owned by the install domain under
`core`, not by CLI, resolver, registry, or linker modules. When the install
domain is promoted into `src/core/install`, performance measurement helpers
belong under an install-owned performance module or its tests. Until then, the
current fixture remains the shared input and production code should not add a
new permanent harness under legacy command modules.

Metadata fetch and tarball download counts should be collected through a fake
registry API used by installer tests. The fake registry records calls by package
name and selected version while serving deterministic fixture metadata and
tarball responses. Resolver event logs may be added later for diagnostics, but
they are not the first measurement mechanism and should not become required to
prove installer network deduplication.

Before tarball verification is implemented, npm registry `dist.integrity` is
the authoritative integrity source when present. If metadata omits
`dist.integrity`, registry `dist.shasum` is the legacy fallback. Lockfile and
measurement records may preserve both values, but pre-verification tests treat
the metadata value as recorded package fact only; they must not report the
tarball as cryptographically verified.

## Consequences

- Installer performance tests can measure package-manager side effects without
  making resolver diagnostics part of the required contract.
- Resolver graph tests can stay focused on graph output and requested/resolved
  version preservation.
- The registry abstraction used by installer tests needs enough surface to
  serve metadata, tarballs, and call counts deterministically.
- Integrity recording remains aligned with the lockfile SPEC before the later
  tarball verification phase adds cryptographic checks.

## Follow-Up

- Update `docs/specs/core/install/performance/SPEC.md` to reference this ADR
  and remove the resolved open questions.
- Keep future installer harness code under the install-owned core boundary when
  that boundary exists.
- Add tarball verification behavior in a later SPEC or SPEC update before
  claiming downloaded tarballs are integrity-verified.

## Alternatives Considered

- Put the first harness under resolver: rejected because the measurement target
  is installer side effects, including metadata fetches, tarball downloads, and
  writes that happen after graph resolution.
- Use a resolver event log for fetch counts: rejected for the first baseline
  because event logs are diagnostics, while a fake registry API directly
  observes the network/cache calls the installer must dedupe.
- Treat `dist.shasum` as authoritative until verification exists: rejected
  because `dist.integrity` is the stronger npm metadata field and the lockfile
  SPEC already treats `shasum` as legacy fallback data.
