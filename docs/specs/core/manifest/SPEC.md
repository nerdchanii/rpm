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
Manifest parsing must reject more than one top-level `workspaces` key and more
than one `packages` key inside the `workspaces` object before a generic JSON
representation can discard the duplicate. A parser's first-key or last-key
selection behavior must not determine the discovered member set.

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

Pattern matching is host-independent and case-sensitive. RPM decodes each JSON
pattern segment and each enumerated native directory-entry component losslessly
to Unicode scalar values. A literal segment matches when its complete NFC form
equals the candidate component's complete NFC form. A segment containing `*`
matches when some sequence of Unicode scalars substituted for each wildcard
makes the complete materialized segment NFC-equal to the complete candidate
component; this whole-result rule also applies when a wildcard falls between a
base scalar and a combining scalar. `**` retains its complete-component meaning
across path segments. Matching performs no locale collation or case folding, so
case variants remain distinct while canonically equivalent composed/decomposed
spellings match. For an ordinary directory candidate the candidate's normalized
root-relative components later form the `member_path_key`; a selected directory
symlink uses the canonical-target rule below. RPM must enumerate entries and
apply this matcher instead of delegating literal or wildcard matching to host
glob, host Unicode normalization, or case-insensitive path lookup behavior.

The object form does not implicitly enable npm- or Yarn-specific workspace
options. Unsupported object keys and every other `workspaces` value type are
invalid declarations and must produce an input error that names the manifest
path, the `workspaces` field, and the reason. A missing `workspaces` field means
that the project is root-only. Nested `workspaces` declarations in a member
manifest are not recursively discovered by this contract.

For workspace discovery, RPM first opens the canonical project-root directory
descriptor-relative from its retained canonical parent/name chain without
following links. Every parent identity and the root directory's pre-open native
identity must match the opened descriptor; a rename, replacement, mount/reparse
substitution, or platform without an atomic equivalent fails before a manifest
is read. Discovery retains the root directory descriptor, identity, and exact
parent/name chain as filesystem-validation state. On Linux, the global
descriptor-scoped watcher is initialized before the root is opened. Starting at
the outermost retained ancestor anchor, discovery opens and validates each
ancestor descriptor, installs its watch through the descriptor's
`/proc/self/fd/<dirfd>` path, and only then opens the next child in the retained
parent/name chain. Every ancestor watch remains installed through root open,
root manifest lookup, complete member discovery, and the single final
linearization cut below. The root directory watch is installed on the retained
root descriptor before any root `package.json` lookup, open, or read, including
the absent-manifest case. Watch setup and the initial queue drain must succeed
before any manifest operation.

When the root `package.json` is absent, discovery follows the existing manifest
initialization contract: it returns one immutable empty root snapshot and an
empty member table, with no `workspaces` declaration to expand. It does not
invent a manifest file or fail merely because the file is absent. Workspace
discovery is fully read-only: it performs no exclusive creation, replacement,
truncation, or other manifest mutation, and it does not invoke an initializer.
Workspace-aware absent-root creation remains disabled and deferred to #222,
which must prove a root-bound publication primitive before enabling it. A later
root-only flow may apply its own owning initialization contract, but it is not a
workspace-discovery consumer; a concurrently created entry is observed by a
fresh read and is never overwritten or replaced by this discovery.

When the root `package.json` is present, it is opened descriptor-relative to
that retained project-root descriptor with no symlink following. The path
itself must be a regular, non-symlink file, and its pre-open native identity must
match the opened descriptor. Discovery pins that descriptor identity, exact
bytes, permissions, and single-link guarantee and parses one immutable root
snapshot. Obtaining the exact bytes requires either a platform-provided stable
file snapshot or two complete descriptor reads from offset zero with unchanged
identity, link count, size, permissions, and content-change metadata before,
between, and after the reads; both reads must be byte-identical. Any detected
in-place mutation, unstable byte sequence, or platform unable to provide one of
these stable-read guarantees fails discovery before parsing. The snapshot
contains at least `name`, `version`, `scripts`, `dependencies`,
`devDependencies`, and `workspaces`. The declaration is read from this snapshot.

