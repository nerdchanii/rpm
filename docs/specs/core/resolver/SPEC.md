---
spec_id: resolver_boundary
title: Resolver Strategy Boundary
status: draft
owner: core/resolver
last_reviewed: 2026-08-11
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
  - 0006-resolver-strategy-boundary
related_issues:
  - 50
  - 58
  - 130
  - 133
  - 136
---

# Spec: Resolver Strategy Boundary

Status: Draft
Owner: core/resolver
Last reviewed: 2026-08-11

## Purpose

RPM resolves dependency requests before it fetches tarballs, extracts packages,
links `node_modules`, or writes `rpm.lock` and `package.json`. The resolver
boundary defines the internal contract for that phase so the first traversal
implementation can stay simple without becoming the long-term installer shape.

## Contract

The resolver consumes dependency requests and package metadata through explicit
abstractions. A dependency request includes the package name, the requested
range or version text, and a request kind. Request kinds distinguish direct
production dependencies, direct development dependencies, and transitive
dependencies discovered from package metadata. Only direct request kinds may
drive manifest dependency updates; transitive requests are graph inputs and must
not be treated as root manifest entries. Package metadata access supplies
available versions, dist metadata, and dependency declarations without
downloading or extracting tarballs as part of traversal.

The resolver produces a resolved dependency graph. Each resolved package record
preserves both the requested range and the selected version. The graph is the
input to later installer phases that download tarballs, verify integrity,
extract packages, link `node_modules`, and write lockfile or manifest state.

The resolved graph contains at most one record per `<name>@<version>`. A
package reached through several parents is merged into a single node, so a
shared transitive package/version is represented once even when it is reached
through different requested ranges. This node-uniqueness invariant is the basis
for the deduplication proofs in
`docs/specs/core/install/performance/SPEC.md`, and it is the reason later
installer phases may download and cache a selected version at most once.

Version and range satisfaction rules are owned by
`docs/specs/core/semver/SPEC.md`. Resolver strategies call the version
selection abstraction and record its selected version; they must not duplicate
range parsing policy in the traversal implementation.

### Package name parsing

A dependency request splits a single spec string into a package name and a
range. The split rule is the contract between CLI/manifest input, registry
lookup, lockfile keys, cache filenames, and linker paths, so each of those
consumers receives the same package name text.

- An unscoped spec splits on the last `@`. `socket-store@^1.0.0` yields the name
  `socket-store` and the range `^1.0.0`. A spec with no `@` yields the whole
  string as the name and an empty range.
- A scoped spec (`@scope/name`) splits on the first `@` that follows the scope
  separator `/`. `@scope/name@1.2.3` yields the name `@scope/name` and the range
  `1.2.3`; `@scope/name` with no trailing `@` yields the whole string as the
  name and an empty range. The leading `@` is part of the name, never the
  version separator, so scoped names round-trip through parsing unchanged.

The resolver boundary rejects npm alias declarations before it parses a spec as
an ordinary name/range request. A range that begins with the literal `npm:`
prefix (`foo@npm:bar@1.2.3`, including the scoped form
`@scope/foo@npm:bar@1.2.3`) is rejected as an input error with a typed error
naming the offending package and alias target, rather than being split into a
misleading request for a nonexistent package. This rejection contract and its
detection points are owned by
`docs/specs/core/registry/SPEC.md` ("Unsupported metadata behavior"). Active
alias consumption remains an Open Question there.

RPM does not today enforce full npm package-name syntax (length, allowed
characters, lowercase rule, scope/name balance). Parsing is structural: any
non-empty name that splits cleanly is accepted as a package name. Stricter name
validation is intentionally deferred until a name-validation contract owns the
accepted-form set and its error reporting; until then, parsing must not invent
ad hoc rejection rules that diverge across CLI, manifest, and registry
boundaries.

Traversal policy is behind a replaceable `ResolutionStrategy` boundary, or an
equivalent internal abstraction, owned by the `src/core/resolver` root module.
Concrete strategies may live in private child modules, but callers depend on
the resolver facade rather than a concrete queue or worklist type. The resolver
must not rely on recursive calls for correctness.

The first strategy is an iterative FIFO worklist:

