---
spec_id: lockfile_v1_v2
title: Lockfile v1 and planned workspace lockfile v2
status: draft
owner: core/lockfile
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
  - 133
  - 136
  - 146
  - 147
  - 221
  - 222
  - 224
---

# Spec: Lockfile v1 and planned workspace lockfile v2

Status: Draft
Owner: core/lockfile
Last reviewed: 2026-08-24

## Purpose

`rpm.lock` is the reproducibility contract for installs. It records the
requested package graph and the resolved package facts needed by later install
phases. The root-only v1 format is current behavior. Workspace-aware records
are a planned v2 contract; this document does not claim that workspace
serialization, replay, or installation is implemented.

## Contract

### Format

#### Version policy

The `lockfile_version` marker is authoritative and is read before any package
record is interpreted. Version `1` is the current root-only format described
below. A v1 reader must reject `lockfile_version = 2` explicitly, and an
unknown version must fail before record decoding. A future workspace-aware
reader may accept v1 for a root-only project, but accepting v1 does not make it
a workspace graph.

Version `2` is required for a lockfile that records a workspace member table or
any workspace-aware edge. A workspace declaration paired with v1 cannot be
replayed as a workspace graph or converted by adding a local marker: v1 has no
member origins and no per-parent edges. It requires a fresh deterministic
resolution and an atomic v2 publication. There is no automatic downgrade from
v2 to v1. A fresh root-only resolution may continue to write v1 under the
current compatibility policy.

The current v1 reader checks this marker before decoding package records and
rejects version 2. Its flattened package and script maps have no canonical
byte-order guarantee; canonical byte stability is a v2 requirement.

#### Current v1 format

The lockfile is TOML and starts with project metadata:

```toml
lockfile_version = 1
name = "app"
version = "0.1.0"
```

Each package entry is keyed by `<package-name>@<resolved-version>`.

```toml
["react@18.2.0"]
name = "react"
requested = "^18.0.0"
version = "18.2.0"
relationship = "direct"
tarball = "https://registry.npmjs.org/react/-/react-18.2.0.tgz"
integrity = "sha512-..."
scripts = { preinstall = "echo preparing" }
dependencies = ["loose-envify@^1.1.0"]
```

A scoped package keeps its `@scope/name` form verbatim in both the entry key and
the `name` field; neither the scope separator `/` nor the leading `@` is
escaped or sanitized. `["@scope/lib@1.0.0"]` is the entry key for
`@scope/lib` at `1.0.0`, and readers split the key on the last `@` so the
scoped name is recovered whole.

```toml
["@scope/lib@1.0.0"]
name = "@scope/lib"
requested = "^1.0.0"
version = "1.0.0"
relationship = "direct"
tarball = "https://registry.npmjs.org/@scope/lib/-/lib-1.0.0.tgz"
integrity = "sha512-..."
dependencies = []
```

Package entries record:

- `name`: package name, including scope when present. Scoped names are
  preserved verbatim; only the cache filename sanitizes the `/`
  (`docs/specs/core/install/cache/SPEC.md`) and only the registry lookup path
  percent-encodes it (`docs/specs/core/registry/SPEC.md`).
- `requested`: the range or tag requested by the parent manifest or package.
- `version`: resolved package version.
- `relationship`: one of `direct`, `dev`, or `transitive`.
- `tarball`: resolved tarball URL when registry metadata provides it.
- `integrity`: Subresource Integrity value when provided.
- `shasum`: legacy shasum when `integrity` is absent or when the registry only
  provides a shasum.
- `scripts`: selected per-version lifecycle script map from registry metadata;
  install lifecycle execution consumes this persisted map.
- `dependencies`: dependency edges as requested package references.