The root snapshot and member table form one read-only discovery result. Resolver
seeding and other consumers of workspace discovery use that result and must not
reopen or publish the live root manifest by path. This contract does not
authorize truncation, replacement, or any other write to a present root
manifest after workspace discovery. Existing root-only flows that do not
consume workspace discovery remain governed by their owning contracts.
Workspace-aware manifest mutation and lifecycle adoption remain disabled and
are owned by #222, which must select and prove a publication primitive supported
by the target platform before enabling either behavior. The retained root
descriptor and native identity are validation state for read-only consumers.

Each workspace pattern is normalized relative to the canonical project root
before expansion. Absolute patterns, patterns that can escape through `..`, and
matched member paths whose resolved symlink target is outside the canonical
root are rejected before a discovery result is returned.

Glob expansion distinguishes traversal directories from member candidates.
Directories consumed by a non-terminal `**` segment are traversal nodes; a
traversal node without a direct `package.json` entry is incidental and is not an
error. A terminal `**` evaluates the zero-segment directory and every descendant
directory it visits: each directory with a direct `package.json` entry becomes
a member candidate, while each directory without one remains incidental. When
the zero-segment result is the canonical project root itself, it remains the
already-known root package and is skipped rather than promoted to a member. A
directory selected by a terminal literal or `*` segment is an explicit match
and must contain a direct `package.json` entry; an explicit selection equal to
the project root remains invalid. A pattern must produce at least one member
candidate after this distinction or the declaration is invalid. This lets
`packages/**` discover package directories at any depth while passing through
`packages` and ordinary source directories without treating them as packages,
and a misspelled explicit member path still fails.

The expansion walker inspects directory-symlink entries but never descends
through them. A symlink path that the complete pattern selects is a terminal
member candidate only when it canonicalizes to a directory inside the canonical
root. Its descendants are not discovered through that link. A dangling link, a
symlink cycle, an outside-root target, or any other canonicalization failure on
a selected symlink is an invalid declaration. For an accepted directory-symlink
candidate, the `member_path_key` is derived from the canonical target's
root-relative native component chain, not from the glob-visible symlink path.
Selecting the same canonical directory through its target path and one or more
aliases therefore produces one member identity and one key. This rule is
independent of the filesystem walker's default symlink policy.

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
not fall back to a path-based open. The same stable-snapshot or repeated
byte-identical descriptor-read rule used for the root manifest applies to every
member manifest, so an in-place write cannot produce a mixed snapshot.

Every present root or member manifest descriptor must report exactly one
filesystem link (`st_nlink == 1`) or a platform-equivalent atomic guarantee that
no second pathname aliases the opened file identity. A hard-linked manifest is
invalid even when every known link is inside the canonical root, because an
unobserved alias could mutate the validated bytes. If the platform cannot obtain
the link count or an equivalent guarantee from the opened descriptor, workspace
discovery fails closed before reading or returning manifest data.

Directory traversal uses descriptor-relative, no-follow directory handles for
every enumeration and metadata operation, or an atomic equivalent with the
same identity and root-confinement guarantees. Before and after each traversal
operation, the directory handle identity must still represent the expected
root-relative directory. Traversal must not cross a descendant mount, bind
mount, volume, or non-symlink reparse boundary: every opened descendant and
every canonical target chain must retain the root's mount/volume identity, with
a no-cross-device/mount primitive or platform equivalent that detects bind
mounts even when ordinary device numbers are equal. Each directory enumeration
must also provide a stable entry-set snapshot spanning the complete enumeration
and final pre-return validation. Workspace discovery treats the root manifest
snapshot and the member table as one result, so all of those operations share
one global watcher and final linearization cut.

On Linux, the supported primitive is descriptor-scoped inotify revalidation.
Discovery creates one nonblocking inotify descriptor before walking the
retained root parent/name chain. For each ancestor edge, it installs a watch
through the already validated ancestor's `/proc/self/fd/<dirfd>` path before
opening the next child. After the validated root descriptor is opened, it
installs the root directory watch before looking up the root manifest. Before
every first read from a newly opened descendant directory, it installs that
directory's watch through its retained descriptor path. After each root or
member manifest descriptor is opened and its no-follow identity, link count,
and confinement are checked, discovery installs an inode-bound watch through
`/proc/self/fd/<manifestfd>` before the first byte read. All ancestor,
root/member directory, and root/member manifest watches remain installed, and
their descriptors remain open, through root-manifest lookup and stable reads,
the complete descriptor-relative walk, candidate-manifest reads, and final
identity/metadata checks.

