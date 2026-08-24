---
spec_id: registry_metadata
title: Registry Metadata
status: draft
owner: core/registry
last_reviewed: 2026-08-24
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
  - 125
  - 127
  - 130
  - 133
  - 136
  - 139
  - 141
  - 142
  - 146
  - 170
  - 224
---

# Spec: Registry Metadata

Status: Draft
Owner: core/registry
Last reviewed: 2026-08-24

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
  resolver package key. Scoped names (`@scope/name`) are preserved verbatim as
  the package identity; only the registry lookup path encodes the name (see
  "Scoped package registry paths").
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

Package bin metadata. Per-version `bin` is read and preserved in both npm
forms — string (`"bin": "./cli.js"`) and object
(`"bin": { "name": "./target" }`) — so the linker can generate
`node_modules/.bin` entries for resolved packages. The binary name mapping
(unscoped string form uses the package name; scoped string form uses the
unscoped name; object form uses the keys verbatim) and the link layout are
owned by `docs/specs/core/linker/SPEC.md`. The registry boundary owns only
reading and preserving `bin`; it does not influence version selection,
dependency edges, cache writes, or integrity verification. A
present-but-wrong-type `bin` value is discarded as absent during deserialization
rather than failing the packument, consistent with the lenient handling of
other preserved fields. A version that omits `bin` simply contributes no
`.bin` entries.

