---
spec_id: node_modules_linker
title: Node Modules Linker
status: draft
owner: core/linker
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
  - 139
---

# Spec: Node Modules Linker

Status: Draft
Owner: core/linker
Last reviewed: 2026-08-11

## Purpose

RPM links an extracted package set into a `node_modules` filesystem layout after
dependency resolution and package extraction. The linker contract defines the
shape that package-local dependency links must create so runtime resolution sees
only the dependencies declared by each package.

## Contract

For each resolved package, RPM creates dependency links under that package's own
`node_modules` directory. A dependency link target is calculated from the actual
dependency package name, not from the parent package being linked.

For example, if package `a` declares dependency `b`, the linker creates:

```text
node_modules/a/node_modules/b -> node_modules/b
```

Scoped package names keep their scope directory. If package `a` declares
`@scope/b`, the linker creates:

```text
node_modules/a/node_modules/@scope/b -> node_modules/@scope/b
```

The link path uses the raw scoped name (`@scope/name`) verbatim: the leading
`@`, the scope label, and the `/` all become path components, so a scoped
dependency is linked under a real `@scope/` directory the same way an unscoped
dependency is linked under its bare name. The linker reuses the resolver
package name and the lockfile key without re-encoding or sanitizing it; only
the registry lookup path percent-encodes the scoped name
(`docs/specs/core/registry/SPEC.md`) and only the cache filename replaces `/`
with `-` (`docs/specs/core/install/cache/SPEC.md`).

Filesystem operations are part of the contract. Directory creation and symlink
creation failures must be returned as errors rather than ignored.

Strict dependency visibility remains a design constraint: package-local
`node_modules` entries should expose declared dependencies, not unrelated
packages from the root package set.

### Executable bin links (`node_modules/.bin`)

After dependency links are created, RPM generates executable links for every
resolved package that declares a `bin` field. The `bin` field source and shape
are owned by `docs/specs/core/manifest/SPEC.md` (root package) and
`docs/specs/core/registry/SPEC.md` (per-version packument entry); the linker
owns only the link layout those entries produce.

Only resolved packages with an installed directory under `node_modules/`
receive `.bin` links. The root project manifest is a `bin` source for
preservation only: it has no installed directory and the linker does not create
a `.bin` link for the root package itself. Reaching the root project's own
binaries through `rpm run` is handled by the run contract and the PATH prepend
(`docs/specs/cli/run/SPEC.md`, issue #143), not by `.bin` generation.

For each resolved package that declares `bin`, RPM creates one link per exposed
binary name under the project `node_modules/.bin/` directory. The link points
at the package's declared target file inside the package's installed directory:

```text
node_modules/.bin/<binary-name> -> ../<package-dir>/<target-file>
```

Where `<package-dir>` is the package's installed directory (the same directory
the dependency-link step uses) and `<target-file>` is the path the `bin` entry
names, relative to the package root.