The queue-drain operation owns the inotify descriptor and follows one exact
nonblocking loop: (1) read repeatedly until `EAGAIN`, requiring every returned
buffer to contain complete event records; (2) call `poll` with a zero timeout;
(3) return a quiet result only when `poll` reports no readable event, otherwise
return to step 1. Each drain invocation has fixed starvation bounds:
`DRAIN_EVENT_BUDGET = 4096` complete event records, `DRAIN_BYTE_BUDGET =
1_048_576` bytes returned by `read`, and `DRAIN_TIME_BUDGET = 10 ms` measured
by a monotonic clock from invocation start. Every complete record, including an
unrelated ancestor entry, counts toward both the event and byte budgets; the
counters are not reset by a successful read or by ignoring an unrelated event.
The implementation checks the monotonic deadline before each read or poll and
after each such call. Reaching or exceeding any budget fails closed before a
quiet result can be returned; a clock failure also fails closed. These budgets
bound drain work and do not establish quiet by elapsed time. If that readable
poll is followed by `EAGAIN` again, it is a readiness/read retry; three
consecutive such retries (`DRAIN_RETRY_LIMIT = 3`) fail closed, and any
successful event read resets the retry count. A zero-return `poll` with
`revents == 0` is the only quiet result. A nonzero
`poll` return is accepted only when `revents == POLLIN` exactly; `POLLERR`,
`POLLPRI`, `POLLHUP`, `POLLNVAL`, any unknown bit, any of those bits combined
with `POLLIN`, or an inconsistent return/revents pair fails closed. Inotify
setup/watch failure, read error or EOF, malformed or partial event record, or
unavailable `/proc/self/fd` resolution also fails closed. No sleep or time-based
quiet period is allowed. The initial root drain must return quiet before the
root manifest operation. Drains at the root snapshot boundary, after each
directory enumeration, and after final validation must each return quiet. The
final validation rechecks every retained ancestor parent/name edge, root/member
directory identity, and root/member manifest identity, link count, size,
permissions, and content-change metadata before the last drain. Any
role-relevant mutation event observed by a retained watch fails the full
discovery; unrelated ancestor entries remain drain-only events after their
complete records are parsed, subject to the per-attempt event, byte, and
monotonic-time budgets above. The last quiet result after all final checks is
the single global linearization cut.
The adapter must provide a documented ordering guarantee that every watched
mutation completed before that cut has a queued event; when the filesystem or
kernel adapter cannot provide that guarantee, discovery fails closed.

The queue parser binds each watch descriptor to its role. For a root or member
directory watch, `IN_CREATE`, `IN_DELETE`, `IN_MOVED_FROM`, `IN_MOVED_TO`,
`IN_ATTRIB`, `IN_MODIFY`, `IN_CLOSE_WRITE`, `IN_DELETE_SELF`, `IN_MOVE_SELF`,
or `IN_UNMOUNT` affecting the watched entry set fails the full operation. For
an ancestor-chain watch, the same events fail when they affect the tracked
child component or the watched directory itself; unrelated ancestor entries
are drained and ignored after their complete records are parsed. For a
root/member manifest inode watch, `IN_ATTRIB`, `IN_MODIFY`, `IN_CLOSE_WRITE`,
`IN_DELETE_SELF`, `IN_MOVE_SELF`, or `IN_UNMOUNT` on that exact inode fails,
including link-count changes and writes made through an outside hard-link alias.
`IN_Q_OVERFLOW`, `IN_IGNORED`, or any other queue-loss/watch-loss event fails
globally. The event is a drift signal even when later events restore the earlier
names; discovery never interprets the event stream as a replacement entry set.
Before the global cut, every retained root/member manifest descriptor is rechecked
for identity, link count, size, permissions, and content-change metadata; any
difference fails before the result is returned. A mutation delivered after the
final cut belongs to a later filesystem state and is outside the returned
snapshot. Before a consumer accesses an enumerated member again, its retained
parent/name and descriptor identity must still validate; a missing or replaced
selected entry fails that consumer operation. A fixed delay or repeated equal
enumeration does not establish stability. Linux without the descriptor-scoped
watch, a readable lossless queue, an exact inode-bound manifest watch, or the
required `/proc/self/fd` resolution fails closed. Other hosts require an atomic
enumeration snapshot, a reliable monotonic directory-content generation, or an
equivalent lossless watcher/revalidation primitive; a platform without one
fails the entire discovery. A directory replacement, mount/reparse crossing,
identity mismatch, entry-set mutation, manifest link-count/content drift, or
watch loss must never continue from a path-based handle or return a partial
member table.

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
ASCII reserved component names and prefixes are compared case-insensitively on
every host, so aliases such as `NODE_MODULES` and `.RPM` are
pruned consistently. These exclusions are applied again after symlink
resolution, so an explicit pattern or in-root symlink cannot opt an artifact
tree into discovery.

