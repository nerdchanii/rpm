---
spec_id: install_cache
title: Install Cache
status: draft
owner: core/install/cache
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
  - 44
  - 146
  - 224
---

# Spec: Install Cache

Status: Draft
Owner: core/install/cache
Last reviewed: 2026-08-24

## Purpose

RPM stores downloaded package tarballs in the local install cache before the
linker extracts them into `node_modules`. This contract defines the cache
filename shared by tarball download and linker code, and keeps registry metadata
reads separate from cache writes.

## Contract

Each downloaded package tarball is cached under `.rpm/.cache` with this
filename:

```text
<sanitized-package-name>@<resolved-version>.tgz
```

The sanitized package name is the npm package name with every `/` replaced by
`-`. For example:

```text
axios@0.21.1.tgz
@babel-core@2.3.1.tgz
```

This sanitization is the only place RPM rewrites the `/` in a scoped name. It
applies to the cache filename only; the resolver package key, the lockfile
`name` and entry key, and the linker path all keep the raw `@scope/name`
(`docs/specs/core/resolver/SPEC.md`, `docs/specs/core/lockfile/SPEC.md`,
`docs/specs/core/linker/SPEC.md`), and only the registry lookup path
percent-encodes it (`docs/specs/core/registry/SPEC.md`). A single
`/` → `-` rule covers every `/` in the name, so a scoped name with one scope
separator and any future unscoped name containing a `/` both sanitize the same
way.

The cache filename is derived from the selected package name and resolved
version. It is not derived from the registry tarball URL basename, because
registry URLs can repeat the package name and already include the `.tgz`
extension.

Registry metadata reads may return tarball URLs, dependency declarations, and
version metadata, but they must not write files into `.rpm/.cache`. Cache writes
belong to the tarball download phase.

Cache writes must stage downloaded bytes in `.rpm/.cache` and publish the final
cache file only after the staged file is fully written and flushed. The final
`<sanitized-package-name>@<resolved-version>.tgz` path must not be truncated or
replaced until publication. Publication must use a same-directory rename so
callers never observe a partially written final cache file.

The cache writer must append exactly one `.tgz` extension. Passing an input that
already ends in `.tgz` must not create a `*.tgz.tgz` path.

The linker must resolve cached tarballs using the same filename contract.

### Planned v2 destination preflight

Before a v2 tarball fetch or replay opens or creates a cache entry, the installer
derives every final cache destination and compares its filesystem projection
key under the actual host filesystem's equivalence rules. The key accounts for
case folding, Unicode normalization, trailing-space and trailing-dot behavior,
and reserved-name semantics in addition to the lexical `/` to `-` mapping. Two
distinct external identities that project to the same cache destination are an
input error even when their UTF-8 spellings differ. A component that the host
treats as reserved is also an input error. The complete set is checked before
tarball download, extraction, linking, or creation of a final or staged cache file. If
RPM cannot determine a conservative projection for any destination or the
approved cache root, v2 replay and fresh fetch/publication fail closed before
tarball acquisition, cache mutation, or publication.

