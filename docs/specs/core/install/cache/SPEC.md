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
RPM cannot determine a conservative projection for the approved cache root, v2
replay fails closed.

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
RPM opens each `.rpm/.cache` component descriptor-relative with
no-follow semantics and requires a directory at each step, establishing the
approved cache-root handle without following a symlink. It then opens the
derived entry relative to that handle with a no-follow operation. It rejects a
symlink at the final component and rejects directories, devices, sockets, and
every other non-regular file. Path-based prechecks alone are insufficient, and
the entry must never be reopened by pathname after validation.

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
`version`, canonical bin map, and scripts map must exactly match the v2 external
record under the lockfile SPEC.
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
pathname reopen. The publisher must atomically reject a final destination that
appeared or changed after preflight; it must not truncate, follow, or replace
that entry. Reopening `.rpm/.cache`, the staged entry, or the final destination
through a workspace pathname is invalid. A cache-root identity change,
unsupported descriptor-relative staging or publication, or a raced staging or
final destination fails publication and discards the staged entry. These
requirements make pathname replacement after open irrelevant to the bytes
consumed by extraction and keep cache replay and publication from introducing a
verify/use race.

## Error Cases

If the selected registry metadata has no tarball URL, the download phase must
return an error instead of writing a placeholder cache file.

Cache directory creation, file opening, file writing, and file flushing failures
must be returned to callers with the failed cache path in the error message.
Rename-style publication failures must also be returned to callers with the
failed cache path in the error message. Failed staged writes or failed
publication must not leave a partial file at the final cache path. Staging files
should be removed after failures; if cleanup fails, the cleanup failure should
be reported with the original cache write failure.

Metadata reads must remain side-effect free even when registry metadata contains
tarball URLs.

For v2, a cache projection collision, reserved host spelling, symlink or
non-regular cache entry, unstable verification descriptor, missing or invalid
SHA-512 integrity, shasum-only provenance, archive-manifest identity failure,
or archive-entry/link validation failure is reported before extraction and
before cache or install output is published. Cache-root identity drift,
unavailable descriptor-relative publication, or a raced final destination fails
cache publication and still blocks install publication. A raced or unsafe
staging entry fails before verified bytes are copied into cache staging.

## Test Fixtures

Unit tests in `src/lib/registry/mod.rs` verify cache filename derivation for
unscoped and scoped package names, and verify that cache writes do not create
`*.tgz.tgz` paths. They also verify that rename-style publication failures are
reported without leaving staging files behind.

Linker tests in `src/lib/node_linker/mod.rs` verify that extraction reads the
same cache filename shape.

Planned v2 fixtures must additionally cover:

- names that collide only after host case folding or Unicode normalization,
  plus trailing-dot, trailing-space, and reserved-name spellings, proving the
  whole cache destination set is rejected before download or cache creation;
- a final cache entry replaced with a symlink or non-regular file, proving the
  descriptor-relative no-follow open rejects it without reading the target;
- a pathname swap after the cache entry is opened, proving verification and
  extraction consume the same stable descriptor bytes;
- replacement of the `.rpm/.cache` pathname or creation of the final entry
  between verification and publication, proving publication remains relative
  to the originally opened cache-root descriptor and fails without following or
  replacing the raced destination;
- a pre-existing or raced cache staging name that is a symlink or other entry,
  proving exclusive descriptor-relative no-follow creation fails without
  writing through the entry, publishing a final cache file, or changing install
  or lockfile output;
- concurrent content mutation where a stable direct descriptor cannot be
  guaranteed, proving the transaction-owned verified descriptor is used or the
  replay fails closed; and
- digest-valid archives with matching identity plus missing, wrong-type,
  mismatching, duplicate, and ambiguous required package-manifest name/version
  cases, plus canonical bin/scripts mismatches; absent and wrong-type optional
  bin/scripts normalize to `{}` on both sides. No cache or install output is
  published and extraction never starts unless the exact provenance gate
  succeeds.
