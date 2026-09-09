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
`/` → `-` rule covers every `/` in the name.

The cache filename is derived from the selected package name and resolved
version. It is not derived from the registry tarball URL basename, because
registry URLs can repeat the package name and already include the `.tgz`
extension.

Registry metadata reads may return tarball URLs, dependency declarations, and
version metadata, but they must not write files into `.rpm/.cache`. Cache
writes belong to the tarball download phase.

Cache writes stage downloaded bytes in the approved cache directory and publish
the final cache file only after the staged file is completely written and
flushed. The final
`<sanitized-package-name>@<resolved-version>.tgz` path is never exposed as a
partially written file. Publication uses a same-directory atomic rename or the
host equivalent, and failed publication removes the temporary file when
possible.

The cache writer appends exactly one `.tgz` extension. Passing an input that
already ends in `.tgz` must not create a `*.tgz.tgz` path.

The linker resolves cached tarballs using the same filename contract.

### Planned v2 destination preflight

Before a v2 fetch or replay opens or creates a cache entry, the installer
derives every final cache destination and checks both lexical containment under
the approved cache root and the host filesystem's projection rules. The
projection accounts for case folding, Unicode normalization, trailing-space
and trailing-dot behavior, and reserved-name semantics. Two distinct external
identities that project to one cache destination are an input error. A
projection or root-confinement check that cannot be completed returns an
unsupported-capability error before tarball acquisition or filesystem mutation.

The workspace and `node_modules` projections are owned by workspace discovery
(#221) and the linker (#147). V2 external records carry the selected version's
canonical bin map, so #147 can check every planned `.bin` destination before
fetching or opening an archive. This SPEC does not redefine linker layout.

### Planned v2 verified reads and publication

A v2 cache hit is untrusted until its exact bytes pass the required SHA-512 SRI
recorded in the selected registry provenance. A shasum-only cache hit is not
eligible for v2 replay. The cache path is opened relative to the approved cache
root with no-follow final-component semantics and must be a regular file.
Symlinks, directories, devices, sockets, and other non-regular entries are
rejected before their contents are consumed.

The installer copies a cache hit, when needed, into a transaction-private
regular file and keeps the verified descriptor open through integrity
verification and archive inspection. It reads the archive manifest from that
same descriptor and requires the exact external package `name`, `version`,
ordinary dependency requests, canonical `bin` map, and `scripts` map
specified by the lockfile contract. #147 validates archive entries plus
symlink and hardlink targets from that descriptor before extraction. Extraction
does not reopen the cache path.

A fresh v2 download is acquired into a transaction-private descriptor. RPM
verifies SHA-512, validates the archive manifest and #147's safe archive-entry
and link rules before extraction or cache publication. It then writes a
temporary cache entry inside the approved cache directory, flushes it, and
publishes it with same-directory atomic rename. The final name is derived from
validated package identity; an existing destination is replaced only when the
selected update policy permits it and its regular-entry identity passes the
publication checks. A user file, symlink, or other unexpected destination is
preserved and causes publication to fail. Extraction consumes the verified
descriptor and does not reopen the cache path.

Containment and identity checks are performed immediately before each
filesystem mutation. If a check observes root, directory, destination, or
content drift, RPM aborts the operation, removes only its own temporary file,
and preserves the previous cache and install outputs. Ordinary recovery may
retry from the last committed state; it must not publish a partial archive.
The cache contract does not provide a cross-object compare-and-swap or
universal protection against an uncoordinated same-user writer, `mmap`
mutation, or mount replacement after the last observed check. Such unobserved
changes are outside the contract; changes detected by identity, size, metadata,
or read validation are reported as drift.

## Error Cases

If selected registry metadata has no tarball URL, the download phase returns an
error instead of writing a placeholder cache file.

Cache directory creation, file opening, writing, flushing, integrity
verification, archive-manifest validation, archive-entry/link validation, and
publication failures are returned with safe cache context. Failed staged writes
or failed publication do not leave a partial file at the final cache path.
Cleanup failures are reported with the original cache failure.

For v2, a projection collision, unsafe path, symlink or non-regular cache
entry, missing or invalid SHA-512 integrity, archive-manifest mismatch, or
unsafe archive link is reported before extraction or cache/install publication.
Observed root or destination drift is an ordinary transaction error and leaves
the prior committed output intact.

Metadata reads remain side-effect free even when registry metadata contains
tarball URLs.

## Test Fixtures

Unit tests in `src/lib/registry/mod.rs` verify cache filename derivation for
unscoped and scoped package names, the single `.tgz` extension, and the
existing rename-style failure cleanup.

Linker tests in `src/lib/node_linker/mod.rs` verify that extraction reads the
same cache filename shape.

Planned v2 fixtures belong to the implementation work owned by #224 and do not
claim that the current runtime already supports v2. They should cover:

- cache destination traversal, reserved names, case/normalization collisions,
  and a symlink or special-file destination rejected before acquisition;
- a cache hit whose exact bytes pass SHA-512 and whose archive manifest matches,
  plus integrity, name/version, dependency, bin, and scripts mismatches rejected
  before extraction;
- archive entries with escaping paths, unsafe symlink targets, and unsafe
  hardlink targets rejected after acquisition and before extraction or
  publication;
- fresh bytes written to a transaction-private temporary descriptor, followed
  by flush and same-directory atomic cache publication; a write, flush, or
  publication failure preserves the previous cache entry and removes only the
  worker's temporary file;
- an observed root, cache-directory, destination, or staged-byte identity/read
  drift that aborts publication without changing committed cache or install
  output; and
- repeated recovery from the same failed transaction producing no partial final
  archive and no unrelated file changes.

Fixtures must copy install projects to temporary directories before mutation,
remain offline, and keep planned evidence separate from runtime assurances.
