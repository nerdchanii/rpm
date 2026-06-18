---
adr_id: 0006
title: Keep Resolver Strategy Ownership In Core Resolver
status: accepted
date: 2026-06-18
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_specs:
  - docs/specs/core/resolver/SPEC.md
related_issues:
  - 58
---

# ADR 0006: Keep Resolver Strategy Ownership In Core Resolver

Status: Accepted
Date: 2026-06-18

## Context

The first resolver boundary SPEC accepted a replaceable traversal strategy, but
left three M1 follow-up questions unresolved: which Rust module owns the first
strategy type, how peer dependencies are represented before a peer-aware
strategy exists, and whether graph conflicts need structured diagnostics before
M1.

These decisions need a stable tracked artifact so resolver implementation can
proceed without making reviewers infer ownership or pre-M1 behavior from issue
discussion.

## Decision

The `src/core/resolver` root owns the first `ResolutionStrategy` trait or
equivalent internal abstraction.

Concrete strategy implementations may live in private child modules under
`src/core/resolver`, but callers should depend on the resolver root facade
rather than importing concrete traversal modules. Semver behavior remains owned
by `src/core/resolver/semver` and is called through its facade; traversal
strategies must not absorb semver range parsing or selection policy.

Before RPM has a peer-aware strategy, peer dependencies are represented as peer
requirement metadata on resolved package records or metadata records. They are
not direct dependency requests, transitive dependency requests, manifest update
inputs, or `node_modules` link targets by themselves. A non-peer-aware strategy
must not silently enqueue peer dependencies as ordinary dependencies.

M1 does not require public structured diagnostics for graph conflicts. Resolver
failures must still be typed internally enough for callers to distinguish
missing metadata, invalid metadata, unsatisfied ranges, invalid ranges, and
unsupported graph conditions, and they must remain side-effect free. A public
machine-readable diagnostic format for graph conflicts is deferred until RPM
has a diagnostics contract that covers CLI presentation and future API output.

## Consequences

- Resolver ownership stays aligned with ADR 0002's single-crate `cli/core`
  boundary.
- The first strategy can be implemented without creating a separate resolver
  crate, workspace package, or CLI-owned traversal type.
- Peer dependency data may be preserved without pretending the M1 resolver is
  peer-aware.
- Implementations that need peer-aware behavior later can add strategy support
  without reclassifying peer dependencies as ordinary transitive edges.
- M1 conflict errors can remain focused on side-effect-free failure instead of
  freezing a public diagnostic schema too early.

## Follow-Up

- Keep `docs/specs/core/resolver/SPEC.md` as the resolver contract and link it
  to this ADR for the resolved #58 boundary decisions.
- When peer-aware resolution is implemented, update the resolver SPEC with the
  active peer conflict and placement contract.
- When public structured diagnostics are introduced, add or update the owning
  diagnostics SPEC before exposing a machine-readable graph-conflict format.

## Alternatives Considered

- Put `ResolutionStrategy` in a separate resolver crate now: rejected because
  ADR 0002 keeps RPM as a single Cargo package until extension or packaging
  needs are concrete.
- Let each strategy module define its own public trait: rejected because it
  would make concrete traversal layout part of the repository-wide API.
- Treat peer dependencies as ordinary transitive dependencies until peer-aware
  resolution exists: rejected because it would encode incorrect npm dependency
  semantics into the first graph contract.
- Require public structured graph-conflict diagnostics before M1: rejected
  because the diagnostics schema is broader than the first resolver boundary
  and should not be frozen by this issue alone.
