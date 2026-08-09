# Core SPECs

This directory holds core package-manager contract documents.

Core SPECs define behavior that must remain callable without CLI parsing or
terminal presentation. That includes manifest handling, semver policy,
dependency resolution, lockfile behavior, install staging, and linking.

Current core contracts:

- `manifest/SPEC.md`
- `semver/SPEC.md`
- `resolver/SPEC.md`
- `registry/SPEC.md`
- `lockfile/SPEC.md`
- `install/cache/SPEC.md`
- `install/recovery/SPEC.md`
- `install/performance/SPEC.md`
- `linker/SPEC.md`

## M4 Ownership and Gap Audit

The 2026-08-07 M4 audit maps each M4 behavior area to its owning SPEC/ADR and
records whether the contract is explicitly stated. M4 is a measurement and
deduplication milestone: it must observe duplicate graph nodes and duplicate
downloads deterministically before expanding npm compatibility or adding
concurrency. All follow-up tickets below landed and merged to `main`; M4 is
complete.

| M4 behavior area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| install pipeline shape | `install/performance/SPEC.md` | states the current recursive bottleneck and the future staged pipeline (resolve → dedupe → fetch → download → verify → extract → link → write) | none |
| resolver graph deduplication | `resolver/SPEC.md`, ADR 0006 | resolved graph preserves requested range and selected version; node uniqueness by `<name>@<version>` is stated in the resolver contract | closed by this audit |
| tarball download deduplication | `install/performance/SPEC.md`, `install/cache/SPEC.md` | performance SPEC states a selected version downloads once; cache SPEC's version-keyed filename `<name>@<version>.tgz` yields one cache file per selected version | none |
| cache behavior | `install/cache/SPEC.md` | staged write plus same-directory rename publication; metadata reads are side-effect free | none |
| lockfile preservation | `lockfile/SPEC.md` | `<name>@<version>` key; requested range and selected version recorded as separate fields | none |
| manifest reads | `manifest/SPEC.md` | `package.json` read and save contract | none |
| recovery behavior | `install/recovery/SPEC.md` | staged `node_modules` replacement, phase labels (`resolve|fetch|extract|link|write`), M3 and M4 side-effect audit tables | #96 added the M4 side-effect audit (completed, landed via #107) |
| measurement harness | `install/performance/SPEC.md`, ADR 0005 | harness records metadata fetch and tarball download counts through a fake registry API owned by the install domain | #93 added the metadata-read counter (completed, landed via #106); the tarball download counter landed in #103 |

Findings:

- Ownership exists for every M4 behavior area; no area is unowned.
- Graph node uniqueness was implied by the resolver merge step but was not
  stated as an invariant in the owning resolver SPEC. This audit adds the
  invariant there; the dedup behavior was already proven by the resolver test
  tracked by #94 (landed via #74). The download-dedup proof is a separate
  install-layer test landed in #103.
- The performance SPEC states the measurement-harness contract (metadata fetch
  and tarball download counts via a fake registry). Both counters are now
  implemented: the tarball download counter (#103) and the metadata-read
  counter (#93, landed via #106).
- The M4 delivery order was decomposed into phase-isolated tickets, all
  completed: #93 (measurement harness, landed via #106), #94 (graph dedup
  proof), #103 (download dedup proof), #96 (phase side-effect audit, landed
  via #107), and #97 (fixture output convention, landed via #108).
