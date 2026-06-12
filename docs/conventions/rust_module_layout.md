# Convention: Rust Module Layout

Status: Draft
Owner: repository
Last reviewed: 2026-06-03

## Purpose

RPM keeps Rust modules easy to review by separating API boundaries from domain
implementation. A file name should tell readers whether they are looking at
type definitions, public operations, trait semantics, parsing, or private
algorithm code.

## Rule

Treat `mod.rs` as a module index. Keep it limited to:

- child module declarations
- public or crate-visible re-exports
- module documentation
- very small facade code when the facade is the module's main purpose

Do not put long type definitions, long inherent `impl` blocks, trait impls, or
domain algorithms in `mod.rs`.

When a module owns a public type, prefer this layout:

```text
module/
  mod.rs          # module declarations and re-exports
  types.rs        # public and internal domain types
  construct.rs    # constructors and parsing entrypoints on the type
  display.rs      # Display and formatting trait impls
  ordering.rs     # Eq, Ord, PartialEq, PartialOrd trait impls
  parse.rs        # parser implementation
```

Use narrower file names when they describe the domain better. For example,
`evaluate.rs`, `normalize.rs`, `desugar.rs`, `interval.rs`, and `select.rs` are
acceptable when they name one responsibility.

## Public API Placement

For modules that may become standalone crates, treat the top-level module file
as the future `lib.rs`. The root should own the public facade and should be the
only access point used by code outside the module's domain.

Free `pub fn` operations belong at the facade boundary for the behavior they
expose. They should parse caller input, call typed internals, and return public
results. Implementation modules may define public-to-the-module functions, but
callers outside the domain should not import implementation paths directly.

Private or `pub(crate)` helpers belong under the module that owns the data they
mutate or inspect.

Typed APIs should live in domain modules named for their concepts. Convenience
APIs may live in implementation modules, but they should be re-exported through
the root facade when they are part of the supported surface.

Architecture-specific applications of this rule belong in ADRs. Behavior
contracts belong in SPECs. For example, the semver boundary application is
recorded in `docs/adrs/0004-semver-standalone-ready-boundary.md`, while its
behavior contract remains in `docs/specs/core/semver/SPEC.md`.

## Visibility

Prefer the narrowest visibility that compiles:

- use private items by default
- use `pub(super)` for parent-module-only helpers
- use `pub(crate)` for cross-module internals inside RPM
- use `pub` only for documented API surface

Avoid wildcard public re-exports for stable API surfaces. Re-export explicit
items when the facade contract matters.

## Impl Organization

Group inherent impls by responsibility. Do not let one `impl Type` block become
a mixed bag of constructors, accessors, mutation helpers, parser entrypoints,
and domain algorithms.

Trait impls encode observable semantics. Move them to dedicated files when they
are not trivial, especially for:

- `Display`
- `FromStr`
- `Ord` and `PartialOrd`
- custom `PartialEq`
- conversion traits

## Change Discipline

File splits and module layout cleanups must not change behavior. Do not combine
module layout work with resolver, lockfile, registry, installer, or CLI contract
changes.

When a layout change crosses more than one domain module, keep the patch
mechanical and validate with at least `cargo check`.
