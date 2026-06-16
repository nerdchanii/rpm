---
spec_id: install_cache
title: Install Cache
status: draft
owner: core/install/cache
last_reviewed: 2026-06-16
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
---

# Spec: Install Cache

Status: Draft
Owner: core/install/cache
Last reviewed: 2026-06-16

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

The cache filename is derived from the selected package name and resolved
version. It is not derived from the registry tarball URL basename, because
registry URLs can repeat the package name and already include the `.tgz`
extension.

Registry metadata reads may return tarball URLs, dependency declarations, and
version metadata, but they must not write files into `.rpm/.cache`. Cache writes
belong to the tarball download phase.

The cache writer must append exactly one `.tgz` extension. Passing an input that
already ends in `.tgz` must not create a `*.tgz.tgz` path.

The linker must resolve cached tarballs using the same filename contract.

## Error Cases

If the selected registry metadata has no tarball URL, the download phase must
return an error instead of writing a placeholder cache file.

Cache directory creation, file opening, file writing, and file flushing failures
must be returned to callers with the failed cache path in the error message.

Metadata reads must remain side-effect free even when registry metadata contains
tarball URLs.

## Test Fixtures

Unit tests in `src/lib/registry/mod.rs` verify cache filename derivation for
unscoped and scoped package names, and verify that cache writes do not create
`*.tgz.tgz` paths.

Linker tests in `src/lib/node_linker/mod.rs` verify that extraction reads the
same cache filename shape.
