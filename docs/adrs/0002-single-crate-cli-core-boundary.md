---
adr_id: 0002
title: Use A Single-Crate `cli/core` Boundary Before Any Workspace Split
status: accepted
date: 2026-05-29
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
---

# ADR 0002: Use A Single-Crate `cli/core` Boundary Before Any Workspace Split

Status: Accepted
Date: 2026-05-29

## Context

RPM needs clearer ownership boundaries before semver, resolver, and installer
work grows further. Earlier planning discussed a future Cargo workspace split
and a possible `rpm-npm` boundary.

That shape is too heavy for the current stage:

- semver and resolver work needs faster iteration, not packaging overhead
- npm registry interpretation is part of the core package-manager contract
- Cargo workspace management would add structure before extension points exist

At the same time, the codebase still needs a hard boundary between command-line
behavior and package-manager behavior.

## Decision

RPM stays a single Cargo package for now.

The initial code boundary is:

- `src/cli`
- `src/core`

`cli` owns:

- argument parsing
- command dispatch
- terminal presentation
- exit-code mapping

`core` owns:

- manifest handling
- resolver and semver policy
- registry metadata interpretation and network access
- lockfile loading and saving
- install staging and recovery
- linker behavior
- script execution contracts

`core -> cli` dependencies are forbidden.

`cli -> core` dependencies are allowed.

There is no separate `rpm-npm` boundary at this stage. npm registry handling
and npm-compatible semver behavior belong to `core` because they define RPM's
actual package-manager contract.

Cargo workspace or multi-crate splitting is deferred until RPM has concrete
extension or independent packaging needs.

## Proposed Initial Layout

This layout is a boundary target, not a full file-by-file migration plan:

```text
src/
  main.rs
  cli/
  core/
    manifest/
    resolver/
      semver/
    registry/
    lockfile/
    install/
    linker/
    error/
```

Exact submodule names may change, but the ownership boundary should remain the
same.

## Consequences

- Refactors should move logic toward `src/cli` and `src/core` even before any
  future crate split.
- Semver lives under `core::resolver`, not as a CLI concern and not as a
  separate npm crate boundary.
- Resolver output should remain callable without CLI parsing or terminal I/O.
- Future Cargo workspace promotion should be a mechanical packaging step on top
  of already-stable boundaries, not the mechanism used to discover them.

## Follow-Up

- Align workspace-layout SPEC with this boundary.
- Reorder M1 work so semver and resolver boundaries land before end-to-end
  installer expansion.
