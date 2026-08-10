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

## M5 Ownership and Gap Audit

The M5 audit maps each npm metadata compatibility area to its owning SPEC/ADR
and records whether the contract is explicitly stated. M5 is an npm metadata
compatibility milestone: it must classify every registry metadata category as
consumed, ignored, or rejected before any category gains active behavior, so
RPM does not treat unsupported metadata as successful compatibility.

| M5 compatibility area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| registry metadata fields consumed by RPM | `registry/SPEC.md` | consumed / ignored / rejected classification is explicit (root `name`, `dist-tags`, `versions`; per-version `dependencies`, `dist`; `dist.tarball`, `dist.integrity`, `dist.shasum`); legacy single-version shape also consumes root `version`, `dist`, and `dependencies` as documented in the SPEC's "Legacy root fallbacks" section | delivered: #110 landed via #112 |
| ignored-field tolerant deserialization | `registry/SPEC.md` | every ignored metadata field deserializes leniently: a missing, null, or wrong-type value is discarded as absent rather than failing the packument, and `bundledDependencies` accepts map or array (applies uniformly to all ignored fields, not only the originally-tolerated set) | delivered: #113 landed via #116; uniform coverage landed via #122 |
| dist-tag and root metadata fallback gating | `registry/SPEC.md` | a dist-tag target absent from `versions` is rejected; root `dist` / `dependencies` fallback only applies to the legacy single-version shape | delivered: #114 landed via #118 |
| dist-tags / `latest` / semver range selection boundary | `registry/SPEC.md`, `semver/SPEC.md` | dist-tags are registry selectors, not semver ranges; `latest` and tag precedence over ranges is defined | none |
| build-metadata deterministic selection | `registry/SPEC.md` (Registry Boundary, precedence step 3) | registry-owned raw-key sort before `max_satisfying` makes selection repeatable across `HashMap` seedings | delivered: #115 / #117 landed |
| optionalDependencies | `registry/SPEC.md` (ignored list) | classified as ignored (not enqueued); no active read / resolve / install / skip / report contract exists yet | draft: compat optionalDependencies contract |
| peerDependencies | `resolver/SPEC.md`, `registry/SPEC.md` (ignored list) | non-peer-aware strategy must not enqueue peer deps as ordinary dependencies; no peer-requirement field is implemented (spec-only) | draft: compat peerDependencies preservation and diagnostics |
| engines, os, cpu | `registry/SPEC.md` (ignored list) | classified as ignored; no engine, OS, or CPU filtering, warning, or rejection policy exists | draft: compat engines/os/cpu metadata policy |
| package bin metadata | `linker/SPEC.md` (out of scope) | `.bin` generation is explicitly out of scope; `bin` is not modeled on registry types | M6 linker contract owns this |
| scoped package names | `registry/SPEC.md`, `linker/SPEC.md`, `lockfile/SPEC.md` | scoped names are owned throughout: registry consumes the scoped `name`, linker preserves the scope directory in the link path, and lockfile records `name` including scope | none |
| npm aliases | (no owning SPEC) | npm alias syntax (`npm:<name>@<version>`) is unrepresented in SPECs and source | draft: compat alias contract |

Findings:

- Ownership exists for the registry metadata boundary. The consumed / ignored /
  rejected classification landed in #112, and the deserialization behavior that
  the classification implies was made tolerant in #116 and gated against stale
  root fallbacks in #118.
- The dist-tag and semver range selection boundary is fully owned across
  `registry/SPEC.md` and `semver/SPEC.md`; the build-metadata deterministic
  tie-break closes the last selection-repeatability gap (#115 / #117).
- The remaining M5 frontier is per-field classification: optional dependencies,
  peer dependencies, engines/os/cpu, package bin metadata, and npm aliases each
  need an active-behavior contract (or an explicit deferred decision) before
  implementation. Each is represented by a compat draft task in Project #7.
- Package `bin` metadata is intentionally deferred to the M6 linker milestone,
  where `.bin` generation is owned; it is listed here so the boundary is
  explicit, not so M5 implements it.