Discovery serializes each member's canonical-target root-relative path into a
portable `member_path_key`. Every native path component must decode losslessly
to Unicode scalar values; an unpaired surrogate, invalid UTF-8 byte sequence,
or any other non-Unicode
component makes the declaration invalid. Lossy `OsStr` conversion, replacement
characters introduced by such conversion, WTF-8, and host-private surrogate
encodings are not accepted. Each component is normalized to Unicode NFC, the
normalized components are joined
with the literal `/` character, and the result is encoded as valid UTF-8. The
complete key must decode and re-encode byte-for-byte under the same rule on
every supported host. Discovery rejects a native component or completed key
that cannot satisfy this portable round trip before returning any member table
or handing input to the resolver. Discovery performs no locale collation or
case folding. It deduplicates and sorts keys by unsigned UTF-8 byte order. Two
distinct validated filesystem identities that serialize to the same key are an
ambiguous declaration and are rejected instead of being silently deduplicated.
Filesystem access continues through the descriptor-validated native identity
captured during discovery; an implementation must not reopen a member by
reparsing the serialized key.

Discovery also retains the exact canonical-target, descriptor-relative native
component chain and parent-directory identities that produced each key. For a
directory-symlink candidate this is the target chain, not the glob-visible alias
chain. The retained chain is filesystem validation state and must serialize to
that row's `member_path_key`; it is not a second graph identity. Later
filesystem consumers use this retained parent/name mapping instead of
reconstructing a host path from the portable key.

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
- an absent root `package.json`, proving workspace discovery returns the empty
  root-only snapshot without invoking an initializer or writing, a root rename
  or replacement cannot redirect a stale descriptor into a later creation, and
  any workspace-aware absent-root mutation remains deferred to #222;
- malformed, unsupported, wrong-type, `[]`, and `{ "packages": [] }`
  declarations, plus duplicate top-level `workspaces` keys and duplicate
  object-form `packages` keys, proving only a missing field is root-only and a
  JSON parser's duplicate-key selection policy cannot change discovery;
- supported `*` and `**` patterns plus rejected brace, character-class,
  negation, escape, platform-separator, drive-qualified (`C:/...` and
  `C:\\...`), UNC, and device-path forms on every host;
- literal and wildcard patterns over ASCII case variants, non-ASCII case
  variants, Turkish dotted/dotless I, and composed/decomposed spellings, proving
  NFC component matching returns identical results on simulated case-sensitive,
  case-insensitive, and normalization-changing filesystem adapters without
  locale or host normalization behavior; a wildcard between a base scalar and
  combining scalar proves matching normalizes the complete materialized result;
- `packages/**` over ordinary intermediate and source directories, proving
  the zero-segment directory and nested directories with direct `package.json`
  entries become candidates while directories without one are ignored; a
  terminal root `**` case proves the canonical project root is skipped and only
  descendant package directories become members;
- a declaration whose pattern matches no member path;
- a member without a valid `package.json`;
- `..` or absolute path escape attempts;
- an in-root directory-symlink member whose descendants are not traversed and
  whose key uses the canonical target's root-relative chain; selecting that
  target through both its glob-visible alias and canonical path produces one
  identity and key; a directory-symlink cycle fails without traversal, and a
  symlink whose resolved target is outside the canonical root is rejected;
- an in-root member whose direct `package.json` is a symlink (including one
  resolving outside the member or canonical root) and is rejected before the
  target is read;
- injected walker/fake-filesystem failures for directory enumeration, metadata,
  symlink resolution/canonicalization, and candidate manifest reads, proving
  each error names the operation and safe root-relative path and returns no
  partial member table;
- a descendant bind mount, volume boundary, and non-symlink reparse point plus a
  recursive bind mount, proving traversal and selected canonical target chains
  fail before reading external bytes or recursing through the mounted tree;
- an injected descriptor-relative validate-open path swap and identity mismatch,
  including a platform without an atomic equivalent, proving the candidate
  target is not read and the full discovery fails without a partial table;
