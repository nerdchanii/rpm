---
spec_id: registry_metadata
title: Registry Metadata
status: draft
owner: core/registry
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
  - 110
  - 113
  - 114
  - 120
---

# Spec: Registry Metadata

Status: Draft
Owner: core/registry
Last reviewed: 2026-08-10

## Purpose

RPM consumes a narrow subset of npm registry package-document metadata to select
versions, locate tarballs, verify integrity, and discover dependency edges. This
contract defines which registry metadata fields RPM consumes, which it ignores,
and which it rejects, and keeps registry metadata interpretation separate from
semver range parsing and installer side effects.

This is the M5 foundation for npm compatibility work. Semver range behavior is
owned by `docs/specs/core/semver/SPEC.md`. Cache writes, extraction, and linking
are owned by the install and linker SPECs. This document owns only the boundary
between registry metadata and the consumers that read it.

## Contract

Registry metadata is the npm registry package document keyed by package name. The
authoritative implementation lives in `src/lib/registry/mod.rs` through the
`Registry`, `Version`, `Dist`, and `DistTags` types. RPM reads metadata without
writing files: metadata reads must remain side-effect free even when the document
carries tarball URLs.

### Metadata sources

RPM reads two shapes of registry document:

1. A full packument with a `versions` map keyed by version string plus a
   `dist-tags` map. This is the primary shape; the selected version's
   `Version` record supplies dependencies and dist metadata. A version key that
   is absent from the map is never substituted with root fields — the lookup
   fails (see "Legacy root fallbacks" and "Unsupported metadata behavior").
2. A legacy single-version shape that carries a top-level `version`, `dist`,
   and `dependencies` and no `versions` map. Root fields are the authoritative
   record for this shape and are consulted in place of per-version metadata
   (see "Legacy root fallbacks").

### Consumed metadata fields

RPM consumes the following fields. Fields are grouped by where they are read.

Root document (`Registry`):

- `name`: package name, including scope. Used as the cache filename base and the
  resolver package key.
- `dist-tags`: map of tag name to version string. Tag resolution happens at the
  registry boundary before semver range evaluation. `latest` and any other
  published tag (for example `next`, `beta`) resolve to their target version.
- `versions`: map of version string to per-version `Version` record. The keys
  are the candidate version set for semver range selection.

Legacy root fallbacks. RPM consults these root fields only for the legacy
single-version shape — that is, when the `versions` map is entirely absent. When
a `versions` map is present, a version key missing from the map is never
silently substituted with root fields; the lookup fails instead (see
"Unsupported metadata behavior"):

- `version`: the single published version. Used by `latest`/empty selection
  ahead of `dist-tags.latest` (see "Registry Boundary").
- `dist`: root-level dist metadata used when `get_dist_for_version` is consulted
  for the legacy shape (no `versions` map).
- `dependencies`: root-level dependency map used when
  `get_dependencies_for_version` is consulted for the legacy shape (no
  `versions` map).

Because root fallbacks are gated on the absence of the `versions` map, a
dist-tag target absent from the map is rejected at selection time rather than
falling through to root `dist`/`dependencies` (see "Registry Boundary").

Per-version record (`Version`):

- `dependencies`: map of package name to range. Consumed as transitive
  dependency edges during graph resolution. This is the only dependency map RPM
  enqueues as ordinary dependency requests.
- `dist`: per-version distribution metadata (see below).

Deserialized for document fidelity but not consumed after parsing: the
per-version `name` and `version` fields. RPM selects versions by the `versions`
map key and carries that key through dependency lookup, cache naming, and
lockfile creation; the embedded `Version.version` and `Version.name` are never
read by an active code path and do not influence selection.

Distribution record (`Dist`):

- `tarball`: tarball download URL. `Dist` (and therefore `Version.dist`) is a
  non-optional Serde field, so any `versions` entry that omits `dist` or
  `dist.tarball` fails packument parsing before version selection. The
  post-selection "no tarball" path is reached when the selected version key is
  absent from the `versions` map (root fallback no longer applies once a
  `versions` map exists); the fetch phase then fails before any network request.
- `integrity`: Subresource Integrity value. Authoritative when present. The
  supported algorithm is `sha512`. RPM may select any matching `sha512` token
  when the value contains multiple whitespace-separated tokens.
- `shasum`: legacy hex-encoded SHA-1 digest. The fallback when `integrity` is
  absent or empty. Used for tarball verification when no supported SRI value
  exists.

### Ignored metadata fields

The following fields are deserialized for document fidelity but are not consumed
by any active install, resolver, lockfile, linker, or script behavior. They do
not affect version selection, dependency edges, cache writes, or integrity
verification:

