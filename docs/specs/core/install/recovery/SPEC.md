---
spec_id: install_recovery
title: Install Recovery
status: draft
owner: core/install/recovery
last_reviewed: 2026-08-11
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
  - 81
  - 141
  - 142
---

# Spec: Install Recovery

Status: Draft
Owner: core/install/recovery
Last reviewed: 2026-08-11

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
package installation. This contract enforces `resolve`, `fetch`, `extract`,
`link`, `scripts`, and `write` labels for cached package installation. The
`scripts` phase runs between `link` and `write` and is owned by
`docs/specs/core/install/scripts/SPEC.md` (#141); `preinstall` execution landed
via #142, while later hooks remain deferred. Registry fetch and cache-write
failures must be returned to callers instead of being ignored or reported as
successful downloads.

## Error Cases

A failed resolve, fetch, extract, or link phase must leave the previous
`node_modules` directory untouched. A failed write phase must not be reported as
a successful install.

A failed `scripts` phase must leave the previous `node_modules` directory
untouched, must not write or rewrite `rpm.lock` or `package.json` (those writes
belong to the `write` phase, which has not run), and must not be reported as a
successful install. Because the `scripts` phase runs between `link` and
`write`, a lifecycle hook failure occurs while the staged replacement has been
linked but not yet renamed into place; the staged tree is discarded, so the
published install never reflects a partial lifecycle run. This invariant is
owned jointly with `docs/specs/core/install/scripts/SPEC.md` (#141).

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
| integrity gate | installer records `dist.integrity` or `dist.shasum` and verifies supported metadata before extraction | lockfile metadata and cached tarball bytes | lockfile, registry metadata, and integrity failure fixture tests | conforms | none after #89 |

## M4 Side-Effect Audit

The 2026-08-07 M4 audit re-checks installer phase side effects after the M4
measurement and deduplication work (#92 contract and gap audit, #94 graph dedup
proof, #103 tarball download counter, #93 metadata-read counter landed via
#106). M4 adds no
production install behavior: all measurement instrumentation is `#[cfg(test)]`-only
recording inside the fake registry API, and the deduplication proofs exercise
behavior the resolver already had. The audit confirms M3 recovery guarantees are
not weakened and classifies each phase against its owning SPEC.

| Phase | Owning SPEC(s) | M4 change | Side-effect status | Current tests | Verdict |
| --- | --- | --- | --- | --- | --- |
| read manifest | manifest | none | `package.json` read only | manifest parser tests and install fixture copy tests | conforms |
| resolve graph | resolver, lockfile | none (dedup proven, not added) | in-memory graph; no output writes before resolution | resolver tests; #94 graph proof (`graph.packages().len() == 3`); #103 download proof | conforms |
| fetch/cache | cache, performance | measurement only (`#[cfg(test)]` counters) | `.rpm/.cache` staged write plus rename; metadata reads side-effect free | registry cache tests; #103 tarball download counter; #93 metadata-read counter (landed via #106) | conforms |
| verify (integrity) | performance | none | lockfile metadata and cached tarball bytes; failure blocks extraction | lockfile, registry metadata, and integrity failure fixture tests | conforms |
| extract | recovery, linker | none | temporary sibling staging directory | linker extract-failure recovery tests | conforms |
| link | recovery, linker | none | temporary sibling staging directory | linker missing-target recovery tests | conforms |
| write lockfile | lockfile, recovery | none | `rpm.lock` and sibling backup; restore on later failure | lockfile save tests and output-failure install fixture | conforms |
| write manifest | manifest, recovery | none | `package.json` and sibling backup; restore on later failure | manifest save tests, read-only manifest test, output-failure install fixture | conforms |
| replace output | recovery | none | rename staged output into place; backup restore on write failure | staged replacement success and extract/link failure recovery tests | conforms |

Findings:

- M4 introduces no production side effects. The tarball download counter (#103) is
  `#[cfg(test)]`-only and records inside the `RPM_REGISTRY_FIXTURE_ROOT`-gated
  branch of `get_tarball`; production downloads never reach it. The metadata-read
  counter (#93, landed via #106) records inside the corresponding branch of
  `get_registry` and is likewise test-only.
- Failed graph resolution stays side-effect free: `populate_metadata` writes only
  to in-memory `InstallMetadata`, and `resolve_dependency_graph` runs before
  `apply_resolved_graph` touches the lockfile, manifest, cache, or `node_modules`.
- Failed fetch, verify, extract, link, or write phases are not reported as
  successful installs; each maps to a labeled phase error returned to the caller,
  matching the recovery contract above.
- Graph node uniqueness is to be stated in `resolver/SPEC.md` (with an M4 gap-audit
  section in `docs/specs/core/README.md`) by #105; the dedup proofs (#94, #103)
  already confirm the resolved graph and cache represent a selected package/version
  once, consistent with the cache SPEC's version-keyed filename.
- No phase is stale, no contract is changed by M4, and no phase lacks SPEC
  ownership. No new follow-up issue is required from this audit.

## M6 Lifecycle Phase Audit

The 2026-08-11 M6 audit adds the `scripts` phase to the recovery pipeline
between `link` and `write`, so lifecycle hook execution has a contracted home.
The phase label and its position are part of this recovery contract; the
active execution is owned by `docs/specs/core/install/scripts/SPEC.md` (#141),
and the `preinstall` hook landed via #142.

| Phase | Owning SPEC(s) | M6 change | Side-effect status | Current tests | Verdict |
| --- | --- | --- | --- | --- | --- |
| scripts (lifecycle hooks) | recovery, install/scripts | phase label and position contracted (#141); `preinstall` execution landed via #142 | `preinstall` runs between `link` and `write`; a failed `scripts` phase discards the staged tree and leaves `node_modules`, `rpm.lock`, and `package.json` unchanged | #142 added success, failure, missing-command, wrong-type, and root `preinstall` fixtures under `tests/fixtures/install-projects/` | conforms |

Findings:

- The `scripts` phase is the only M6 addition to the recovery pipeline. It
  inherits the existing staged-replacement guarantee: a hook failure occurs
  while the staged replacement is linked but not yet published, so the previous
  `node_modules` stays in place and no lockfile or manifest write has run.
- The within-package lifecycle ordering (`preinstall`, `install`,
  `postinstall`, `prepare`) and the failure invariant (a failed `scripts` phase
  cannot publish partial successful install state) are owned by
  `docs/specs/core/install/scripts/SPEC.md`. This recovery SPEC owns only the
  phase label, its position, and the staged-tree discard guarantee.
- No existing M3 or M4 phase is changed by adding the `scripts` phase. The
  `resolve`, `fetch`, `extract`, `link`, and `write` labels and their
  side-effect classifications stand unchanged.

## Test Fixtures

Recovery verification should cover staged replacement success plus resolve,
fetch, extract, link, scripts, and write failures that leave the previous
`node_modules` contents intact. Scripts-phase fixtures are owned by
`docs/specs/core/install/scripts/SPEC.md` (#141) and landed with #142; they
prove that a failed lifecycle hook leaves `node_modules`, `rpm.lock`, and
`package.json` unchanged.
