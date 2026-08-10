---
spec_id: lockfile_v1
title: Lockfile v1
status: draft
owner: core/lockfile
last_reviewed: 2026-08-11
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
  - 136
---

# Spec: Lockfile v1

Status: Draft
Owner: core/lockfile
Last reviewed: 2026-08-11

## Purpose

`rpm.lock` is the reproducibility contract for installs. It records the
requested package graph and the resolved package facts needed by later install
phases.

## Contract

### Format

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

### Loading

An absent or empty lockfile initializes as an empty v1 lockfile. Empty loading
must not be reported as successful dependency resolution; it only gives callers a
safe in-memory lockfile to mutate.

Malformed TOML or malformed lockfile fields are load failures. Parse failures
must include the lockfile path and parser context.

### Saving

Saving writes the complete current lockfile and truncates old content. Save
errors must include the lockfile path and must not be hidden behind panics.

## Error Cases

Malformed TOML, malformed lockfile fields, and save failures must be returned
with the lockfile path and parser or write context. Empty loading must not be
reported as successful dependency resolution.

## Test Fixtures

Lockfile verification should cover v1 format round-tripping, empty lockfile
initialization, malformed-file parse failures, and save truncation behavior.