Lifecycle script fields. Per-version `scripts` is read and preserved as a
`string -> string` map so the install lifecycle phase can execute recognized
lifecycle hooks (`preinstall`, `install`, `postinstall`, `prepare`). The
registry boundary owns only reading and preserving `scripts`; it does not
influence version selection, dependency edges, cache writes, or integrity
verification, and the registry boundary does not execute scripts. The active
lifecycle execution contract — which hook names run, in what order, with what
environment and PATH, and how their failure preserves install state — is owned
by `docs/specs/core/install/scripts/SPEC.md` (#141). A present-but-wrong-type
`scripts` value (for example a string or array) is discarded as absent during
deserialization rather than failing the packument, consistent with the lenient
handling of other preserved fields; the lifecycle phase then sees no hooks for
that package and proceeds. A version that omits `scripts` simply contributes no
lifecycle hooks. Non-lifecycle `scripts` entries (for example `test`, `build`,
`start`) are preserved but are not invoked during install; they remain
reachable only through `rpm run` (`docs/specs/cli/run/SPEC.md`).

### Planned v2 selected-metadata provenance and transport

Lockfile v2 records the selected registry origin and base endpoint together
with the selected version's immutable replay facts. The provenance tuple
consists of the canonical `registry_origin` and `registry_base`, external
`name` and selected `version`, `tarball`, required SHA-512 SRI `integrity`,
optional legacy `shasum`, the canonicalized `bin` map, `scripts`, and the
outgoing transitive dependency requests produced from that same per-version
record. A writer must take the whole tuple from one selected version record. It
must not combine a tarball, bin map, or scripts map from root fallback fields, a
different version, or a later metadata read.
`docs/specs/core/lockfile/SPEC.md` owns the v2 record shape and #224 owns its
runtime implementation.

The legacy single-version registry shape remains supported by current v1 paths,
but it is ineligible as a source for v2 publication. Its authoritative root
fallbacks supply version, dist, and dependencies without the required
per-version bin/scripts provenance tuple. A fresh v2 writer rejects that shape
after the side-effect-free metadata read and before tarball download, cache
mutation, extraction, or publication, including when the root dist carries valid
SHA-512 integrity. A future policy that admits legacy metadata must first define
the root bin/scripts source and update this SPEC and the lockfile SPEC together.

The initial v2 transport policy is fail-closed:

- `registry_origin` is the normalized origin of the configured HTTPS registry
  used for the packument request. It contains only scheme, host, and effective
  port; it has no user information, path, query, or fragment. The canonical
  spelling lowercases scheme and DNS host, removes a trailing DNS dot, omits
  the default HTTPS port `443`, and includes any non-default port explicitly. A
  replay reader compares the recorded value with the currently configured and
  policy-approved registry origin before cache access, network access, or
  extraction, including when a cache hit would avoid a request. A mismatch is
  ineligible for replay, and RPM must not contact the recorded origin first.
- `registry_base` is the canonical configured HTTPS registry endpoint used for
  the packument request. It retains the normalized origin and endpoint path
  prefix, without user information, query, or fragment. A percent sign in the
  serialized endpoint must introduce exactly two ASCII hexadecimal digits;
  malformed escapes are rejected before a packument or tarball request. Path
  canonicalization then decodes only ASCII unreserved escapes (`A-Z`, `a-z`,
  `0-9`, `-`, `.`, `_`, `~`), so `%41` becomes `A` and `%7e` becomes `~`.
  Escapes for reserved or non-ASCII octets remain escapes with uppercase hex,
  so `%2f` becomes `%2F` and never creates a path separator. The resulting
  literal `.` and `..` segments, including ones produced by `%2E` or `%2e`, are
  removed using the standard dot-segment walk; an attempt to walk above the
  endpoint root is rejected. Interior empty segments are preserved, a trailing
  slash run is removed except for the root path, and the root path is serialized
  as the origin without a trailing slash. A replay reader compares both
  `registry_origin` and `registry_base` with the currently configured and
  policy-approved endpoint before cache access, network access, or extraction.
  The origin parsed from `registry_base` must equal `registry_origin`. A
  same-origin endpoint with a different base path is a provenance mismatch; RPM
  must not contact the recorded endpoint first.

  The normalization matrix is part of this contract:

  | input path | canonical path |
  | --- | --- |
  | `/repo/` | `/repo` |
  | `/repo/%41/` | `/repo/A` |
  | `/repo/%7e` | `/repo/~` |
  | `/repo/%2e/` | `/repo` |
  | `/repo/x/%2E%2E/pkg` | `/repo/pkg` |
  | `/repo/%2E%2E` | `/` (serialized as the origin) |
  | `/%2E%2E/repo` | rejected above the endpoint root |
  | `/repo//packages///` | `/repo//packages` |
  | `/repo/%2f/private` | `/repo/%2F/private` |
  | `/repo/%3f` | `/repo/%3F` |
  | `/repo/%` or `/repo/%G0` | rejected as a malformed escape |
- The selected `tarball` is an absolute HTTPS URL with no user information,
  query, or fragment, and its normalized origin must equal `registry_origin`.
  Planned v2 rejects every query-bearing tarball URL before archive acquisition.
  This keeps credentials, signed URLs, and expiry values out of persisted
  lockfile provenance. V1 keeps its current URL handling. A future policy that
  needs private or expiring downloads must define a stable redacted locator and
  explicit runtime credential injection before v2 can admit one.
- Metadata and tarball redirects are limited to five hops. Every redirect
  target is parsed and checked before following it, remains HTTPS, has no user
  information, query, or fragment, and has the same normalized origin. A
  relative redirect is allowed only when resolution against the current URL
  produces a URL that passes those checks. Cross-origin redirects, HTTPS
  downgrades, and credential- or expiry-bearing redirect URLs are rejected. The
  initial v2 contract has no implicit CDN or alternate-origin exception.

Every v2 URL-policy rejection uses a redacted diagnostic locator. When parsing
succeeds, the locator may contain only the scheme, normalized lower-case host,
effective non-default port, and normalized path, followed by `?[redacted]` when
a query was present. It omits user information, the raw query, fragment, and
the raw URL. A malformed percent escape or otherwise unparseable URL reports a
stable rejection category without echoing the supplied URL. Error chains,
logs, and fixture diagnostics apply the same rule, so credential, signature,
and expiry query values never appear in diagnostics.

After the graph, name, and destination projections derivable without archive
bytes pass preflight, the approved tarball request may acquire bytes only into a
transaction-private non-published stable descriptor. SHA-512 verification binds
that descriptor to the selected provenance. #147 then validates archive entry
paths and symlink/hardlink targets from the same descriptor before extraction,
cache publication, or install publication. Acquisition creates no cache or
install publication.

Offline registry fixtures use the fixture transport and do not relax this
production URL policy. A future configurable registry or CDN allowlist requires
an explicit registry contract update and a stable provenance representation;
lockfile replay must not infer trust from a URL recorded by an unvalidated
lockfile alone.

The planned v2 packument fields have no npm signature or attestation primitive.
A digest stored beside a URL in the same lockfile binds archive bytes to that
record after the record is trusted; it cannot independently prove that the URL,
digest, bin map, scripts, or dependency facts came from npm. Fresh resolution
obtains the tuple over the configured HTTPS registry policy above. Later
no-refetch replay uses it only with the exact `TrustedLockfile` capability
established under the lockfile SPEC. An untrusted downloaded, generated, or
replaced lockfile is not eligible for replay, and replay remains disabled until
the #155 issuance and #224 enforcement APIs exist.

SHA-512 SRI is the only authenticated archive verifier accepted by planned v2.
The `integrity` field is required, non-empty, and must contain a valid supported
`sha512` token. A legacy `shasum` may be preserved when metadata supplies it,
but SHA-1 never makes a v2 record eligible and is not a v2 fallback. Missing,
empty, malformed, unsupported, or mismatched SHA-512 integrity blocks v2
publication, replay, and extraction even when a valid shasum is present. A
future equivalent authenticated provenance mechanism may replace SRI only after
this SPEC and the lockfile SPEC add an explicit typed mechanism and verification
rules.

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
  ordinary dependencies. The root manifest field is read and preserved per
  `docs/specs/core/manifest/SPEC.md`. Optional dependencies follow the same
  non-enqueue guard: the root manifest field is read and preserved per
  `docs/specs/core/manifest/SPEC.md`, and per-version optional dependencies on
  registry packuments remain ignored here until an optional-aware strategy
  consumes them.
- `engines`, `os`, and `cpu`. RPM deserializes these with npm-accurate types
  (`engines` as a map of engine name to range; `os` and `cpu` as arrays whose
  entries may be negated, for example `!win32`) but does not consume them.
  **There is no engine, OS, or CPU filtering, warning, skip, or rejection
  policy at the registry boundary.** Platform incompatibility is not a
  resolver or install failure today: a version whose `engines`/`os`/`cpu`
  declare an incompatible platform still selects, downloads, verifies, and
  links normally. This is an intentional deferred decision, not an absent one;
  active platform gating is deferred until a platform-gating strategy SPEC owns
  filter/warn/skip/fail behavior. The root-manifest read-and-preserve baseline
  for `engines`/`os`/`cpu` is owned by
  `docs/specs/core/manifest/SPEC.md`; per-version values on registry packuments
  remain ignored here until that strategy consumes them.
- `main`, `types`, `private`,
  `repository`, `description`, `maintainers`, `author`, `homepage`, `keywords`,
  `license`, `readme`, `readmeFilename`, `time`, `_id`, `_rev`, and `sequence`.
  These do not influence resolution, download, verification, extraction,
  linking, lockfile, or manifest output. Package `bin` metadata was previously
  listed here; it is now read for `.bin` generation (see "Package bin metadata"
  under Consumed metadata fields). Per-version `scripts` was previously listed
  here; it is now read and preserved for lifecycle execution (see "Lifecycle
  script fields" under Consumed metadata fields).

Ignored means RPM may accept documents that carry these fields, but no active
behavior depends on them. An ignored field that is invalid or missing must not
fail resolution or install: every ignored field is deserialized leniently so a
packument that omits or malforms any of them still parses. A
present-but-wrong-type value is discarded as absent during deserialization
rather than failing the packument, regardless of the field's expected shape.
This applies uniformly to all ignored fields: string fields such as `main`,
`license`, `readme`, and `readmeFilename`; map fields such as
`devDependencies`, `peerDependencies`, and `optionalDependencies`; array fields
such as `os`, `cpu`, and `keywords`; scalar fields such as `private` and
`sequence`; and the untagged-enum fields `repository`, `author`,
`bundledDependencies`, `engines`, `time`, `_rev`, and `homepage`. A wrong-type
value for any of these (for example a SPDX object-form `license`, a numeric
`engines`) is dropped to its absence without aborting packument parsing.
Well-typed values still round-trip into `Some(...)`. The same lenient
deserialization applies to preserved fields that are consumed downstream
(`bin`, `scripts`): a present-but-wrong-type `bin` or `scripts` value (for
example a string `scripts`) is discarded as absent without failing the
packument, while a well-typed value round-trips into `Some(...)` for the
downstream owner to consume.

### Unsupported metadata behavior

RPM rejects the following as input errors rather than silently proceeding:

- A dependency map value whose range text begins with the `npm:` scheme, matched
  ASCII case-insensitively (an npm alias declaration, for example
  `"foo": "npm:bar@1.2.3"` or `"foo": "NPM:bar@1.2.3"`). The case-insensitive
  scheme match mirrors npm's own `npm-package-arg`, which tests
  `spec.toLowerCase().startsWith('npm:')`. RPM does not resolve aliases today:
  without rejection it would assemble `"foo@npm:bar@1.2.3"`, split it on the
  last `@`, and look up a nonexistent package `"foo@npm:bar"`, hiding the real
  cause behind a misleading fetch failure. The alias is rejected as a resolver
  input error at the dependency-declaration boundary — when an install/add entry
  point turns a root-manifest entry into a direct resolver request, and when the
  resolver reads registry metadata to build a transitive dependency declaration
  — with a message that identifies the offending package and the alias target.
  Root-direct alias detection happens before any registry fetch; transitive
  alias detection happens during resolution (registry metadata read), so the
  root registries may already be fetched by the time a transitive alias is
  rejected. In both paths the alias is rejected before any tarball download,
  lockfile write, or install side effect. Detection is a prefix test on the
  range text, so a range that merely contains `npm:` at a non-prefix position
  is not rejected. Active alias consumption (resolving `npm:<name>@<version>`
  to a different registry package) remains an Open Question (issue #125).
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

For the current v1 path, when both `integrity` and `shasum` are absent or empty,
RPM may proceed without verification but must not claim the tarball was
verified. V1 also retains its existing shasum fallback when integrity is absent.
Planned v2 publication and replay require SHA-512 SRI under the
selected-metadata provenance contract above.

## Registry Boundary

The registry boundary resolves dist-tags and supplies version metadata to the
resolver through explicit abstractions. It must not duplicate semver range
parsing policy (owned by `docs/specs/core/semver/SPEC.md`) or perform installer
side effects.

For workspace classification, the boundary must expose whether a canonical
request is a published dist-tag key, with the empty/`latest` bare-selector path
handled by step 1, before semver range compatibility is considered. This
classification is separate from version selection: it does not select a version
or retrieve per-version metadata. External version selection continues to use
the precedence below.

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

For planned lockfile v2, the registry boundary returns the selected version
together with the selection branch: `empty`, `latest`, `dist-tag`, or `semver`.
An empty request records `empty`; the exact raw request `latest` records
`latest`; any other request that matched a `dist-tags` key records `dist-tag`;
every other request successfully selected through the semver facade records
`semver`. Tag matching retains its precedence when the tag text also parses as
semver. The v2 writer stores this value as the edge's required `selector_kind`,
allowing replay to use the pinned target without fetching the packument to
rediscover which branch won.

Only requests that are not registry dist-tags are evaluated as semver ranges.
This keeps version selection centralized and keeps dist-tag interpretation out of
semver code.

### Scoped package registry paths

A scoped package name (`@scope/name`) identifies one registry document, so the
registry lookup path must encode the name as a single path segment. npm's
registry serves a scoped packument at `/<percent-encoded-name>` where every `/`
in the scoped name is encoded as `%2F`; `@babel/core` is fetched from
`/@babel%2Fcore`. The version segment, when present, is a separate path
component following the encoded name.

The package identity stays verbatim everywhere except this one registry path:
the resolver package key, lockfile key, cache filename base, and linker path all
use the raw scoped name (`@scope/name`), and only the registry lookup path
percent-encodes it. This keeps one encoding rule at one boundary instead of
duplicating it across lockfile, cache, and linking.

The production registry client (`src/lib/api/mod.rs`) percent-encodes `/` as
`%2F` in the name segment via `registry_lookup_url` before the network request
(issue #170). Offline fixture resolution is unaffected: it routes
`@scope/name` to a local `@scope__name.json` file and never reaches the
production URL builder, so the fixture-backed test suite exercises the fixture
mapping rather than the encoded path. The encoded-path derivation itself is
covered by a focused unit test on `registry_lookup_url`.

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
- A planned v2 provenance tuple with an invalid registry origin or base endpoint,
  a same-origin/different-path registry drift, a disallowed tarball URL or
  redirect, a query-bearing tarball URL, malformed percent encoding, mixed-version
  metadata, an untrusted lockfile source, or missing/invalid SHA-512 SRI fails
  before archive acquisition, cache mutation, extraction, and any install output
  publication. The URL-policy diagnostic uses the redaction rules above and
  never echoes a rejected query, credential, signature, or expiry value.
  A valid SHA-1 shasum does not make that v2 tuple eligible.
- A legacy single-version root record is ineligible for v2 publication even when
  its root dist contains valid SHA-512 integrity; rejection occurs before tarball
  download or cache mutation. Existing v1 interpretation remains unchanged.

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
- planned v2 selector-kind capture, including a semver-shaped dist-tag recorded
  as `dist-tag` rather than reclassified as `semver` during replay
- missing dist rejected before fetch
- integrity verification of supported, mismatched, invalid, and absent variants
- planned v2 provenance cases covering same-version bin/scripts fact capture,
  rejection of mixed-version fields, and a legacy single-version root record
  carrying valid SHA-512 integrity rejected with zero tarball requests and zero
  cache writes; configured/recorded origin or canonical base endpoint mismatch
  (including same-origin/different-path drift), malformed percent escapes and
  the complete `registry_base` normalization matrix (uppercase retained hex,
  unreserved decoding, encoded dot/slash behavior, root traversal, repeated
  separators, and trailing slash), untrusted lockfile input, missing or
  unsupported integrity, shasum-only metadata, query-bearing
  credential/signature/expiry tarball URLs rejected with zero tarball requests
  and zero cache writes while diagnostics omit their raw query values,
  non-HTTPS and cross-origin tarballs, HTTPS downgrade, query-bearing redirect,
  cross-origin redirect, and redirect-limit overflow
- wrong-type values on every ignored metadata field are discarded as absent
  rather than failing the packument (issue #113), while well-typed values
  round-trip into `Some(...)`
- npm alias dependency declarations are rejected as resolver input errors at
  the dependency-declaration boundary for both root-manifest and transitive
  paths, with a clear message naming the offending package and alias target,
  while a range that only contains `npm:` at a non-prefix position is not
  rejected; the `npm:` scheme is matched ASCII case-insensitively, so mixed-case
  prefixes such as `NPM:` and `Npm:` are rejected too (issue #125)
- `optionalDependencies` is preserved on the deserialized packument (root and
  per-version) but is not exposed as an ordinary dependency edge, mirroring the
  `peerDependencies` non-enqueue guard; the `registry/optional-preserve` fixture
  covers the current non-optional-aware contract (issue #133). The
  `peerDependencies` non-enqueue guard is covered by the
  `registry/peer-preserve` fixture (issue #130).

New fixtures should cover dist metadata, dist-tags, dependencies, optional
dependencies, peer dependencies, engines, OS/CPU, aliases, scoped packages, and
package bin metadata only as needed for narrow compatibility scenarios, and must
not duplicate the contract text above.

## Open Questions

- When and how RPM begins consuming `peerDependencies`, `optionalDependencies`,
  `engines`, `os`, and `cpu` as active behavior. These remain ignored at the
  registry boundary until a peer-aware resolution strategy, an optional-aware
  strategy, or platform gating owns the active behavior. Package `bin` metadata
  is now consumed for `.bin` generation
  (`docs/specs/core/linker/SPEC.md`, #139) and is no longer an open question.
  Per-version `scripts` is now read and preserved for lifecycle execution
  (`docs/specs/core/install/scripts/SPEC.md`, #141) and is no longer an open
  question at this boundary; active execution of the first phase is tracked by
  #142.
  The root manifest `optionalDependencies` read-and-preserve
  baseline is now owned by `docs/specs/core/manifest/SPEC.md`; per-version
  `optionalDependencies` on registry packuments remain ignored here until an
  optional-aware strategy consumes them as dependency edges. The reserved
  failure policy for that future optional-aware strategy (skip-and-warn on
  resolution/download/install failure, skip-silently on platform mismatch,
  record only successful installs) is owned by
  `docs/specs/core/resolver/SPEC.md` and `docs/specs/core/lockfile/SPEC.md`
  (#133); until that strategy exists, per-version optional dependencies on
  registry packuments stay ignored here regardless of the root-manifest entry.
  The root manifest `engines`/`os`/`cpu` read-and-preserve baseline is now owned
  by `docs/specs/core/manifest/SPEC.md` (#127); per-version `engines`/`os`/`cpu`
  on registry packuments remain ignored here until a platform-gating strategy
  consumes them.
- When and how RPM begins actively consuming npm alias declarations (resolving
  `npm:<name>@<version>` to a different registry package). npm aliases are
  currently rejected as input errors (issue #125); active consumption would
  require its own milestone, a lockfile record shape distinguishing install
  name from resolved name, and resolver changes, and is therefore deferred.