1. Seed the worklist with direct dependency requests.
2. Pop the oldest pending request.
3. Read package metadata through the metadata abstraction.
4. Select a version through the version selection abstraction.
5. Add or merge the resolved package into the graph.
6. Enqueue that package's dependency requests as transitive requests.
7. Continue until the worklist is empty or resolution fails.

Future strategies may replace FIFO traversal with priority-based, heuristic,
peer-aware, or backtracking behavior without changing fetch, extract, link, or
lockfile write phases.

Before a peer-aware strategy exists, peer dependencies are represented as peer
requirement metadata on resolved package records or metadata records. They are
not direct dependency requests, transitive dependency requests, manifest update
inputs, or `node_modules` link targets by themselves. A non-peer-aware strategy
must not silently enqueue peer dependencies as ordinary dependencies. The
root-manifest read-and-preserve baseline for `peerDependencies` is owned by
`docs/specs/core/manifest/SPEC.md`; per-version peer dependencies on registry
packuments remain ignored at the registry boundary
(`docs/specs/core/registry/SPEC.md`).

The presence of an unmet peer requirement is not a resolution or install
failure under the non-peer-aware strategy. RPM performs no peer-set
enforcement, peer placement, or peer-conflict detection today: a package whose
`peerDependencies` target is absent, the wrong version, or otherwise
unsatisfied still selects, downloads, verifies, and links normally, and the
resolved graph contains only the package's ordinary dependencies. Peer
requirements do not appear in the lockfile
(`docs/specs/core/lockfile/SPEC.md`). Warnings or errors for unmet peer
requirements are deferred to a peer-aware strategy SPEC; until then, peer
metadata is observable only as preserved metadata, not as install output.
This is an intentional deferral, not an absence of policy: callers must not
infer that an install succeeded without peer warnings means the peer set is
satisfied.

Before an optional-aware strategy exists, optional dependencies are read and
preserved on the manifest and on registry metadata but are not direct dependency
requests, transitive dependency requests, or `node_modules` link targets. A
non-optional-aware strategy must not silently enqueue optional dependencies as
ordinary dependencies. The read-and-preserve baseline is owned by
`docs/specs/core/manifest/SPEC.md`; per-version optional dependencies on
registry packuments remain ignored at the registry boundary
(`docs/specs/core/registry/SPEC.md`).

The presence of an unsatisfiable or uninstalled optional dependency is not a
resolution or install failure under the non-optional-aware strategy. RPM
performs no optional-aware enqueueing, install attempt, skip, or reporting
today: a package whose `optionalDependencies` entry is absent, the wrong
version, or otherwise unsatisfiable still selects, downloads, verifies, and
links normally, and the resolved graph contains only the package's ordinary
dependencies. Optional dependencies do not appear in the lockfile
(`docs/specs/core/lockfile/SPEC.md`). This is an intentional deferral, not an
absence of policy: callers must not infer that an install succeeded without
optional-dependency warnings means the optional set is satisfied.

### Optional-aware strategy policy (deferred)

The contract below is reserved for the first optional-aware strategy SPEC that
consumes `optionalDependencies` as installable edges. It records the failure
mode for each optional-dependency lifecycle stage so a future optional-aware
resolver and installer do not have to re-derive the policy and cannot silently
choose a different one. Until that strategy exists, the non-optional-aware
behavior above is authoritative and this subsection imposes no new active
behavior.

| Optional dependency lifecycle stage | Failure policy |
| --- | --- |
| Resolution failure (unsatisfiable range, missing metadata, alias rejection) | Skip the optional entry and warn; the install must not fail |
| Download or integrity failure (network error, unsupported integrity, digest mismatch) | Skip the optional entry and warn; the install must not fail |
| Extract or link failure for the optional package | Skip the optional entry and warn; the install must not fail |
| Platform skip (engines/os/cpu mismatch when a platform-gating strategy owns it) | Skip the optional entry silently; platform-incompatible optional dependencies are expected and must not warn |

An optional dependency that succeeds through every reached stage is recorded in
the resolved graph and lockfile exactly like an ordinary dependency, with its
requested range and resolved version kept distinct
(`docs/specs/core/lockfile/SPEC.md`). A skipped optional dependency is not
recorded: the lockfile reflects the actually installed graph, not the requested
optional set, so a later install reproduces the same skip rather than re-attempting
an entry that was known to be uninstallable on this platform.