`peerDependencies` and `optionalDependencies` are not recorded in lockfile v1.
The current non-peer-aware, non-optional-aware strategy neither resolves nor
links these edges, so recording them would freeze metadata that no install
phase consumes. Peer and optional metadata remain preserved on the manifest
(`docs/specs/core/manifest/SPEC.md`) and on registry packuments
(`docs/specs/core/registry/SPEC.md`) without appearing in `rpm.lock`. A
`relationship` value for peer or optional edges, and any lockfile
representation of unmet peer or optional requirements, must be added by the
peer-aware or optional-aware strategy SPEC that first consumes them; lockfile
v1 does not reserve those values.

The reserved lockfile policy for the first optional-aware strategy is:
optional dependencies that are installed successfully are recorded with the
same shape as ordinary dependencies (requested range and resolved version kept
distinct), and optional dependencies that are skipped at any lifecycle stage
are not recorded. This keeps `rpm.lock` a record of the actually installed
graph rather than the requested optional set, so a later install reproduces the
same skip deterministically instead of re-attempting an entry known to be
uninstallable on this platform. Whether the skipped set is summarized in a
separate lockfile section is an open question for that strategy SPEC; lockfile
v1 records nothing about optional edges either way.

### Loading

An absent or empty lockfile initializes as an empty v1 lockfile. Empty loading
must not be reported as successful dependency resolution; it only gives callers a
safe in-memory lockfile to mutate.

Malformed TOML or malformed lockfile fields are load failures. Parse failures
must include the lockfile path and parser context.

### Saving

Saving writes the complete current lockfile and truncates old content. Save
errors must include the lockfile path and must not be hidden behind panics.

### Planned workspace lockfile v2

The first workspace-aware lockfile uses `lockfile_version = 2`. Its records
are deliberately separate from v1's flattened package map: resolution roots
describe the root and discovered members, external package records store each
resolved registry fact once, and edges retain every parent relationship. The
resolver's #145 member table is the input; this section does not redefine
workspace discovery, local classification, linking, or command targeting.

#### Record identities and fields

Unless a field is explicitly described as optional, it is required. A v2
document has the required top-level fields `lockfile_version = 2`, `name`, and
`resolution_roots`, plus an optional `version` and the `external_packages` and
`edges` collections. Top-level `name` must equal the root record's `name`.
Top-level `version` and the root record's `declared_version` must have identical
presence and exact text. `resolution_roots` is non-empty because it always
contains the root. `external_packages` and `edges` are omitted when empty and
must be emitted as arrays of tables when non-empty; readers treat their omission
only as an empty collection. Writers must not emit an empty array for either
collection. No unlisted top-level, record, or identity field is accepted in v2.

Every identity is a structured TOML table. Consumers must not encode or parse
identity by splitting a delimiter-containing string. The allowed identity
forms are:

- `{ kind = "root", path = "." }` for the project root;
- `{ kind = "workspace", path = "packages/a" }` for a member's canonical
  root-relative path, using `/` separators; and
- `{ kind = "external", name = "lodash", version = "4.17.21" }` for a
  resolved registry package.

All v2 identity and path text is valid UTF-8. A workspace `origin.path` is the
exact `member_path_key` supplied by manifest discovery. The manifest SPEC owns
lossless native-component decoding, NFC serialization, portable UTF-8 round
tripping, and rejection before resolver handoff; the lockfile writer must not
reconstruct a path from native components or apply a second normalization.

The root is represented exactly once, first in `resolution_roots`. Each
discovered member is represented exactly once after the root, in the stable
order supplied by #145. A root record requires `origin`, `manifest_path`, and
`name`; `declared_version` is optional. A member record has the same fields.
The root uses `origin.kind = "root"`, `origin.path = "."`, and
`manifest_path = "package.json"`. A member uses `origin.kind = "workspace"`,
its canonical root-relative member path as `origin.path`, and
`<origin.path>/package.json` as `manifest_path`. `declared_version` is omitted
exactly when its manifest has no version text and otherwise preserves that text
without normalization. The recorded roots must have unique origins and names,
and a root/member name collision is invalid.

