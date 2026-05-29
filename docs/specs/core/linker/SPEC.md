---
spec_id: node_modules_linker
title: Node Modules Linker
status: draft
owner: core/linker
last_reviewed: 2026-05-29
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
related_issues:
  - 50
---

# Spec: Node Modules Linker

Status: Draft
Owner: core/linker
Last reviewed: 2026-05-29

## Purpose

RPM links an extracted package set into a `node_modules` filesystem layout after
dependency resolution and package extraction. The linker contract defines the
shape that package-local dependency links must create so runtime resolution sees
only the dependencies declared by each package.

## Contract

For each resolved package, RPM creates dependency links under that package's own
`node_modules` directory. A dependency link target is calculated from the actual
dependency package name, not from the parent package being linked.

For example, if package `a` declares dependency `b`, the linker creates:

```text
node_modules/a/node_modules/b -> node_modules/b
```

Scoped package names keep their scope directory. If package `a` declares
`@scope/b`, the linker creates:

```text
node_modules/a/node_modules/@scope/b -> node_modules/@scope/b
```

Filesystem operations are part of the contract. Directory creation and symlink
creation failures must be returned as errors rather than ignored.

Strict dependency visibility remains a design constraint: package-local
`node_modules` entries should expose declared dependencies, not unrelated
packages from the root package set.

## Out Of Scope

`.bin` generation is not defined by this contract. It should be specified and
implemented separately.

## Error Cases

Linking fails if a dependency target package has not been extracted, if the
destination directory cannot be created, or if the symlink cannot be created.
Failed linking must not be reported as a successful install or script setup.

## Test Fixtures

Linker verification should cover unscoped and scoped dependency links plus
destination-directory and symlink-creation failures.

## Open Questions

None currently.
