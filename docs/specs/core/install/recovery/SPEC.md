---
spec_id: install_recovery
title: Install Recovery
status: draft
owner: core/install/recovery
last_reviewed: 2026-06-22
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
  - 79
---

# Spec: Install Recovery

Status: Draft
Owner: core/install/recovery
Last reviewed: 2026-06-22

## Purpose

RPM must not destroy a working project while preparing replacement install
output. Recovery behavior defines when `node_modules` can be replaced and how
failures are reported to callers.

## Contract

Install output replacement is staged. RPM builds replacement `node_modules`
content in a temporary sibling directory first, while the existing
`node_modules` remains in place.

RPM replaces the existing directory only after extraction and linking both
complete successfully. If replacement itself fails, RPM attempts to restore the
previous directory before returning the write failure.

Failures must include the failed phase in the returned error message for cached
package installation. This contract currently enforces `resolve`, `extract`,
`link`, and `write` labels for cached package installation. Registry fetch and
cache-write failures must be returned to callers instead of being ignored or
reported as successful downloads.

## Error Cases

A failed resolve, fetch, extract, or link phase must leave the previous
`node_modules` directory untouched. A failed write phase must not be reported as
a successful install.

## M3 Side-Effect Audit

The 2026-06-22 M3 audit classifies current installer side effects against this
recovery contract and the related cache, lockfile, manifest, linker, resolver,
and performance SPECs.

| Phase | Code path | State touched | Current tests | SPEC status | Follow-up |
| --- | --- | --- | --- | --- | --- |
| read manifest | `install_in` calls `PackageManifest::read_from_path` before later phases | `package.json` read only | manifest parser tests and install fixture copy tests | conforms | none |
| resolve graph | `add_with_cache_dir` populates metadata and calls `resolve_dependency_graph` before output writes | in-memory graph, lockfile, and manifest state | resolver and install fixture tests | conforms | none |
| fetch/cache | `Registry::download_tarball*_to_dir` writes tarballs through staged cache publication | `.rpm/.cache` | registry cache write tests and install cache fixture assertions | conforms | none after #82 |
| extract | `NodeModules::init_from_lockfile` builds a staged `node_modules` tree with `NodeResolver::resolve_deps` | temporary sibling staging directory | linker extract-failure recovery tests | conforms | #81 may add broader phase-boundary fixtures |
| link | `NodeModules::linking` creates package-local dependency links inside staging | temporary sibling staging directory | linker missing-target recovery tests | conforms | #81 may add broader phase-boundary fixtures |
| write lockfile | `install_in` backs up install state, writes `rpm.lock`, and restores on later failure | `rpm.lock` and sibling backup | lockfile save tests and output-failure install fixture | conforms | none after #80 |
| write manifest | `install_in` backs up install state, writes `package.json`, and restores on later failure | `package.json` and sibling backup | manifest save tests, read-only manifest test, and output-failure install fixture | conforms | none after #80 |
| replace output | `replace_node_modules` renames staged output into place and restores a backup on write failure | `node_modules` and sibling backup | staged replacement success plus extract/link failure recovery tests | conforms | #81 may add a direct replacement-failure fixture |
| integrity gate | installer records `dist.integrity` or `dist.shasum`; it does not verify tarballs before extraction | lockfile metadata only | lockfile and registry metadata fixture tests | conforms | #83 owns the verification gate |

## Test Fixtures

Recovery verification should cover staged replacement success plus resolve,
extract, link, and write failures that leave the previous `node_modules`
contents intact.