- a canonical root-directory rename, every retained ancestor parent/name
  replacement, mount/reparse substitution, and root path swap between chain
  validation and descriptor open, proving the ancestor-chain watches and final
  identity checks reject the changed root before reading its `package.json`;
- a root-manifest replacement between discovery and a later consumer, proving
  every workspace-discovery consumer uses the immutable root snapshot and no
  workspace-aware path publishes or truncates the replacement;
- injected in-place root/member manifest writes during descriptor reads, proving
  the stable-snapshot check rejects changing or mixed bytes before parsing;
- an attempted present-manifest write by a workspace-discovery consumer,
  proving the operation is rejected before the root manifest or any alias is
  modified and remains deferred to #222;
- root and member `package.json` files hard-linked to an external alias, writes
  made through that alias, link-count changes, and an injected platform without
  descriptor link-count or exact inode-watch support, proving the retained
  descriptor/inode watches and final metadata checks reject each case before
  parsing or returning a snapshot;
- an injected directory replacement during descriptor-relative enumeration or
  metadata validation, proving the traversal identity mismatch fails the full
  discovery without a partial table;
- a Linux descriptor-scoped inotify adapter proving the root watch is installed
  before the root `package.json` lookup/read and every descendant watch before
  its first directory read, with all watches retained through the final global
  `EAGAIN` cut; injected additions, removals, renames, attribute/manifest
  writes, self-moves, unmounts, queue overflow, lost watches, and
  watch/poll/read/`/proc/self/fd` failures before that cut fail the full
  discovery, while an unchanged queue accepts the cut and a post-cut
  replacement is rejected by retained parent/name and descriptor validation
  before consumer access; a post-cut addition remains outside the returned
  snapshot; fixed delays and repeated equal enumerations are rejected as
  stability evidence;
- an ancestor-chain adapter proving each ancestor watch is installed before
  opening the next child and retained through the global cut; injected rename,
  replacement, delete/create, self-move, mount, watch-loss, and tracked
  parent/name identity drift on every ancestor fail before root manifest bytes
  are read, while unrelated ancestor entries are drained without changing the
  result;
- a sustained unrelated-ancestor-event adapter that keeps the inotify queue
  readable with irrelevant entries while avoiding overflow; event-count,
  byte-count, and monotonic-deadline variants each exceed one per-attempt drain
  budget and fail closed before root manifest bytes or a partial member table
  are returned, while an under-budget burst reaches the exact quiet poll;
- injected `pollfd.revents` values of `POLLERR`, `POLLPRI`, `POLLHUP`,
  `POLLNVAL`, each unknown bit, each combination with `POLLIN`, and
  return-zero/nonzero inconsistencies fail closed; only `revents == 0` with a
  zero return or `revents == POLLIN` with a nonzero return is accepted;
- a root/member manifest inode-watch adapter proving each exact descriptor watch
  is installed before its first byte read and retained through the global cut;
  injected outside-alias writes, hard-link creation/removal, link-count drift,
  `IN_ATTRIB`, `IN_MODIFY`, `IN_CLOSE_WRITE`, self-move, delete, watch-loss,
  and final `fstat` metadata drift fail before parsing or returning a table;
- a race adapter that replaces the root `package.json` or adds, removes, or
  renames a selected member between root snapshot reads, the root-to-member
  snapshot boundary, member enumeration, candidate-manifest reads, and final
  validation; each pre-cut event fails the complete discovery with no parsed
  bytes or partial member table, and queue-drain retry exhaustion fails closed;
- a broad pattern with pre-existing `node_modules`, `.rpm`, and RPM-managed
  staging or backup paths plus ASCII case aliases of those reserved components,
  proving artifacts do not change discovery on case-sensitive or
  case-insensitive adapters;
- overlapping declarations proving sorted, deduplicated root-relative output;
- composed and decomposed non-ASCII member names plus CJK member names, proving
  NFC `member_path_key` serialization and unsigned UTF-8 byte ordering produce
  the same order on every host; an injected non-Unicode native component and a
  normalized-key collision are rejected without a partial table;
- a cross-host UTF-8 portability fixture injects invalid Unix path bytes,
  unpaired Windows surrogate input, WTF-8, and lossy replacement conversion in
  separate cases, proving each fails before resolver handoff while every
  accepted `member_path_key` round-trips as identical valid UTF-8 on POSIX and
  Windows adapters;
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
