# Spec: Installer Performance Baseline

Status: Draft  
Owner: resolver/install  
Last reviewed: 2026-05-27

## Purpose

RPM's current installer is intentionally still a prototype, but the M0 recovery
track needs a stable description of the bottleneck before changing behavior.
This document records where the recursive install flow lives, what future
staging should look like, and which fixture should be used to measure later
changes.

This document does not authorize an installer rewrite. It is the baseline for a
later milestone that can change scheduling, concurrency, deduplication, and
transaction safety with tests.

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
version for every package record, matching `docs/specs/resolver.md`.

## Measurement Fixture

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

## Error Cases

Pipeline work must keep failed graph resolution side-effect free. A missing
package, invalid metadata document, unsatisfied range, failed tarball download,
failed integrity check, failed extraction, failed link, or failed lockfile write
must not be reported as a successful install.

## Open Questions

- Which module owns the first installer measurement harness?
- Should metadata fetch counts be collected through a fake registry API or a
  resolver event log?
- What integrity format is authoritative before tarball verification is
  implemented?