An external package record requires `identity`, `name`, `version`,
`registry_origin`, `tarball`, `integrity`, and `scripts`; `shasum` is optional.
`identity` must be an external identity whose `name` and `version` exactly equal
the record fields. `registry_origin` is the normalized HTTPS origin from which
the selected packument was obtained. `tarball` is the non-empty resolved
download URL supplied by that selected registry version and must satisfy the
registry SPEC's scheme, origin, and redirect policy. Before any cache access,
network access, or extraction, replay requires the recorded origin to equal the
currently configured and policy-approved registry origin, including on a cache
hit. `integrity` must be non-empty and contain a valid supported SHA-512
SRI token. A legacy `shasum` is preserved when supplied but never substitutes
for integrity in v2. Replay never refetches mutable metadata to recover an
omitted URL or verifier, so a missing or empty `registry_origin`, `tarball`, or
`integrity`, an unsupported integrity value, or a shasum-only record makes the
v2 document invalid and blocks extraction. The initial v2 schema has no
verifier-free or SHA-1-only authenticated-provenance alternative.

`scripts` is always present as a `string -> string` map and is `{}` when the
selected version has no lifecycle scripts. The registry origin, external
identity fields, tarball, verifier fields, scripts map, and outgoing transitive
dependency requests form one selected-version provenance snapshot. A fresh
writer captures them from one metadata record without mixing versions or later
reads. Before an external lifecycle hook runs, the locked scripts map must also
match the scripts map read from `package.json` inside the already verified
archive under `docs/specs/core/install/scripts/SPEC.md`; a mismatch fails
closed. External identities are unique. Dependency relationships are
represented by `edges`, not duplicated inside this package record. A package
fact is written once even when several parents reach the same name and version.
Local workspace members have no external package record and do not require a
registry origin, tarball, integrity, or shasum.

Before any external archive entry is extracted or published, #147's archive
inspection boundary reads the single package manifest from the stable
SHA-512-verified descriptor without materializing archive output. Its `name` and
`version` must both be strings and must exactly equal the external record's
`name`, `version`, and structured identity fields. A missing, duplicate,
ambiguous, malformed, wrong-type, or mismatching package manifest fails before
extraction, lifecycle hooks, cache publication, lockfile publication, or install
publication. The descriptor is rewound for extraction only after this identity
gate succeeds. #147 owns safe archive-entry selection and symlink/hardlink
handling; this SPEC owns the exact identity predicate consumed by v2 replay.

Before a v2 identity can drive a cache, fetch, extraction, link, or script
operation, its external `name` and `version` must pass a platform-independent
filesystem-confinement check. This is a path-safety gate, not a full npm
package-name syntax policy. An unscoped name is one filename component. A
scoped name is exactly two non-empty components in `@scope/name` form, with `/`
used only as that single scope separator. Every component and the version must
be non-empty, must not be `.` or `..`, and must contain no ASCII control,
backslash, colon, or Windows-reserved filename character (`<`, `>`, `"`, `|`,
`?`, or `*`); a component ending in a space or `.` is also invalid. The version
must contain no `/`, and an external name or version with an absolute, UNC,
device, or ASCII drive-qualified spelling is invalid on every host. The cache
and linker must derive destinations from these validated components and verify
that the resulting lexical destination remains below its approved root before
any mutation. A reader and a fresh v2 writer both apply this check, so unsafe
registry metadata cannot be published and a crafted lockfile cannot escape a
filesystem root.

Lexical confinement is followed by a host-filesystem projection check for every
cache and linker destination. The owning cache and linker boundaries derive
comparison keys that reflect the actual destination filesystem's case folding,
Unicode normalization, trailing-space and trailing-dot behavior, and reserved
name semantics. Every external record must project to a distinct cache
publication path. Separately, #147 enumerates the extraction and link
destinations and rejects any two distinct planned filesystem objects that
project to the same host key. The sole intentional linker alias is two or more
packages exposing the exact same validated binary name in the same
`node_modules/.bin` directory. Those producers describe one logical output slot
and use the linker SPEC's deterministic v2 last-writer precedence. Distinct raw
binary names that merely become equivalent under host projection remain a
collision and are rejected. Every other cache, extraction, or link collision is
invalid before download, extraction, or linking, even when the structured
identities or UTF-8 path spellings differ. If the host semantics cannot be
represented conservatively, v2 replay fails closed. The cache projection and
verified-read rules are owned by `docs/specs/core/install/cache/SPEC.md`; #147
owns the extraction/link projection and layout, which this SPEC does not
redefine.

