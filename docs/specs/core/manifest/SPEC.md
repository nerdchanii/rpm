---
spec_id: package_manifest
title: Package Manifest
status: draft
owner: core/manifest
last_reviewed: 2026-08-10
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
  - 127
---

# Spec: Package Manifest

Status: Draft
Owner: core/manifest
Last reviewed: 2026-08-10

## Purpose

`package.json` is the project manifest contract for root dependencies, dev
dependencies, scripts, and project metadata used by install and add flows.

## Contract

An absent manifest is treated as an empty manifest so commands can initialize a
new project state.

A present manifest must be valid JSON matching RPM's supported manifest shape.
Package manifest parsing errors must be returned to callers with the manifest
path and parser context. Core package-manager code must not panic on invalid
manifest content.

Saving writes the complete current manifest and truncates old content. Save
errors must be returned to callers with the manifest path.

The full npm `package.json` schema is intentionally out of scope for this
contract today.

### Optional dependencies

RPM reads and preserves the root `optionalDependencies` map (`package name` to
`range`) when it is present. Preserved entries are not consumed by install, add,
or resolution today: they are not enqueued as dependency requests, they do not
influence version selection, and they do not appear in the resolved graph,
lockfile, or linked `node_modules`. A manifest that omits
`optionalDependencies` behaves identically to one without it.

This read-and-preserve baseline makes RPM honest about a field it accepts today.
The full optional-aware behavior (resolve the entry as an ordinary dependency,
attempt install, skip on failure, and report the outcome) is intentionally
deferred until an optional-aware strategy SPEC owns it. Until then, a
non-optional-aware strategy must not silently enqueue optional dependencies as
ordinary dependencies; that non-enqueue guard is owned by
`docs/specs/core/resolver/SPEC.md`. Per-version
`optionalDependencies` on registry packuments remain ignored at the registry
boundary (`docs/specs/core/registry/SPEC.md`).

### Engines, OS, and CPU metadata

RPM reads and preserves the root `engines`, `os`, and `cpu` fields when they
are present, using npm-accurate types (`engines` as a `name -> range` map;
`os` and `cpu` as arrays whose entries may be negated, for example `!win32`).
Preserved values are not consumed by install, add, or resolution today: RPM
performs no engine, OS, or CPU filtering, warning, skip, or failure. They do
not influence version selection, the resolved graph, the lockfile, or linked
`node_modules`. A manifest that omits any of these fields behaves identically to
one without it.

This read-and-preserve baseline makes RPM honest about fields it accepts today
and keeps a real npm-shaped manifest from failing parsing. The full
platform-gating behavior (filter candidates, warn on mismatch, skip install, or
fail) is intentionally deferred until a platform-gating strategy SPEC owns it.
Until then, a non-platform-aware strategy must treat platform incompatibility as
a non-failure: platform metadata must not block resolution, download,
verification, extraction, linking, lockfile, or manifest output. Per-version
`engines`, `os`, and `cpu` on registry packuments remain ignored at the registry
boundary (`docs/specs/core/registry/SPEC.md`).

## Error Cases

Invalid JSON is an input error and must not be reported as a successful command.
File write, create, and serialization failures must not be hidden behind
panics.

## Test Fixtures

Manifest fixtures live under `tests/fixtures/package_manifest/`.
