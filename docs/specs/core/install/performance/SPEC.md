---
spec_id: installer_performance
title: Installer Performance Baseline
status: draft
owner: core/install/performance
last_reviewed: 2026-06-22
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
  - 0005-installer-performance-measurement-boundary
related_issues:
  - 50
  - 60
  - 83
  - 89
---

# Spec: Installer Performance Baseline

Status: Draft
Owner: core/install/performance
Last reviewed: 2026-06-22

## Purpose

RPM's current installer is intentionally still a prototype, but the active M1
track needs a stable description of the bottleneck before changing behavior.
This document records where the recursive install flow lives, what future
staging should look like, and which fixture should be used to measure staged
changes.

This document does not authorize an installer rewrite by itself. It is the
baseline for staged M1 work and later milestones that can change scheduling,
concurrency, deduplication, and transaction safety with tests.

## Current Bottleneck

`src/lib/command/working_process/install.rs` seeds the install from the root
manifest. It reads `./package.json`, loads `rpm.lock`, converts dependencies and
devDependencies to `name@range` strings, calls `working_process::add` for each
set, then saves the lockfile and manifest after both calls return.

`src/lib/command/working_process/add.rs` owns the recursive traversal. For each
requested package it currently:

1. Parses the package request string.
2. Fetches registry metadata with `api::get_registry`.
3. Selects `latest` for empty or wildcard requests.
4. Downloads the selected tarball.
5. Reads that package's dependency list from registry metadata.
6. Mutates the lockfile.
7. Optionally mutates the root manifest for direct dependencies.
8. Calls `add` recursively for transitive dependencies.

That combines graph traversal, metadata fetch, version selection, tarball
download, lockfile mutation, manifest mutation, and recursive scheduling in one
depth-first operation. The result is difficult to deduplicate or retry because a
package/version node can be encountered only as a side effect of walking the
current branch. It is also difficult to make transactional because installer
state is mutated before the full graph is known.

`src/lib/registry/mod.rs` is part of the same bottleneck. `Registry::get_tarball_url`
and `Registry::get_dependencies` choose data from the current registry response,
while `Registry::download_tarball` fetches bytes and persists them to the RPM
cache during traversal. Later pipeline work should keep metadata reads separate
from tarball download and cache writes.

## Future Pipeline

Later installer work should stage installation in this order:

1. Read the project manifest from an explicit project root.
2. Resolve the dependency graph from package metadata.
3. Dedupe package/version nodes before network downloads.
4. Fetch any remaining metadata needed by the graph.
5. Download tarballs for the deduped graph.
6. Verify integrity before extraction.
7. Extract packages into a staging area.
8. Link `node_modules` from the staged package set.
9. Write `rpm.lock` and `package.json` only after install state is ready.

The graph resolution stage must preserve both the requested range and selected
version for every package record, matching `docs/specs/core/resolver/SPEC.md`.

## Test Fixtures

Use `tests/fixtures/install-projects/performance-small/` as the first
measurement fixture. It intentionally includes two direct dependencies that
share one transitive dependency so later implementation can prove graph
deduplication before adding concurrency.

Measurement runs should copy the fixture to a temporary directory before
mutation. A measurement must record:

- number of metadata fetches by package name and selected version
- number of tarball downloads by package name and selected version
- resolved package/version list
- whether `rpm.lock`, `package.json`, `.rpm`, or `node_modules` were written
  before the graph was fully resolved

The initial success criterion for later implementation is not raw speed. The
first criterion is that shared transitive packages are represented once in the
resolved graph and downloaded once for a selected version.

## Measurement Decisions

ADR 0005 resolves the installer measurement ownership and pre-verification data
sources for this baseline.

The first measurement harness belongs to the install domain under `core`. It
should not be owned by CLI, resolver, registry, linker, or legacy command
modules. When `src/core/install` exists, install performance helpers should
live under an install-owned performance module or its tests.

Metadata fetch counts and tarball download counts should be collected through a
fake registry API used by installer tests. The fake registry should serve
deterministic fixture metadata and tarball responses while recording calls by
package name and selected version. Resolver event logs may be added later for
diagnostics, but they are not required for the first installer measurement
harness.

## Integrity Gate

RPM verifies tarball bytes after download/cache publication and before
extraction when supported integrity metadata is available. Registry
`dist.integrity` is authoritative when present. Registry `dist.shasum` is the
legacy fallback when `dist.integrity` is absent.

The supported Subresource Integrity algorithm is `sha512`. If an SRI value
contains multiple whitespace-separated tokens, RPM may select any matching
`sha512` token. If `dist.integrity` is absent, RPM verifies `dist.shasum` as a
hex-encoded SHA-1 digest. If both `dist.integrity` and `dist.shasum` are absent,
RPM may proceed without verification but must not claim that the tarball was
verified.

Verification applies to tarballs downloaded from current registry metadata and
to lockfile-backed tarball URLs. A verification failure must be returned as a
failed integrity phase and must not publish extracted package contents,
`rpm.lock`, or `package.json` as a successful install output.

## Error Cases

Pipeline work must keep failed graph resolution side-effect free. A missing
package, invalid metadata document, unsatisfied range, failed tarball download,
failed integrity check, failed extraction, failed link, or failed lockfile write
must not be reported as a successful install.