The corresponding workspace and `node_modules` destination projections are
owned by workspace discovery (#221) and the linker (#147). V2 external records
carry the selected version's canonical bin map, so #147 can enumerate every
`.bin` destination during this preflight without fetching or opening a tarball.
The lockfile replay and fresh-publication gates consume the bound validated
results, including the linker's narrow exact-name `.bin` precedence rule; this
cache SPEC does not define the linker's path layout.

### Planned v2 verified replay reads

A v2 cache hit is untrusted until its exact bytes pass the required SHA-512 SRI
recorded in the selected registry provenance. A shasum-only cache hit is
ineligible for v2 replay. Starting from the trusted workspace directory handle,
RPM establishes the `.rpm/.cache` component chain descriptor-relative. For each
component in order, an existing entry is opened with no-follow semantics and
must be a directory. For an absent component, RPM chooses an unpredictable
temporary sibling name and passes it to one atomic descriptor-relative
`create_dir_retain(parent_descriptor, temporary_name)` capability. That single
capability must create the empty directory, return its no-follow open
descriptor, and bind the created object identity to the retained parent
descriptor and temporary name before the result is observable. A separate
`mkdirat` followed by `openat` or `openat2`, even with no-follow flags, does not
qualify because an attacker can replace the name between creation and retain.
Before choosing or creating that temporary sibling, RPM must verify that the
platform also supplies move-aware identity-bound cleanup for the retained
object, or a combined create-retain-publish capability that never exposes the
temporary source to an attacker. If neither capability exists, RPM fails
closed before invoking the create operation and before creating any temporary
directory.
The retained create capability then invokes an identity-bound publication
primitive with the retained temporary-directory descriptor/object identity,
the original temporary name and parent binding, and the component destination.
At the one atomic commit point, that primitive must prove that the temporary
name still identifies the retained directory before moving anything, and must
then perform a parent-handle no-replace publication such as
`renameat2(..., RENAME_NOREPLACE)`. A bare `renameat2(..., RENAME_NOREPLACE)`
protects only the destination name and does not qualify: it can publish an
attacker's replacement of the temporary source. A separate source identity
check followed by rename is equally insufficient. If the source binding or
destination changed, publication fails before either entry is moved or
replaced. RPM verifies that the retained object identity is bound to the
published parent/name, records that binding, and uses the retained descriptor
thereafter; it never reopens the component through a pathname.

Failure cleanup must use the retained create capability's identity-conditional
remove operation with the original parent binding and object identity. The
cleanup capability must be move-aware: if an attacker renames the retained
temporary directory to another name after creation, it must reclaim exactly
the retained object by identity without following an attacker path or removing
the replacement at the original name. A combined create-retain-publish
capability may satisfy this requirement by keeping the temporary source
unobservable. A name-only `unlinkat`/`rmdir` cleanup at the original name after
a create/open race is forbidden. If the adapter cannot prove and complete
identity-bound reclamation after a source move, it is unsupported and must
fail closed before any temporary directory is created. This establishes the
approved cache-root handle without following a symlink on a clean first install
or an existing cache. It retains the workspace-root identity and exact
parent/name chain, plus the `.rpm` and `.cache` component identities and names,
for the transaction. It then opens the derived entry relative to that handle
with a no-follow operation. It rejects a symlink at the final component and
rejects directories, devices, sockets, and every other non-regular file.
Path-based prechecks alone are insufficient, and the entry must never be
reopened by pathname after validation.

The installer must establish one stable verification descriptor for the archive
bytes. The descriptor returned by the no-follow cache open may be used directly
only when the platform can exclude concurrent content mutation for the whole
verify-and-extract interval. Otherwise RPM copies the cache bytes once into a
transaction-owned, exclusively created regular no-follow file and uses that
private file descriptor as the stable descriptor. The private snapshot is
unlinked after opening or lives in a transaction-private directory, is not
published through a mutable pathname, and has no other writable handle during
verification or extraction. RPM rewinds and reads that stable descriptor to
validate the required supported SHA-512 `integrity` value, then uses the same
descriptor to inspect the archive package manifest. The manifest `name`,
`version`, ordinary `dependencies` request map, canonical bin map, and scripts
map must exactly match the v2 external record and outgoing edges under the
lockfile SPEC.
RPM rewinds the descriptor again and passes it directly to extraction only after
both checks and #147's descriptor-bound archive-entry, symlink, and hardlink
validation succeed, keeping it open throughout. Extraction must not resolve or
reopen the cache path. Failure to obtain a stable descriptor, a descriptor
identity or type change, a short or changed read, a SHA-512 mismatch, an
archive-manifest identity failure, or failed archive-entry/link validation
invalidates the hit and blocks extraction and publication.

A newly downloaded v2 archive follows the same rule. After the graph, name, and
destination projections derivable without archive bytes pass preflight, network
acquisition may write only an exclusive transaction-owned descriptor that is
not published through a cache or install pathname. RPM verifies SHA-512 there,
inspects the exact external package-manifest identity/bin/scripts provenance,
and runs #147's archive-entry, symlink, and hardlink validation against that
same descriptor before extraction. Extraction consumes the same descriptor.
Final cache publication may occur only after verification, provenance
inspection, and archive-entry/link validation succeed. RPM retains the
originally approved cache-root directory descriptor through publication. The
staged cache entry is exclusively created as a regular file relative to that
descriptor with no-follow final-component semantics. RPM writes and flushes it
through that exact opened descriptor. The final same-directory rename publishes
that same staged entry relative to the same cache-root descriptor without a
pathname reopen. The identity includes the platform's stable object identity
and, where the platform exposes it, the file-generation/version value; a
platform that cannot distinguish an unlink/recreate from the observed object
must not claim CAS support. The rename must be an identity-conditional
descriptor-relative commit, with a no-replace branch for an absent final
destination and a CAS branch
for an explicitly authorized existing destination. Preflight records the final
state as absent or as the exact regular, non-symlink identity that the CAS is
allowed to replace. The no-replace branch atomically fails if a final entry
appeared; the CAS branch atomically compares that recorded identity and fails if
the entry appeared, disappeared, changed identity, became non-regular, or became
a symlink. An ordinary `renameat` or same-directory rename that silently
replaces the destination does not satisfy this contract. Planned v2 cache
population uses the absent/no-replace branch unless an explicit update policy
authorizes the matching-identity CAS branch.

The primitive takes the retained workspace-root handle and identity, its exact
parent/name chain, the retained `.rpm/.cache` handle and component parent/name
chain, staged descriptor/name, final name, and expected final state as one
commit operation. For an absent component, its source check is part of this
same atomic operation: the temporary name must still map to the retained
created-directory identity before the no-replace destination commit. At the
atomic commit point it must also prove that the workspace root and every
`.rpm/.cache` component still resolve through those same identities and names
before it performs the identity-conditional commit. A workspace-root or
`.rpm/.cache` pathname replacement therefore fails even when an old descriptor
still refers to the renamed directory. Reopening `.rpm/.cache`, the staged
entry, or the final destination through a workspace pathname is invalid. A
cache-root identity or parent-chain change, unsupported descriptor-relative
staging or identity-conditional publication, a changed temporary source
binding, or a raced staging or final destination fails publication and
discards only the retained staged object while leaving the raced destination
and source entries untouched. These requirements make pathname replacement
after open irrelevant to the bytes consumed by extraction and keep cache replay
and publication from introducing a verify/use race.

The current Rust/POSIX adapters, including the current macOS/POSIX adapters,
do not provide the required atomic create-and-retain capability for an absent
`.rpm` or `.cache`, the atomic parent-chain-and-destination CAS capability, or
move-aware identity-bound cleanup. They therefore fail closed before invoking
absent-component creation and before any temporary directory, network, or
cache mutation. A separate
`fstatat`/`fstat` identity check followed by `renameat` or `renameat2` is not an
atomic proof and does not satisfy this contract. Until #224 supplies concrete
platform capabilities and executable tests for atomic create-and-retain,
retained parent-chain proof, source-bound no-replace/CAS publication,
move-aware identity-bound cleanup, and no-follow descriptor use, every v2 cache
publication and replay path remains disabled and fails closed before cache,
network, extraction, or install mutation.

## Error Cases

If the selected registry metadata has no tarball URL, the download phase must
return an error instead of writing a placeholder cache file.

Cache directory creation, file opening, file writing, and file flushing failures
must be returned to callers with the failed cache path in the error message.
Identity-conditional publication failures must also be returned to callers with
the failed cache path in the error message. Failed staged writes or failed
publication must not leave a partial file at the final cache path. Staging files
should be removed after failures; if cleanup fails, the cleanup failure should
be reported with the original cache write failure.

Metadata reads must remain side-effect free even when registry metadata contains
tarball URLs.

For v2, a cache projection collision, reserved host spelling, symlink or
non-regular cache entry, unstable verification descriptor, missing or invalid
SHA-512 integrity, shasum-only provenance, archive-manifest identity failure,
or archive-entry/link validation failure is reported before extraction and
before cache or install output is published. Cache-root identity or parent-chain
drift, unavailable descriptor-relative publication, or a raced final destination
fails cache publication and still blocks install publication. A raced or unsafe
staging entry fails before verified bytes are copied into cache staging.

## Test Fixtures

Unit tests in `src/lib/registry/mod.rs` verify cache filename derivation for
unscoped and scoped package names, and verify that cache writes do not create
`*.tgz.tgz` paths. They also verify that cache publication failures are reported
without leaving staging files behind.

Linker tests in `src/lib/node_linker/mod.rs` verify that extraction reads the
same cache filename shape.

Planned v2 fixtures must additionally cover:

- a clean first-install workspace with absent `.rpm` and `.cache`, proving each
  component uses the atomic create-and-retain capability, an identity-bound
  descriptor-relative publication that combines the retained source identity
  check with `RENAME_NOREPLACE`, identity verification, and retained-descriptor
  use; a barrier immediately after that atomic capability returns and before
  identity-bound publication lets an attacker replace the temporary source
  name or create the final name, and a second barrier immediately before
  failure cleanup lets the attacker replace the retained binding. Source
  replacement must fail before the attacker directory is published. Both
  barriers must preserve the attacker entry, reject name-only cleanup, clean up
  only through the retained identity capability, and make zero network or
  tarball requests or cache mutation;
- a separate adapter-capability fixture for the combined
  create-retain-publish branch, proving that the temporary source is never
  externally observable, its created identity is bound directly to the
  published component, and no source-replacement barrier is applicable to
  that branch; destination and retained parent-chain race checks remain
  required, and unsupported adapters fail closed;
- an attacker renaming the retained temporary source to another name before
  publication, proving the publication/failure path reports a stable
  source-binding race, reclaims the retained object through move-aware
  identity-bound cleanup without deleting the attacker replacement, and leaves
  no orphan directory; repeated retries of the same race must not increase the
  orphan count or create additional untracked temporary directories. An
  adapter without that cleanup capability fails before the first temporary
  directory is created;
- names that collide only after host case folding or Unicode normalization,
  plus trailing-dot, trailing-space, and reserved-name spellings, proving the
  whole cache destination set is rejected before download or cache creation;
- a final cache entry replaced with a symlink or non-regular file in both fresh
  and replay variants, proving the descriptor-relative no-follow open rejects
  it without reading the target or making a network/tarball request;
- a pathname swap after the cache entry is opened, proving verification and
  extraction consume the same stable descriptor bytes;
- behind a barrier after workspace-root and `.rpm/.cache` parent/name-chain
  identity plus final-destination preflight and before the commit, renaming or
  replacing the validated workspace root or `.rpm/.cache` pathname and creating
  or replacing the final entry, proving the descriptor-relative no-replace/CAS
  primitive rejects every race without following or replacing the raced
  destination; a platform without that primitive fails closed;
- a pre-existing or raced cache staging name that is a symlink or other entry,
  proving exclusive descriptor-relative no-follow creation fails without
  writing through the entry, publishing a final cache file, or changing install
  or lockfile output;
- concurrent content mutation where a stable direct descriptor cannot be
  guaranteed, proving the transaction-owned verified descriptor is used or the
  replay fails closed; and
- digest-valid archives with matching identity plus missing, wrong-type,
  mismatching, duplicate, and ambiguous required package-manifest name/version
  cases, ordinary `dependencies` absent/empty, wrong-type, non-string,
  duplicate, key-order, exact-selector, missing-edge, extra-edge, and changed-
  edge cases, plus canonical bin/scripts mismatches; absent and wrong-type
  optional bin/scripts normalize to `{}` on both sides. No cache or install
  output is published and extraction never starts unless the exact provenance
  gate succeeds.
