---
spec_id: package_manifest
title: Package Manifest
status: draft
owner: core/manifest
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
  - 127
  - 130
  - 133
  - 139
  - 141
  - 142
  - 145
  - 221
---

# Spec: Package Manifest

Status: Draft
Owner: core/manifest
Last reviewed: 2026-08-24

## Purpose

`package.json` is the project manifest contract for root dependencies, dev
dependencies, scripts, and project metadata used by install and add flows.

## Contract

An absent manifest is treated as an empty manifest so commands can initialize a
new project state.

A present manifest must be valid JSON matching RPM's supported manifest shape.
Package manifest parsing errors must be returned to callers with the manifest
path and parser context. Core package-manager code must not panic on invalid
manifest content.

Saving writes the complete current manifest and truncates old content. Save
errors must be returned to callers with the manifest path.

The full npm `package.json` schema is intentionally out of scope for this
contract today.

### Optional dependencies

RPM reads and preserves the root `optionalDependencies` map (`package name` to
`range`) when it is present. Preserved entries are not consumed by install, add,
or resolution today: they are not enqueued as dependency requests, they do not
influence version selection, and they do not appear in the resolved graph,
lockfile, or linked `node_modules`. A manifest that omits
`optionalDependencies` behaves identically to one without it.

This read-and-preserve baseline makes RPM honest about a field it accepts today.
The full optional-aware behavior (resolve the entry as an ordinary dependency,
attempt install, skip on failure, and report the outcome) is intentionally
deferred until an optional-aware strategy SPEC owns it. The reserved failure
policy for that future strategy — skip-and-warn on resolution, download, and
install failures, skip-silently on platform mismatch, record only successful
installs — is owned by `docs/specs/core/resolver/SPEC.md`, with the lockfile
recording policy owned by `docs/specs/core/lockfile/SPEC.md`. Until then, a
non-optional-aware strategy must not silently enqueue optional dependencies as
ordinary dependencies; that non-enqueue guard is owned by
`docs/specs/core/resolver/SPEC.md`. Per-version
`optionalDependencies` on registry packuments remain ignored at the registry
boundary (`docs/specs/core/registry/SPEC.md`).

### Peer dependencies

RPM reads and preserves the root `peerDependencies` map (`package name` to
`range`) when it is present. Preserved entries are not consumed by install, add,
or resolution today: they are not enqueued as dependency requests, they do not
influence version selection, and they do not appear in the resolved graph,
lockfile, or linked `node_modules`. A manifest that omits `peerDependencies`
behaves identically to one without it.

