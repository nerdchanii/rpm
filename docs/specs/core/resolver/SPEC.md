---
spec_id: resolver_boundary
title: Resolver Strategy Boundary
status: draft
owner: core/resolver
last_reviewed: 2026-06-18
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
  - 0006-resolver-strategy-boundary
related_issues:
  - 50
  - 58
---

# Spec: Resolver Strategy Boundary

Status: Draft
Owner: core/resolver
Last reviewed: 2026-06-18

## Purpose

RPM resolves dependency requests before it fetches tarballs, extracts packages,
links `node_modules`, or writes `rpm.lock` and `package.json`. The resolver
boundary defines the internal contract for that phase so the first traversal
implementation can stay simple without becoming the long-term installer shape.

## Contract

The resolver consumes dependency requests and package metadata through explicit
abstractions. A dependency request includes the package name, the requested
range or version text, and a request kind. Request kinds distinguish direct
production dependencies, direct development dependencies, and transitive
dependencies discovered from package metadata. Only direct request kinds may
drive manifest dependency updates; transitive requests are graph inputs and must
not be treated as root manifest entries. Package metadata access supplies
available versions, dist metadata, and dependency declarations without
downloading or extracting tarballs as part of traversal.

The resolver produces a resolved dependency graph. Each resolved package record
preserves both the requested range and the selected version. The graph is the
input to later installer phases that download tarballs, verify integrity,
extract packages, link `node_modules`, and write lockfile or manifest state.

Version and range satisfaction rules are owned by
`docs/specs/core/semver/SPEC.md`. Resolver strategies call the version
selection abstraction and record its selected version; they must not duplicate
range parsing policy in the traversal implementation.

Traversal policy is behind a replaceable `ResolutionStrategy` boundary, or an
equivalent internal abstraction, owned by the `src/core/resolver` root module.
Concrete strategies may live in private child modules, but callers depend on
the resolver facade rather than a concrete queue or worklist type. The resolver
must not rely on recursive calls for correctness.

The first strategy is an iterative FIFO worklist:

1. Seed the worklist with direct dependency requests.
2. Pop the oldest pending request.
3. Read package metadata through the metadata abstraction.
4. Select a version through the version selection abstraction.
5. Add or merge the resolved package into the graph.
6. Enqueue that package's dependency requests as transitive requests.
7. Continue until the worklist is empty or resolution fails.

Future strategies may replace FIFO traversal with priority-based, heuristic,
peer-aware, or backtracking behavior without changing fetch, extract, link, or
lockfile write phases.

Before a peer-aware strategy exists, peer dependencies are represented as peer
requirement metadata on resolved package records or metadata records. They are
not direct dependency requests, transitive dependency requests, manifest update
inputs, or `node_modules` link targets by themselves. A non-peer-aware strategy
must not silently enqueue peer dependencies as ordinary dependencies.

The installer performance baseline in
`docs/specs/core/install/performance/SPEC.md`
documents the current recursive bottleneck and the measurement fixture for
future staged installer work.

## Error Cases

Resolution fails before installer side effects when package metadata is missing,
a requested range cannot be satisfied, dependency metadata is invalid, or the
strategy detects an unsupported graph condition. Failed resolution must not be
reported as a successful install, and it must not cause partial lockfile or
manifest writes.

M1 does not require a public structured diagnostic format for graph conflicts.
Resolver failures must still be typed internally enough for callers to
distinguish missing metadata, invalid metadata, unsatisfied ranges, invalid
ranges, and unsupported graph conditions. A public machine-readable diagnostic
format must be covered by an owning diagnostics SPEC before it becomes part of
RPM's user-facing or API-facing contract.

## Test Fixtures

Resolver tests should use offline registry metadata fixtures. Each fixture
should represent one graph scenario and include expected resolved package
records with requested range and selected version. Integration fixtures may add
expected lockfile snapshots or filesystem trees for later installer phases, but
resolver fixtures should not mutate the repository root, `.rpm`, `rpm.lock`, or
`node_modules`.

The semver baseline fixtures are defined by
`docs/specs/core/semver/SPEC.md` and must be used before installer flow relies
on semver range behavior.

## Resolved Follow-Up

ADR 0006 records the resolved #58 boundary decisions for
`ResolutionStrategy` ownership, pre-peer-aware dependency representation, and
M1 graph-conflict diagnostics.
