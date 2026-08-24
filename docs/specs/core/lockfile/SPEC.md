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

An external package record requires `identity`, `name`, `version`, and
`scripts`; `tarball`, `integrity`, and `shasum` are optional. `identity` must be
an external identity whose `name` and `version` exactly equal the record fields.
If registry metadata supplies both integrity forms, both are preserved and
`integrity` remains authoritative for verification; `shasum` is the fallback
when `integrity` is absent. `scripts` is always present as a `string -> string`
map and is `{}` when the selected version has no lifecycle scripts. External
identities are unique. Dependency relationships are represented by `edges`,
not duplicated inside this package record. A package fact is written once even
when several parents reach the same name and version.
Local workspace members have no external package record and do not require a
tarball, integrity, or shasum.

Each edge is a separate record whose five fields are all required:

- `source`: a root, workspace, or external identity;
- `requested_name`: the package name requested by that parent;
- `requested`: the exact range or dist-tag text requested by that parent;
- `relationship`: exactly `direct`, `dev`, or `transitive`; and
- `target`: a workspace identity for a compatible local member, or an
  external identity containing the resolved name and version.

Root and member manifest requests use `direct` or `dev` according to their
manifest. Requests from an external package use `transitive`. The source
identity and requested fields remain distinct from the resolved target, so two
parents requesting different ranges can share one external target without
losing either request. A local edge is valid only when it targets the member
selected by #145's compatible-version classification; an incompatible,
missing, or invalid member version is represented as an external target after
external resolution. An edge source must refer to an existing root, workspace,
or external package record. Its target must refer to an existing workspace or
external package record, and an external target must have exactly one matching
package record. `requested_name` must equal the target workspace record's name
or the target external identity's name. Every external package record must be
the target of at least one edge; an unreferenced record is invalid. Exactly one
edge is allowed for each `(source, relationship, requested_name)` tuple. An
exact duplicate or a second edge with a different `requested` or `target` is
invalid rather than silently deduplicated. These
field equality, uniqueness, referential-integrity, and
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
tarball = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"
integrity = "sha512-..."
scripts = {}

[[edges]]
source = { kind = "workspace", path = "packages/a" }
requested_name = "lodash"
requested = "^4.17.0"
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
requested name, requested text, and target identity using the same total
identity order. Identity fields are emitted in the order `kind`, `path` or
`name`, then `version`. Resolution-root fields use `origin`, `manifest_path`,
`name`, `declared_version`; external-package fields use `identity`, `name`,
`version`, `tarball`, `integrity`, `shasum`, `scripts`; edge fields use the
order shown in the example. Optional fields retain their listed position when
present. Every nested map, including `scripts`, is emitted with UTF-8 bytewise
ascending keys. Empty maps use `{}`. A serializer must not expose HashMap
iteration order. Consequently, serializing the same graph twice produces
byte-identical lockfiles, independent of filesystem enumeration, registry
timing, or map seeding.

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
external resolved facts; it does not rerun range or dist-tag selection.
Missing or duplicate records, unknown fields or identity kinds, malformed
fields, and equality, uniqueness, or referential-integrity failures are load
failures before mutation.

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
- one shared external target reached through distinct requested ranges and
  origins;
- distinct local and external identities with equal name and version text;
- top-level/root metadata mismatch, external identity/field mismatch,
  malformed or unknown fields, and duplicate or conflicting edges;
- root/member manifest request drift rejected before replay, plus a fresh
  replacement resolution that preserves the prior file on failure;
- v1-to-v2 migration and failure preservation;
- an unsupported future version rejected before record interpretation; and
- repeated canonical serialization producing identical bytes.

The mutable filesystem fixture for #149 remains outside this lockfile contract.
