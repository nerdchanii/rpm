---
spec_id: lockfile_v1
title: Lockfile v1
status: draft
owner: core/lockfile
last_reviewed: 2026-05-29
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
---

# Spec: Lockfile v1

Status: Draft
Owner: core/lockfile
Last reviewed: 2026-05-29

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

Package entries record:

- `name`: package name, including scope when present.
- `requested`: the range or tag requested by the parent manifest or package.
- `version`: resolved package version.
- `relationship`: one of `direct`, `dev`, or `transitive`.
- `tarball`: resolved tarball URL when registry metadata provides it.
- `integrity`: Subresource Integrity value when provided.
- `shasum`: legacy shasum when `integrity` is absent or when the registry only
  provides a shasum.
- `dependencies`: dependency edges as requested package references.

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

## Open Questions

None currently.