The determinism requirement below applies only to skip decisions driven by
deterministic inputs: a skip from an unsatisfiable range, missing metadata,
alias rejection, unsupported integrity, or platform mismatch must be reproducible
given the same metadata, registry state, and platform inputs, and must not
depend on iteration order or an uncontrolled clock. A skip from a transient
download or integrity failure (network error, digest mismatch) is a different
case: it must produce the same skip outcome and warn at the time of the failure,
but it is explicitly not required to be reproducible on the next install, because
the triggering input (registry availability, network state) is itself
non-deterministic. A later install must therefore be free to re-attempt an entry
that skipped only because of a transient failure; only entries that skipped for a
deterministic reason are expected to reproduce the skip.

Optional-dependency warnings and exit behavior are deferred to a diagnostics
SPEC (`docs/specs/core/lockfile/SPEC.md` records the lockfile deferral and
issue #151 tracks diagnostics ownership): a warning must not be exposed as
stable stderr or as a non-zero exit code until the owning diagnostics SPEC
exists.

The installer performance baseline in
`docs/specs/core/install/performance/SPEC.md`
documents the current recursive bottleneck and the measurement fixture for
future staged installer work.

## Error Cases

Resolution fails before installer side effects when package metadata is missing,
a requested range cannot be satisfied, dependency metadata is invalid, or the
strategy detects an unsupported graph condition. Failed resolution must not be
reported as a successful install, and it must not cause partial lockfile or
manifest writes.

M1 does not require a public structured diagnostic format for graph conflicts.
Resolver failures must still be typed internally enough for callers to
distinguish missing metadata, invalid metadata, unsatisfied ranges, invalid
ranges, and unsupported graph conditions. A public machine-readable diagnostic
format must be covered by an owning diagnostics SPEC before it becomes part of
RPM's user-facing or API-facing contract.

## Test Fixtures

Resolver tests should use offline registry metadata fixtures. Each fixture
should represent one graph scenario and include expected resolved package
records with requested range and selected version. Integration fixtures may add
expected lockfile snapshots or filesystem trees for later installer phases, but
resolver fixtures should not mutate the repository root, `.rpm`, `rpm.lock`, or
`node_modules`.

The semver baseline fixtures are defined by
`docs/specs/core/semver/SPEC.md` and must be used before installer flow relies
on semver range behavior.

### Optional-dependency non-enqueue guard fixture

The `registry/optional-preserve` fixture proves the current non-optional-aware
contract: a package whose only edge is an `optionalDependencies` entry resolves
without enqueueing the optional target and without failing resolution. It
mirrors the `registry/peer-preserve` fixture used for the peer non-enqueue
guard. This is current-behavior coverage, not optional-aware implementation.

### Planned optional-aware fixtures (for implementation follow-up)

The scenarios below are listed for the optional-aware strategy that first
consumes `optionalDependencies` as installable edges. They are not part of the
current non-optional-aware test set; each must be paired with an owning
implementation that follows the failure policy in
"Optional-aware strategy policy (deferred)":

- Successful optional dependency: the entry resolves, downloads, verifies, and
  links, and the lockfile records it like an ordinary dependency.
- Unavailable optional dependency (missing metadata or unsatisfiable range):
  resolution skips the entry and warns, the install succeeds, and the lockfile
  omits the skipped entry.
- Optional dependency download or integrity failure: the install skips the
  entry and warns, and the lockfile omits it.
- Optional dependency extract or link failure: the install skips the entry and
  warns, the rest of the install completes, and the lockfile omits it.
- Platform-incompatible optional dependency (once a platform-gating strategy
  exists): the entry is skipped silently and the lockfile omits it.
- Deterministic skip: the same metadata, registry state, and platform inputs
  produce the same skip decision across repeated installs.

## Resolved Follow-Up

ADR 0006 records the resolved #58 boundary decisions for
`ResolutionStrategy` ownership, pre-peer-aware dependency representation, and
M1 graph-conflict diagnostics.
