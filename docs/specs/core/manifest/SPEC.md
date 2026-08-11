---
spec_id: package_manifest
title: Package Manifest
status: draft
owner: core/manifest
last_reviewed: 2026-08-10
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
---

# Spec: Package Manifest

Status: Draft
Owner: core/manifest
Last reviewed: 2026-08-11

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
well-typed value round-trips into `Some(...)`. A manifest that omits `scripts`
behaves identically to one without it.

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

## Error Cases

Invalid JSON is an input error and must not be reported as a successful command.
File write, create, and serialization failures must not be hidden behind
panics.

## Test Fixtures

Manifest fixtures live under `tests/fixtures/package_manifest/`.