- `devDependencies`, `peerDependencies`, `optionalDependencies`, and
  `bundledDependencies` on both the root document and per-version records. RPM
  does not enqueue these as dependency requests in the current non-peer-aware,
  non-optional-aware strategy. Peer dependencies are represented as peer
  requirement metadata on resolved package records per
  `docs/specs/core/resolver/SPEC.md`; they must not be silently enqueued as
  ordinary dependencies. Optional dependencies follow the same non-enqueue
  guard: the root manifest field is read and preserved per
  `docs/specs/core/manifest/SPEC.md`, and per-version optional dependencies on
  registry packuments remain ignored here until an optional-aware strategy
  consumes them.
- `engines`, `os`, and `cpu`. RPM does not perform engine, OS, or CPU filtering.
  Platform incompatibility is not a resolver or install failure today.
- `main`, `types`, `scripts`, `bin`/package bin metadata, `private`,
  `repository`, `description`, `maintainers`, `author`, `homepage`, `keywords`,
  `license`, `readme`, `readmeFilename`, `time`, `_id`, `_rev`, and `sequence`.
  These do not influence resolution, download, verification, extraction,
  linking, lockfile, or manifest output.

Ignored means RPM may accept documents that carry these fields, but no active
behavior depends on them. An ignored field that is invalid or missing must not
fail resolution or install: every ignored field is deserialized leniently so a
packument that omits or malforms any of them still parses. A
present-but-wrong-type value is discarded as absent during deserialization
rather than failing the packument, regardless of the field's expected shape.
This applies uniformly to all ignored fields: string fields such as `main`,
`license`, `readme`, and `readmeFilename`; map fields such as `scripts`,
`devDependencies`, `peerDependencies`, and `optionalDependencies`; array fields
such as `os`, `cpu`, and `keywords`; scalar fields such as `private` and
`sequence`; and the untagged-enum fields `repository`, `author`,
`bundledDependencies`, `engines`, `time`, `_rev`, and `homepage`. A wrong-type
value for any of these (for example a SPDX object-form `license`, a numeric
`engines`, or a string `scripts`) is dropped to its absence without aborting
packument parsing. Well-typed values still round-trip into `Some(...)`.

### Unsupported metadata behavior

RPM rejects the following as input errors rather than silently proceeding:

- A dist-tag whose target version string is absent from the `versions` map when
  a `versions` map is present. The tag is treated as unsatisfiable (a resolver
  failure) rather than returning a version key with no per-version metadata.
  This prevents a tag from silently selecting root `dist`/`dependencies` under
  an unrelated version key (issue #114). When no `versions` map is present
  (legacy single-version shape), the tag target resolves normally via root
  fields.
- A selected version with no `tarball` URL reachable after version selection
  (i.e. the version key is absent from the `versions` map; root `dist` no longer
  applies once a `versions` map exists). The download phase must return an error
  instead of writing a placeholder cache file (owned with
  `docs/specs/core/install/cache/SPEC.md`). Note that an entry inside the
  `versions` map with a missing `dist` or `dist.tarball` is rejected earlier,
  during Serde parsing of the packument.
- An `integrity` value whose supported `sha512` token digest does not match the
  downloaded bytes, whose digest is not valid base64, or which carries no
  supported algorithm. The integrity gate fails the fetch/verify phase before
  extraction (owned with
  `docs/specs/core/install/performance/SPEC.md`).
- A `shasum` value that is not a 40-character hex string when used as the
  fallback verification digest, or whose SHA-1 digest does not match the
  downloaded bytes.

When both `integrity` and `shasum` are absent or empty, RPM may proceed without
verification but must not claim the tarball was verified.

## Registry Boundary

The registry boundary resolves dist-tags and supplies version metadata to the
resolver through explicit abstractions. It must not duplicate semver range
parsing policy (owned by `docs/specs/core/semver/SPEC.md`) or perform installer
side effects.

Version selection precedence at the registry boundary:

1. An empty request or `latest` resolves to the root `version` fallback when
   present; otherwise to the `latest` dist-tag when present. (The current
   implementation checks root `version` before `dist-tags.latest`.) The resolved
   target is then subject to the same membership guard as step 2: it is returned
   only when it exists in the `versions` map, or when no `versions` map is
   present (legacy single-version shape). When a `versions` map is present but
   the resolved target is absent from it, the request is rejected as
   unsatisfiable rather than returning a version key with no per-version
   metadata. This is what gates a dangling `latest` tag (and bare dependency
   requests, which are normalized to `latest`) the same way an explicit dist-tag
   is gated (issue #114).
2. A request matching any `dist-tags` key resolves to that tag's target version
   string only when the target exists in the `versions` map, or when no
   `versions` map is present (legacy single-version shape). When a `versions`
   map is present but the target is absent from it, the tag is rejected as
   unsatisfiable rather than returning a version key with no per-version
   metadata. This prevents a tag from silently selecting root `dist`/
   `dependencies` under an unrelated version key (issue #114).
3. Any other request is evaluated as a semver range against the `versions` keys
   by the semver facade. `max_satisfying` keeps the first candidate on equal
   precedence; `Version::cmp` ignores build metadata, so keys that differ only
   in build metadata (for example `1.0.0+one` and `1.0.0+two`) are equal. The
   `versions` map is deserialized into a randomized `HashMap`, so feeding its
   keys in iteration order would make the first-seen-wins choice — and therefore
   the selected raw key — depend on HashMap seeding, producing a different
   lockfile across runs. The registry boundary removes this nondeterminism by
   sorting the raw keys before calling the semver facade, so first-seen-wins
   always lands on the same least raw key. The semver facade itself is not
   modified: it preserves `node-semver` first-matching behavior, and no
   RPM-specific semver dialect is introduced (owned by
   `docs/specs/core/semver/SPEC.md`). This keeps determinism at the registry
   boundary, where the randomized map lives, rather than in shared semver code.

Only requests that are not registry dist-tags are evaluated as semver ranges.
This keeps version selection centralized and keeps dist-tag interpretation out of
semver code.

## Error Cases

Registry metadata interpretation must not panic on user- or registry-controlled
content. Failures must be returned to callers as typed errors:

- A package absent from the registry, or a registry response that cannot be
  read or parsed, surfaces as a **fetch** failure during metadata population
  (before the resolver runs). Missing metadata discovered later, during
  resolution (for example a transitive dependency whose metadata was never
  fetched), surfaces as a **resolve** failure via `ResolutionError::MissingMetadata`
  (owned by `docs/specs/core/resolver/SPEC.md`).
- A requested range that cannot be satisfied or is invalid is a resolver failure
  (owned by `docs/specs/core/semver/SPEC.md`).
- A selected version with no reachable `tarball` URL (version key absent from
  the `versions` map and no root `dist` fallback) is a fetch/download failure
  that occurs before any network tarball request (owned with
  `docs/specs/core/install/cache/SPEC.md`).
- A supported integrity or shasum value that does not match downloaded bytes is
  an integrity failure that blocks extraction, lockfile writes, and manifest
  writes (owned with `docs/specs/core/install/performance/SPEC.md` and
  `docs/specs/core/install/recovery/SPEC.md`). Because the tarball is downloaded
  and cached before verification, this failure is reported after the allowed
  fetch/verify cache side effect, not before all installer side effects.

Registry metadata **read and interpretation** failures (parsing, version
selection, dist lookup) must be reported before installer side effects and must
not be hidden behind a panic. Integrity verification is intentionally excluded
from this guarantee: the bytes it checks are produced by the fetch/verify step
and are an allowed side effect per
`docs/specs/core/install/recovery/SPEC.md`.

## Test Fixtures

Registry metadata fixtures are offline JSON documents shaped like npm registry
packuments. They live under `tests/fixtures/registry/` and the per-scenario
`registry/` directories under `tests/fixtures/install-projects/`.

Fixture expectations are defined by the owning scenario and documented in
`docs/conventions/install_fixture_outputs.md`; they are not duplicated here. The
`src/lib/registry/mod.rs` unit tests verify the consumed-field contract:

- cache filename derivation for unscoped and scoped names (name + version)
- tarball URL lookup for the selected version and the root-level `dist` fallback
- integrity-only dist metadata (no legacy shasum)
- legacy single-version document shape (root `version`, `dist`, `dependencies`)
- dist-tag resolution before semver range evaluation
- missing dist rejected before fetch
- integrity verification of supported, mismatched, invalid, and absent variants
- wrong-type values on every ignored metadata field are discarded as absent
  rather than failing the packument (issue #113), while well-typed values
  round-trip into `Some(...)`

New fixtures should cover dist metadata, dist-tags, dependencies, optional
dependencies, peer dependencies, engines, OS/CPU, aliases, scoped packages, and
package bin metadata only as needed for narrow compatibility scenarios, and must
not duplicate the contract text above.

## Open Questions

- When and how RPM begins consuming `peerDependencies`, `optionalDependencies`,
  `engines`, `os`, `cpu`, and package `bin` metadata as active behavior. These
  remain ignored at the registry boundary until a peer-aware resolution
  strategy, an optional-aware strategy, platform gating, or `.bin` generation
  SPEC owns the active behavior. The linker SPEC already notes `.bin` generation
  is out of scope. The root manifest `optionalDependencies` read-and-preserve
  baseline is now owned by `docs/specs/core/manifest/SPEC.md`; per-version
  `optionalDependencies` on registry packuments remain ignored here until an
  optional-aware strategy consumes them as dependency edges.