This read-and-preserve baseline makes RPM honest about a field it accepts today.
The full peer-aware behavior (peer-requirement resolution, peer-set enforcement,
and peer-conflict diagnostics) is intentionally deferred until a peer-aware
strategy SPEC owns it. Until then, a non-peer-aware strategy must not silently
enqueue peer dependencies as ordinary dependencies; that non-enqueue guard is
owned by `docs/specs/core/resolver/SPEC.md`, which also owns the *shape* of
peer-requirement diagnostics (issue #135) — the active emission remains gated
on a peer-aware strategy. Per-version `peerDependencies` on registry packuments
remain ignored at the registry boundary
(`docs/specs/core/registry/SPEC.md`).

### Engines, OS, and CPU metadata

RPM reads and preserves the root `engines`, `os`, and `cpu` fields when they
are present, using npm-accurate types (`engines` as a `name -> range` map;
`os` and `cpu` as arrays whose entries may be negated, for example `!win32`).
Preserved values are not consumed by install, add, or resolution today: RPM
performs no engine, OS, or CPU filtering, warning, skip, or failure. They do
not influence version selection, the resolved graph, the lockfile, or linked
`node_modules`. A manifest that omits any of these fields behaves identically to
one without it.

This read-and-preserve baseline makes RPM honest about fields it accepts today
and keeps a real npm-shaped manifest from failing parsing. The full
platform-gating behavior (filter candidates, warn on mismatch, skip install, or
fail) is intentionally deferred until a platform-gating strategy SPEC owns it.
Until then, a non-platform-aware strategy must treat platform incompatibility as
a non-failure: platform metadata must not block resolution, download,
verification, extraction, linking, lockfile, or manifest output. Per-version
`engines`, `os`, and `cpu` on registry packuments remain ignored at the registry
boundary (`docs/specs/core/registry/SPEC.md`).

### Bin field

RPM reads the root `bin` field when it is present and accepts both npm-defined
forms:

- **String form:** `"bin": "./cli.js"` exposes a single binary. For an unscoped
  package the binary name is the package `name`; for a scoped package
  (`@scope/name`) the binary name is the unscoped name (`name`).
- **Object form:** `"bin": { "<name>": "<target>", ... }` exposes one binary
  per map key. The keys are used verbatim as binary names; the scope prefix is
  neither added nor stripped from object-form keys.

A present-but-wrong-type `bin` value (for example a number or an array) is
discarded as absent during deserialization rather than failing the manifest,
mirroring the lenient handling used for other preserved fields. A well-typed
value round-trips into `Some(...)`.

The read `bin` entries do not influence resolution, version selection, the
resolved graph, or the lockfile. They are consumed by exactly one downstream
behavior: the linker's `node_modules/.bin` generation
(`docs/specs/core/linker/SPEC.md`). Until that generation runs, a `bin` entry
has no install side effect. A manifest that omits `bin` behaves identically to
one without it: no `.bin` entries are produced for that package.

The root package `bin` field is preservation-only at this boundary: the root
package is not a resolved package and has no installed directory under
`node_modules/`, so the linker does not generate a `.bin` link for the root
project itself. The linker consumes `bin` only from resolved (installed)
packages. Reaching the root project's own declared binaries at runtime is owned
by `rpm run` and its PATH policy (`docs/specs/cli/run/SPEC.md`, issue #143),
not by `.bin` generation.

A `bin` target that names a path outside the package directory (after symlink
and `..` normalization) is rejected as a link input error by the linker, not
silently followed. This keeps `.bin` generation from becoming a traversal
vector; the traversal guard is owned by the linker contract. An object-form
`bin` key that is not a single path component (absolute, separator-containing,
parent-referencing, or empty) is likewise rejected by the linker before any
`.bin` entry is written; see `docs/specs/core/linker/SPEC.md`.

### Scripts field

RPM reads and preserves the root `scripts` map when it is present, using
npm-accurate type (`string -> string`). Values are preserved verbatim; RPM does
not rewrite, validate, or canonicalize script text. A present-but-wrong-type
`scripts` value (for example a string, an array, or a map whose values are not
strings) is discarded as absent during deserialization rather than failing the
manifest, mirroring the lenient handling used for other preserved fields. A
single non-string value drops the entire `scripts` map, not just the offending
entry, matching the per-version registry boundary's whole-map drop semantics
(`docs/specs/core/registry/SPEC.md`). A well-typed value round-trips into
`Some(...)`. A manifest that omits `scripts` behaves identically to one without
it.

The manifest boundary owns reading and preserving `scripts` only. The read
entries do not influence resolution, version selection, the resolved graph, or
the lockfile. They are consumed by two distinct downstream behaviors, each with
its own contract:

- **`rpm run`** reads the root manifest's `scripts` map to execute a
  user-named script on demand. Running a script must not reinstall or mutate
  install output (`docs/specs/cli/run/SPEC.md`). Any script name is reachable
  through `rpm run`, not only the lifecycle names below.
- **Install lifecycle execution** reads the recognized lifecycle hooks from the
  `scripts` map and runs them as an install phase. The supported install
  lifecycle hook names are exactly `preinstall`, `install`, `postinstall`, and
  `prepare`. Every other `scripts` entry is preserved but never invoked during
  install. The active lifecycle execution contract — ordering, environment,
  PATH, failure behavior, and the invariant that a failed script phase cannot
  publish partial successful install state — is owned by
  `docs/specs/core/install/scripts/SPEC.md` (#141).

Per-version `scripts` on registry packuments are read and preserved at the
registry boundary (`docs/specs/core/registry/SPEC.md`) under the same
`string -> string` shape and the same wrong-type tolerance, and feed the same
lifecycle execution contract for resolved packages.

### Workspace declaration and discovery (planned)

This subsection defines the contract for the first workspace-aware manifest
and discovery implementation. RPM does not currently deserialize or preserve
the `workspaces` field and has no workspace discovery API, so the rules below
are an implementation target rather than a claim about the current root-only
code path. The implementation that activates this contract must land with the
planned fixtures in this section.

The root manifest may declare workspace members through the `workspaces` field.
RPM supports exactly these declaration shapes:

- a non-empty array containing only non-empty strings, each interpreted as a
  relative member glob;
- an object whose `packages` value is a non-empty array containing only
  non-empty strings, interpreted the same way as the array form.

An empty array in either supported shape is an invalid declaration. It does not
mean root-only; only an absent `workspaces` field has that meaning.

Workspace patterns use a portable RPM dialect. `/` is the only path separator
and every segment must be non-empty. `*` matches zero or more non-`/`
characters within one segment, while `**` is supported only as a complete
segment and matches zero or more descendant segments. Wildcards do not match a
segment whose first character is `.`; a non-excluded dot-prefixed segment must
be named literally. Brace expansion, character classes, `?`, extglobs,
negation with `!`, and backslash escaping or separators are unsupported, and a
pattern containing those forms is an invalid declaration. Portable validation
is lexical and runs before host path parsing: a leading `/`, an ASCII drive
prefix matching `[A-Za-z]:`, and every backslash-qualified UNC or device form
are absolute or platform-qualified and invalid on every host. Implementations
must not delegate this decision to the current operating system's path parser.

Pattern matching is host-independent and case-sensitive. RPM decodes both each
JSON pattern segment and each enumerated native directory-entry component to
Unicode scalar values, then compares literal scalars for exact equality. `*`
matches a sequence of zero or more Unicode scalars within one component; `**`
applies the same scalar model across complete components. Matching performs no
locale collation, case folding, or Unicode normalization, so case variants and
canonically equivalent composed/decomposed spellings remain distinct at this
boundary. NFC normalization occurs only when a successfully matched path becomes
a `member_path_key`. RPM must enumerate entries and apply this matcher instead of
delegating literal or wildcard matching to host glob or case-insensitive path
lookup behavior.

The object form does not implicitly enable npm- or Yarn-specific workspace
options. Unsupported object keys and every other `workspaces` value type are
invalid declarations and must produce an input error that names the manifest
path, the `workspaces` field, and the reason. A missing `workspaces` field means
that the project is root-only. Nested `workspaces` declarations in a member
manifest are not recursively discovered by this contract.

For workspace discovery, the root `package.json` is opened descriptor-relative
to the canonical project-root directory with no symlink following. The path
itself must be a regular, non-symlink file, and its pre-open native identity must
match the opened descriptor. Discovery pins that descriptor identity, exact
bytes, and permissions and parses one immutable root snapshot containing at
least `name`, `version`, `scripts`, `dependencies`, `devDependencies`, and
`workspaces`. The declaration is read from this snapshot.

The root snapshot and member table form one discovery result. Resolver seeding,
workspace staging, and root lifecycle-script selection consume that result and
must not reopen the live root manifest by path. The live root descriptor/native
identity is filesystem-validation state only. Immediately before any workspace
publication, while holding the cooperative per-workspace RPM lock and following
the guarded descriptor protocol in
`docs/specs/core/install/recovery/SPEC.md`, the transaction verifies through the
retained descriptor and a descriptor-relative no-follow lookup that the live root
manifest still has the pinned identity, exact bytes, and permissions. Detected
replacement or byte/mode drift fails before the next backup or publication step.

Each workspace pattern is normalized relative to the canonical project root
before expansion. Absolute patterns, patterns that can escape through `..`, and
matched member paths whose resolved symlink target is outside the canonical
root are rejected before a discovery result is returned.

Glob expansion distinguishes traversal directories from member candidates.
Directories consumed only while a `**` segment matches zero or more descendant
segments are traversal nodes; a traversal node without a direct `package.json`
entry is incidental and is not an error. A directory selected by a terminal
literal or `*` segment is an explicit match and must contain a direct
`package.json` entry. A pattern must produce at least one member candidate after
this distinction or the declaration is invalid. This lets `packages/**` pass
through `packages`, member subdirectories, and source subdirectories without
treating each directory as a package, while a misspelled explicit member path
still fails.

The expansion walker inspects directory-symlink entries but never descends
through them. A symlink path that the complete pattern selects is a terminal
member candidate only when it canonicalizes to a directory inside the canonical
root. Its descendants are not discovered through that link. A dangling link, a
symlink cycle, an outside-root target, or any other canonicalization failure on
a selected symlink is an invalid declaration. This rule is independent of the
filesystem walker's default symlink policy.

Before opening a candidate manifest, discovery canonicalizes the candidate's
direct `package.json` path and requires the candidate path itself to be a
regular, non-symlink file inside both the canonical member directory and the
canonical project root. A dangling or cyclic manifest link, a non-file target,
or any manifest link that resolves outside either boundary is rejected without
reading the target. A malformed candidate manifest or a member path equal to
the root is also an invalid workspace declaration. Discovery must not read or
write a manifest outside the canonical root.

The candidate manifest read uses a descriptor-relative, no-follow open rooted
at the canonical member directory, followed by `fstat`-equivalent identity and
confinement checks. The no-follow pre-open identity must match the opened
descriptor's regular-file type and identity, and the descriptor must remain
inside both the canonical member directory and project root. A path swap,
identity mismatch, or platform without an atomic equivalent for this operation
fails the entire discovery before the candidate bytes are read; discovery must
not fall back to a path-based open.

Both root and member manifest descriptors must report exactly one filesystem
link (`st_nlink == 1`) or a platform-equivalent atomic guarantee that no second
pathname aliases the opened file identity. A hard-linked manifest is invalid
even when every known link is inside the canonical root, because an unobserved
alias could mutate the validated bytes. If the platform cannot obtain the link
count or an equivalent guarantee from the opened descriptor, workspace
discovery fails closed before reading or returning manifest data.

Directory traversal uses descriptor-relative, no-follow directory handles for
every enumeration and metadata operation, or an atomic equivalent with the
same identity and root-confinement guarantees. Before and after each traversal
operation, the directory handle identity must still represent the expected
root-relative directory. A directory replacement, identity mismatch, or
platform without a supported equivalent fails the entire discovery; discovery
must not continue from a path-based handle or return a partial member table.

Discovery fails closed on every filesystem I/O error that can affect the
member table. This includes directory enumeration, directory or candidate
metadata/stat, symlink resolution or canonicalization, and reading a candidate
manifest. The implementation must discard any partial result and return one
error instead of skipping the affected path. The error names the failed
operation and a safe path relative to the canonical root; it must not expose a
host-absolute path or continue with an incomplete workspace set.

Expansion considers descendant directories only and prunes install artifacts
before matching. A path at or below any `node_modules` or `.rpm` component, or
at or below an RPM-managed cache, store, staging, or backup path, is never a
workspace candidate. Current root-local managed paths include `.rpm/**`,
`.node_modules.rpm-staging-*`, and `.node_modules.rpm-backup-*`. These
exclusions are applied again after symlink resolution, so an explicit pattern
or in-root symlink cannot opt an artifact tree into discovery.

Discovery serializes each member path into a portable `member_path_key`. Every
native path component must decode losslessly to Unicode scalar values; an
unpaired surrogate, invalid UTF-8 byte sequence, or any other non-Unicode
component makes the declaration invalid. Each component is normalized to
Unicode NFC, the normalized components are joined with the literal `/`
character, and the result is encoded as UTF-8. Discovery performs no locale
collation or case folding. It deduplicates and sorts keys by unsigned UTF-8 byte
order. Two distinct validated filesystem identities that serialize to the same
key are an ambiguous declaration and are rejected instead of being silently
deduplicated. Filesystem access continues through the descriptor-validated
native identity captured during discovery; an implementation must not reopen a
member by reparsing the serialized key.

Discovery also retains the exact descriptor-relative native component chain and
parent-directory identities that produced each key. The chain is filesystem
validation state and must serialize to that row's `member_path_key`; it is not a
second graph identity. Staging and lifecycle validation consume this retained
parent/name mapping instead of reconstructing a host path from the portable key.

This serialization makes member order independent of host path representation,
filesystem enumeration order, and locale, including for non-ASCII names.
Every discovered member must have a non-empty package name accepted by the
resolver's current structural package-name rule; discovery must not introduce
stricter npm name-syntax checks. Duplicate member package names are rejected as
an ambiguous declaration.

Each member-table row carries the `member_path_key`, the descriptor-validated
native member identity and parent/name mapping, and one immutable parsed snapshot
from the same descriptor-validated manifest read. The snapshot includes every
supported manifest field, including package name, declared version text,
`dependencies`, `devDependencies`, and `scripts`. Resolution consumes dependency
declarations from this snapshot and must not perform a second path-based
member-manifest read between discovery and request seeding. Later workspace
phases either consume the same snapshot or apply their owning transaction's
explicit identity check; they must not silently substitute bytes from a path
that changed after discovery.

The root package, a discovered workspace member, and an external package are
distinct identities. The root is the manifest that owns the declaration. A
workspace member is identified for graph/origin purposes by its validated
portable `member_path_key` and package name and carries its declared version for
edge classification. Its native canonical path and native file/directory
identities are retained only for descriptor-rooted filesystem access and
validation; they must not become resolver graph identity or origin. An external
package is reached through an edge that the resolver cannot satisfy from a
compatible discovered member. The resolver owns that classification; lockfile
records, local linking, and command targeting remain owned by the contracts for
issues #146, #147, and #148.

Reading and saving a root manifest must preserve a valid `workspaces`
declaration without changing its supported shape, patterns, or pattern order.
If a manifest writer cannot preserve the declaration, it must fail before
truncating or replacing the existing file rather than silently dropping
workspace configuration. Discovery and validation errors occur before install
or manifest mutation side effects.

## Error Cases

Invalid JSON is an input error and must not be reported as a successful command.
File write, create, and serialization failures must not be hidden behind
panics.

## Test Fixtures

Manifest fixtures live under `tests/fixtures/package_manifest/`.

Workspace discovery fixtures must remain deterministic and offline. The
workspace contract requires planned coverage for:

- a simple root with two workspace packages;
- the array declaration and the object `{ "packages": [...] }` declaration;
- a root-only project with no `workspaces` field;
- malformed, unsupported, wrong-type, `[]`, and `{ "packages": [] }`
  declarations, proving only a missing field is root-only;
- supported `*` and `**` patterns plus rejected brace, character-class,
  negation, escape, platform-separator, drive-qualified (`C:/...` and
  `C:\\...`), UNC, and device-path forms on every host;
- literal and wildcard patterns over ASCII case variants, non-ASCII case
  variants, Turkish dotted/dotless I, and composed/decomposed spellings, proving
  exact Unicode-scalar matching returns identical results on simulated
  case-sensitive and case-insensitive hosts without locale or normalization;
- `packages/**` over ordinary intermediate and source directories, proving
  zero-segment and descendant traversal nodes without `package.json` are
  ignored while direct member candidates are returned;
- a declaration whose pattern matches no member path;
- a member without a valid `package.json`;
- `..` or absolute path escape attempts;
- an in-root directory-symlink member whose descendants are not traversed, a
  directory-symlink cycle that fails without traversal, and a symlink whose
  resolved target is outside the canonical root;
- an in-root member whose direct `package.json` is a symlink (including one
  resolving outside the member or canonical root) and is rejected before the
  target is read;
- injected walker/fake-filesystem failures for directory enumeration, metadata,
  symlink resolution/canonicalization, and candidate manifest reads, proving
  each error names the operation and safe root-relative path and returns no
  partial member table;
- an injected descriptor-relative validate-open path swap and identity mismatch,
  including a platform without an atomic equivalent, proving the candidate
  target is not read and the full discovery fails without a partial table;
- a root-manifest replacement between discovery and resolver/staging plus a
  second replacement immediately before publication, proving every consumer
  uses the immutable root snapshot and final identity/bytes/permissions
  validation fails before overwriting the replacement;
- root and member `package.json` files hard-linked to an external alias, plus an
  injected platform without descriptor link-count support, proving discovery
  rejects each case before parsing or returning a snapshot;
- an injected directory replacement during descriptor-relative enumeration or
  metadata validation, proving the traversal identity mismatch fails the full
  discovery without a partial table;
- a broad pattern with pre-existing `node_modules`, `.rpm`, and RPM-managed
  staging or backup paths, proving artifacts do not change discovery;
- overlapping declarations proving sorted, deduplicated root-relative output;
- composed and decomposed non-ASCII member names plus CJK member names, proving
  NFC `member_path_key` serialization and unsigned UTF-8 byte ordering produce
  the same order on every host; an injected non-Unicode native component and a
  normalized-key collision are rejected without a partial table;
- equivalent POSIX and Windows native component sequences, proving both
  serialize to the same `/`-separated `member_path_key` without leaking `\` or
  drive spelling into graph identity; a literal backslash in a declaration
  remains invalid under the portable glob grammar;
- an injected member-manifest replacement after discovery but before resolver
  seeding, proving dependencies and development dependencies come from the
  descriptor-validated snapshot and the replacement path is not reopened;
- a structurally accepted non-empty member name that is preserved without a
  discovery-only npm syntax gate;
- duplicate workspace package names; and
- a save attempt proving the declaration is preserved or fails before file
  replacement.

The minimal mutable two-package install fixture, expected lockfile, and
expected filesystem tree are owned by issue #149 and must not be added to this
manifest contract change.