Each edge is a separate record whose six fields are all required:

- `source`: a root, workspace, or external identity;
- `requested_name`: the package name requested by that parent;
- `requested`: the exact selector text requested by that parent, including an
  empty string;
- `selector_kind`: exactly `empty`, `latest`, `dist-tag`, or `semver`,
  preserving the selection branch used during fresh resolution;
- `relationship`: exactly `direct`, `dev`, or `transitive`; and
- `target`: a workspace identity for a compatible local member, or an
  external identity containing the resolved name and version.

Root and member manifest requests use `direct` or `dev` according to their
manifest. Requests from an external package use `transitive`. The source
identity and requested fields remain distinct from the resolved target, so two
parents requesting different ranges can share one external target without
losing either request. A fresh writer records `selector_kind = "empty"` exactly
when `requested` is empty and `latest` exactly when the raw request is
`latest`; both follow the registry SPEC's default-selection branch. It records
`dist-tag` when any other non-empty request matched a key in the selected
packument's `dist-tags` map under the registry SPEC's tag-before-semver
precedence, including when the same text is also valid semver syntax. It records
`semver` only when the non-empty request did not use the default branch or match
a dist-tag and was selected through the semver facade. Selection may
canonicalize an empty selector to `latest`, matching current resolver behavior,
but the edge retains the raw empty text separately and the writer must not
serialize `latest` in its place.

Replay validates the recorded branch without consulting mutable registry
metadata. `empty` requires an empty `requested`; `latest` requires the exact raw
text `latest`; `dist-tag` requires other non-empty text and accepts the target
pinned during fresh resolution; `semver` requires a supported semver selector
whose target version satisfies that selector. A missing, unknown, or
text-inconsistent `selector_kind` is invalid.
This explicit discriminator prevents a semver-shaped dist-tag from being
reinterpreted as a range during replay. A local workspace target additionally
requires `selector_kind = "semver"`, because local member classification is
version-compatibility based. A local edge is valid only when it targets the
member selected by #145's compatible-version classification; an incompatible,
missing, or invalid member version is represented as an external target after
external resolution. An edge source must refer to an existing root, workspace,
or external package record. Its target must refer to an existing workspace or
external package record, and an external target must have exactly one matching
package record. `requested_name` must equal the target workspace record's name
or the target external identity's name. Exactly one edge is allowed for each
`(source, relationship, requested_name)` tuple. An exact duplicate or a second
edge with the same tuple and a different `requested` or `target` is invalid
rather than silently deduplicated. All edges sharing one realizable
`(source, requested_name)` link slot must have the same target. A root or member
may therefore retain distinct `direct` and `dev` edges, as required by #145,
only when both selectors resolve to that one target; conflicting production and
development targets are invalid before linking.

Starting from every root and workspace identity in `resolution_roots`, a reader
must traverse outgoing edges and reach every external package record. An
unreferenced external record, an external-only disconnected cycle, or any other
external component unreachable from all resolution roots is invalid. For an
edge whose `selector_kind` is `semver`, the selected workspace declared version
or external identity version must satisfy the recorded selector under
`docs/specs/core/semver/SPEC.md`. Edges classified as `dist-tag`, `latest`, or
`empty` are pinned to the target chosen during fresh resolution and do not
trigger mutable registry metadata lookup during replay. Invalid or unsupported
selector syntax and selector-kind mismatches remain load failures. These
path-safety, field-equality, uniqueness, reachability, selector/target,
referential-integrity, and
local/external-distinction rules are required before replay or mutation.

The smallest illustrative v2 shape is:

```toml
lockfile_version = 2
name = "app"
version = "0.1.0"

[[resolution_roots]]
origin = { kind = "root", path = "." }
manifest_path = "package.json"
name = "app"
declared_version = "0.1.0"

[[resolution_roots]]
origin = { kind = "workspace", path = "packages/a" }
manifest_path = "packages/a/package.json"
name = "a"
declared_version = "1.0.0"

[[external_packages]]
identity = { kind = "external", name = "lodash", version = "4.17.21" }
name = "lodash"
version = "4.17.21"
registry_origin = "https://registry.npmjs.org"
tarball = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"
integrity = "sha512-..."
scripts = {}

[[edges]]
source = { kind = "workspace", path = "packages/a" }
requested_name = "lodash"
requested = "^4.17.0"
selector_kind = "semver"
relationship = "direct"
target = { kind = "external", name = "lodash", version = "4.17.21" }
```

The example is a shape contract. It does not assert that the current runtime
can read or write these records.

#### Canonical ordering and deterministic replay

The v2 writer emits UTF-8 TOML with LF newlines and one final newline. Top-level
fields are emitted in this order: `lockfile_version`, `name`, optional
`version`, `resolution_roots`, non-empty `external_packages`, then non-empty
`edges`. `resolution_roots` are ordered root first, then member path in the
#145 stable order. The total identity order is root first, workspace identities
by path, then external identities by
`(name, version)`; string components use UTF-8 bytewise ascending comparison.
`external_packages` use that external `(name, version)` order. `edges` are
ordered by source identity, relationship rank `direct`, `dev`, `transitive`,
requested name, requested text, selector-kind rank `empty`, `latest`,
`dist-tag`, `semver`, and target identity using the same total identity order.
Identity fields are emitted in the order `kind`, `path` or `name`, then `version`.
Resolution-root fields use `origin`, `manifest_path`,
`name`, `declared_version`; external-package fields use `identity`, `name`,
`version`, `registry_origin`, `tarball`, `integrity`, `shasum`, `scripts`; edge
fields use the order shown in the example. Optional fields retain their listed
position when present. Every nested map, including `scripts`, is emitted with
UTF-8 bytewise ascending keys. Empty maps use `{}`. A serializer must not expose
HashMap iteration order. Consequently, serializing the same graph twice
produces byte-identical lockfiles, independent of filesystem enumeration,
registry timing, or map seeding.

#### Replay trust boundary

A v2 lockfile is executable supply-chain input because it selects archive URLs,
digests, dependency targets, and lifecycle scripts. The initial planned v2
schema carries no npm signature, transparency proof, or attestation for the
selected metadata tuple. A SHA-512 digest recorded in the same lockfile proves
only that the consumed archive bytes match that tuple after the tuple is trusted;
an attacker able to replace the lockfile can replace both archive URL and digest.

Locked replay therefore accepts only the exact lockfile byte snapshot that the
caller has established as reviewed trusted execution input, such as reviewed
source-controlled bytes from the trusted checkout or an equivalent explicit
user approval. File presence in the workspace, syntactic validity, a
self-consistent digest, or equality with the configured registry origin does not
establish that trust. A reader must bind the trust decision to the exact bytes it
parses; replacement or drift after approval makes the input ineligible. If the
caller cannot establish trust, RPM fails before network access, extraction,
scripts, or publication. A mode that is authorized to update may instead perform
fresh resolution over the configured HTTPS registry and produce a new candidate;
that is resolution, not replay, and the candidate becomes replay-eligible only
after the trust boundary above is satisfied. #155 owns mode selection and #224
owns enforcement in the v2 reader.

This boundary preserves no-refetch semantics. Trusted replay uses the recorded
targets and provenance without fetching mutable metadata. Untrusted input never
reaches replay, so no-refetch does not turn a self-authored lockfile tuple into a
registry-authenticated statement. Workspace lifecycle execution remains
disabled and is owned by #222. Before activation, #222 must define and prove how
the transaction keeps the pinned v2 candidate outside every hook capability and
detects candidate replacement or drift. This SPEC does not define a hook-visible
lockfile snapshot or authorize a hook to introduce a new URL, digest, graph
fact, or script and authenticate that change with its own fields.