Binary name confinement. The binary name must be a single path component: it
must not be empty, must not contain a path separator (`/` or `\`), must not be
absolute, and must not contain a parent-reference (`..`) component. An
object-form `bin` key that violates any of these (for example
`{"../../outside": "./cli.js"}`, `{"": "./cli.js"}`, or `{"a/b": "./cli.js"}`)
is rejected as a link input error before any `.bin` link is created; it is not
written verbatim into `node_modules/.bin`. Package-controlled metadata must not
be able to place a `.bin` entry outside the `node_modules/.bin/` directory. The
package name used for string-form binaries is already a single component by the
resolver name contract, so this guard primarily constrains object-form keys.

Binary name mapping follows npm semantics:

- An **unscoped** package with `bin` in string form (`"bin": "./cli.js"`)
  exposes exactly one binary named after the package `name`, pointing at
  `./cli.js`.
- An **unscoped** package with `bin` in object form
  (`"bin": { "my-cli": "./cli.js", "helper": "./bin/helper.js" }`) exposes one
  binary per map key; each key is the binary name and each value is the target
  file.
- A **scoped** package (`@scope/name`) in string form exposes one binary named
  after the package's unscoped name (`name`, without the `@scope/` prefix),
  pointing at the target file. The scope is dropped from the binary name.
- A **scoped** package (`@scope/name`) in object form exposes one binary per map
  key, exactly as written. Object-form keys are used verbatim; the linker does
  not prefix, strip, or otherwise rewrite them.

Name collisions across packages are resolved last-writer-wins by link creation
order. A single canonical link target exists per binary name after linking
completes; RPM does not merge or union colliding binaries. The collision
resolution order is owned by the linker implementation ticket (#140), not by
this contract.

Planned workspace v2 makes that existing exception deterministic for each
root/member `node_modules/.bin` directory. Eligible package producers are
visited in lockfile v2's total identity order and each package's validated
binary names are visited in unsigned UTF-8 byte order. When multiple producers
use the exact same binary-name bytes, the later producer replaces the earlier
link and is the one surviving target. This exact-name case is one intentional
logical output slot and is exempt from the general #147 projection-collision
rejection. Two distinct raw names that only collide after host case folding,
Unicode normalization, trailing-space/dot handling, or another filesystem
equivalence are separate objects and remain invalid before linking.

The `.bin` directory and its links are part of the install output transaction:
they are created during the link phase and must be present before the install
is reported as successful. `rpm run` consumes the resulting `node_modules/.bin`
by prepending it to `PATH` (`docs/specs/cli/run/SPEC.md`); the linker owns how
`.bin` is populated, `rpm run` owns how it is consumed.

Lifecycle script execution (`preinstall`, `install`, `postinstall`, `prepare`)
is not part of this contract. Lifecycle policy is owned separately
(`docs/specs/core/install/recovery/SPEC.md` will own the `scripts` phase; see
issue #141). The `.bin` contract must not depend on lifecycle scripts running,
and lifecycle scripts must not depend on `.bin` being populated.

#### Platform considerations

This contract defines the link layout only. Platform-specific executable
wrappers are explicitly deferred:

- On Unix-like platforms the link is a symlink and the target file is expected
  to carry its own shebang line. RPM does not synthesize or rewrite shebangs.
- Windows `.cmd` / `.ps1` shim generation, executable-bit handling, and any
  platform-dependent permission normalization are **out of scope** for this
  contract and are deferred until a platform-packaging strategy SPEC owns them
  (M10 / issue #163). Until then, `.bin` generation produces the same symlink
  layout on every platform; a Windows host that cannot create or follow a
  symlink surfaces a filesystem error as defined under Error Cases.

## Error Cases

Linking fails if a dependency target package has not been extracted, if the
destination directory cannot be created, or if the symlink cannot be created.
Failed linking must not be reported as a successful install or script setup.

A package that declares a `bin` entry whose target file does not exist inside
the extracted package directory is a link failure, not a successful install.
The linker must not create a `.bin` link that points at a missing target. A
`node_modules/.bin` directory that cannot be created or written is a link
failure.

A `bin` binary name that violates the single-component confinement guard
(absolute, separator-containing, parent-referencing, or empty) is a link input
error, not a successful install; no `.bin` link is created for that entry.

A package that declares no `bin` field contributes no `.bin` entries; this is
normal and not an error.

## Test Fixtures

Linker verification should cover unscoped and scoped dependency links plus
destination-directory and symlink-creation failures.

`.bin` generation verification should cover:

- unscoped package, string-form `bin`, single binary named after the package;
- unscoped package, object-form `bin`, one binary per map key;
- scoped package, string-form `bin`, binary named after the unscoped name;
- scoped package, object-form `bin`, binary names used verbatim;
- package with no `bin` field producing no `.bin` entries;
- a `bin` target file that is absent from the extracted package producing a
  link failure rather than a dangling link;
- a `bin` target that traverses outside the extracted package directory after
  symlink and `..` normalization (for example a `target` of `../outside.js` or
  an in-package symlink that resolves outside the package root) producing a
  link failure rather than an escaping link;
- an object-form `bin` key that is not a single path component (absolute,
  separator-containing, parent-referencing, or empty, for example
  `{"../../etc/foo": "./cli.js"}`) producing a link input error rather than a
  link written outside `node_modules/.bin/`;
- two planned v2 producers with the exact same validated binary name, proving
  the later producer in total identity order wins deterministically; and
- two distinct raw binary names that project to the same host key, proving the
  pair is rejected instead of entering last-writer precedence.

Fixtures must copy install projects to temporary directories before mutation
and must not use live npm.