On accepted v2 replay, the reader first discovers the current root/member table
and compares origin, manifest path, name, and declared version (including
omission) against the ordered recorded roots. It then derives current
`dependencies` and `devDependencies` requests from every root manifest and
compares their exact `(source, relationship, requested_name, requested)` tuples
with the recorded `direct` and `dev` edges. Root/member identity drift or direct
request drift makes the lockfile ineligible for replay. Locked replay must fail
before mutation and preserve the existing install state; it must not ignore the
drift or combine new selectors with recorded targets. A higher-level updating
install may instead perform a fresh deterministic resolution and atomically
publish a complete v2 replacement. #155 owns which CLI modes require replay or
permit that update and how they report drift.

After validation, replay uses the recorded edge target identities and exact
selected-version provenance; it does not rerun range or dist-tag selection.
Before extraction, cache replay must open a regular non-symlink entry relative
to the approved cache root with no-follow semantics, verify the recorded
SHA-512 SRI over the bytes of a stable open descriptor, pass that descriptor
through the external package-manifest identity gate, and then pass the same
descriptor to the extractor without a pathname reopen, as specified by the
cache SPEC. No archive entry is extracted before the identity gate succeeds.
Missing or duplicate records, unknown fields or identity kinds, malformed
fields, unsafe external path components, disallowed provenance URLs, absent
or unsupported SHA-512 integrity, shasum-only records, untrusted lockfile bytes,
archive-manifest identity mismatches, cache or linker projection collisions,
and equality, uniqueness, reachability, selector/target, or
referential-integrity failures are load failures before mutation.

V2 acceptance and publication also depend on filesystem boundaries owned by the
adjacent workspace issues. Before a v2 reader marks a decoded document
replay-eligible, or a fresh writer publishes one, #224 must consume successful
validation results bound to the exact immutable member table and edge set used
by that operation:

- #221 supplies the descriptor-validated member table, portable
  `member_path_key` identities, canonical-root confinement, and injective member
  path projection; and
- #147 supplies complete local/external package-name, requested dependency-name,
  extraction-destination, link-destination, and host-projection validation.

The #147 result must reject traversal, absolute, drive, UNC, device, unsupported
separator, reserved, trailing-space/dot, and host-equivalent collision cases for
every filesystem-driving name or destination. Its narrow exact-name `.bin`
precedence rule remains the only intentional shared output slot. Archive symlink
and hardlink confinement also belongs to #147's extraction/link staging
boundary; #222 must not expose an extracted package to lifecycle hooks until
that boundary has accepted it.

A syntactically valid v2 document, structurally non-empty local name, or
self-asserted validation flag is insufficient evidence. Missing, stale,
unsupported, or failed #221/#147 validation makes both replay and fresh v2
publication fail before cache or network access, extraction, linking, scripts,
lockfile publication, install publication, or any other live mutation. #224
must not replace either prerequisite with a weaker local name check. A reader
may decode inert fields only far enough to perform these validations; it must
return a load failure instead of exposing an accepted v2 graph when either
result is unavailable or fails. This SPEC records the consumer precondition and
does not duplicate the projection, archive-entry, or linker algorithms. #224
owns the v2 reader, writer, validator, replay, and migration implementation.

#### Migration and failure preservation

Migration from v1 to v2 is a fresh deterministic resolution that reconstructs
the #145 root/member table, per-parent edges, and external facts. It is not a
mechanical conversion of flattened v1 package entries. For a root-only project,
the current compatibility policy may keep the fresh result in v1; an explicit
v2 migration must still produce the complete v2 shape. For a workspace project,
v1 input always requires fresh resolution and v2 output. The old v1 file stays
byte-identical until the new v2 document is completely resolved, validated,
serialized, and atomically published. A resolution, validation, serialization,
or publication failure leaves the prior file intact. A v2 reader never silently
downgrades or discards workspace origins to produce v1.

Workspace lifecycle execution remains disabled and does not weaken this
migration boundary. #222 owns the future contract for prior-live visibility,
hook-inaccessible candidate state, post-hook validation, and failure recovery;
it must consume the v2 candidate produced by #224 without redefining its format
or graph. Until that contract and its fixtures land, no root, member, or external
workspace hook may run between v2 candidate creation and publication. This
lockfile SPEC defines neither a second hook-visible candidate snapshot nor a
post-hook merge, new resolution, or repeated-root-hook path.

## Error Cases

Malformed TOML, malformed lockfile fields, and save failures must be returned
with the lockfile path and parser or write context. Empty loading must not be
reported as successful dependency resolution.

## Test Fixtures

Lockfile verification should cover v1 format round-tripping, empty lockfile
initialization, malformed-file parse failures, and save truncation behavior.
Planned workspace snapshots must cover:

- root-only v1 semantic round-tripping and continued acceptance;
- a v2 document containing only its root, with omitted empty external-package
  and edge collections;
- a root plus two members in canonical root order;
- a compatible local edge;
- same-name incompatible member fallback to an external target;
- a member-only external edge;
- a raw empty selector preserved byte-for-byte with `selector_kind = "empty"`
  while selection uses `latest`, plus a semver-shaped request that matches a
  dist-tag and remains `selector_kind = "dist-tag"` on replay rather than being
  reinterpreted as semver;
- one shared external target reached through distinct requested ranges and
  origins;
- compatible direct and dev selectors from one source sharing a single target,
  plus conflicting direct/dev targets rejected before linking;
- distinct local and external identities with equal name and version text;
- top-level/root metadata mismatch, external identity/field mismatch, missing
  or empty registry origin or tarball, missing/empty/unsupported SHA-512
  integrity, shasum-only provenance, disallowed tarball
  scheme/origin/redirect, an external-only disconnected cycle, a
  selector/target version mismatch, malformed or unknown fields, and duplicate
  or conflicting edges;
- scoped-name acceptance plus rejection of traversal, backslash, drive, UNC,
  device, separator-bearing version, and cache or linker destinations colliding
  under host case-folding, Unicode-normalization, trailing-space/dot, or
  reserved-name semantics before filesystem mutation;
- a regular no-follow cache hit verified and extracted through one stable
  descriptor, plus symlink, special-file, pathname-swap, and concurrent-mutation
  cases rejected before extraction;
- selected registry metadata whose external facts, transitive requests, and
  scripts come from one version, plus rejection when the verified archive's
  `package.json` name, version, or scripts map differs, is absent or wrong-type,
  or is ambiguous, proving failure before extraction, hooks, or publication;
- reviewed trusted lockfile bytes accepted without metadata refetch, plus an
  otherwise valid untrusted or post-approval replaced lockfile rejected before
  network access or mutation;
- cross-contract #221/#147/#222 prerequisite fixtures with missing or failed
  validation results; local member names and requested dependency names that use
  traversal, unsupported separator, absolute, drive, UNC, device, reserved, or
  trailing-space/dot forms; local/local and local/external names that collide
  only after host case folding or Unicode normalization; and escaping archive
  symlink and hardlink entries, proving #224 blocks both replay and fresh v2
  publication before cache, network, extraction, linking, lifecycle hooks, or
  live mutation;
- root/member manifest request drift rejected before replay, plus a fresh
  replacement resolution that preserves the prior file on failure;
- v1-to-v2 migration and failure preservation without lifecycle execution,
  proving that a failed fresh resolution or publication preserves the prior v1
  file and only the fully validated v2 candidate can publish; #222 must define
  separate prior-live/candidate hook-visibility and recovery fixtures before
  workspace lifecycle activation;
- an unsupported future version rejected before record interpretation; and
- repeated canonical serialization producing identical bytes.

The mutable filesystem fixture for #149 remains outside this lockfile contract.
