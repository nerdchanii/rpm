---
spec_id: resolver_boundary
title: Resolver Strategy Boundary
status: draft
owner: core/resolver
last_reviewed: 2026-08-24
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
  - 135
  - 136
  - 145
  - 221
---

# Spec: Resolver Strategy Boundary

Status: Draft
Owner: core/resolver
Last reviewed: 2026-08-24

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

The resolver produces a resolved dependency graph. Each dependency edge
preserves its requested range or version text and request kind. Each resolved
package record continues to preserve its requested range and selected version;
the per-edge fields retain every incoming request when node deduplication leaves
one package record. Direct edges also preserve their root or member origin, and
transitive edges preserve their resolved parent. The graph is the input to later
installer phases that download tarballs, verify integrity, extract packages,
link `node_modules`, and write lockfile or manifest state.

The external-package portion of the resolved graph contains at most one record
per `<name>@<version>`. An external package reached through several parents is
merged into a single node, so a shared transitive package/version is represented
once even when it is reached through different requested ranges. Under the
planned workspace boundary, root and member resolution roots use origin
identities in a separate key domain: the project root uses the root identity and
each member uses its validated portable NFC UTF-8 `member_path_key`. A local
member and an external package must never merge, including when their package
names and version text are equal. This node-uniqueness invariant is the basis
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

### Workspace boundary (planned)

This subsection defines the resolver contract for the first workspace-aware
strategy. The current resolver has no member-table input or workspace-local
edge type, so these rules become active with that implementation and its
planned fixtures.

Workspace discovery is owned by
`docs/specs/core/manifest/SPEC.md`. The resolver consumes one validated discovery
result containing the immutable parsed root-manifest snapshot and an ordered
table of NFC-normalized UTF-8 `member_path_key` values with immutable parsed
member snapshots. Each snapshot includes the package name, declared version text
when present, and the parsed dependency maps used for request seeding. Native
paths, directory handles, and file identities remain manifest/filesystem-layer
validation data and are not resolver graph inputs. The resolver does not
re-expand globs, follow a second root, reopen a root or member manifest by path,
or infer members from registry metadata. The table must already satisfy
canonical-root confinement, structurally accepted non-empty and unique package
names, valid manifest snapshots, deduplicated portable keys, and stable unsigned
UTF-8 byte ordering.

The resolver keeps three identities distinct:

- the **root package**, whose manifest declares the workspace and whose direct
  dependency requests come from the immutable root snapshot and remain root
  requests;
- a **workspace member**, identified in the graph by its validated portable
  `member_path_key` and package name, carrying its immutable validated manifest
  snapshot and declared version text, and retaining that portable key as the
  member origin on its dependency requests;
- an **external package**, whose metadata is obtained through the external
  package boundary because no discovered member satisfies the edge.

The workspace-aware graph starts with an ordered set of resolution-root
records: the project root first, followed by every member in the discovery
table's stable order. Every discovered member is a resolution root even when
the project root has no dependency edge to it. A root record retains its root or
portable-member-key origin, package name, declared version text when present,
and direct dependency edges from the already validated snapshot; workspace
lockfile serialization of those records remains owned by #146. Native canonical
paths and native file/directory identities are used only by the descriptor-based
filesystem owner and must not be copied into graph node identity, request origin,
ordering, or equality. Neither the root nor a member manifest path is a resolver
input after discovery, so a rename or replacement between discovery and graph
seeding cannot change the requests in the operation.

The resolver seeds requests from both `dependencies` and `devDependencies` in
the project-root manifest and every member manifest. Seed order is root first,
then members in discovery order; within each manifest, production requests
precede development requests and package names are ordered by unsigned UTF-8
byte order without locale collation or case folding. When the same package name
appears in both maps of one manifest, the `dependencies` entry has precedence:
RPM emits exactly one `DirectProduction` request using its requested text and
does not emit the overlapping development entry. This precedence is applied
before workspace-local versus external classification, so two maps cannot send
one package name to conflicting local and external targets.
Production and development seeds retain `DirectProduction` and
`DirectDevelopment` request kinds respectively and carry a separate origin of
root or the member's portable `member_path_key`. Requests read from selected
external metadata remain `Transitive` and identify their resolved parent. Every
edge preserves that request kind, its requested range or version text, and its
origin or resolved parent independently of node deduplication. When several
root/member/transitive requests select one external `<name>@<version>` node,
merging the node must not merge or discard those per-edge fields. A dependency
reachable only from a member therefore cannot be omitted or mistaken for a
root-manifest entry.

A dependency-map declaration first becomes a `DependencyRequest` through the
resolver's existing parsing and request-normalization boundary. Empty range
text is normalized to `latest` before workspace classification, matching
`DependencyRequest::new` and the registry contract for bare requests. The
workspace branch therefore examines the canonical request text: an empty-range
declaration such as `"foo": ""` is the `latest` selector, not an any-version
semver range, and remains external because registry dist-tags have no local
member mapping. A dependency edge is classified against the discovered member
table before external metadata lookup. A name absent from the table is an
external edge. A name present in the table is workspace-local only when the
member has a valid declared semantic version and that version satisfies the
canonical, non-empty requested range under
`docs/specs/core/semver/SPEC.md`. A missing, invalid, or range-incompatible
member version leaves that edge external, allowing external metadata to select
a compatible package version. Registry dist-tags have no local member mapping
and remain external selectors. Invalid or unsupported request syntax still
fails under its owning input contract; it is not converted into a
workspace-local edge.

Resolution-root creation and edge classification are separate operations. RPM
creates every root/member resolution-root record and seeds that record's
snapshot dependencies exactly once during the ordered initial root-set pass.
For each later edge, it performs the member-name and range-compatibility branch
before calling a registry cache or metadata provider. A compatible local edge
attaches to the already-created member node identified by `member_path_key`; it
does not read external metadata, create another member root, enqueue the member
snapshot again, or replay that member's dependency maps. Multiple incoming
local edges share that existing member node. Only the absent-member,
missing/invalid/incompatible-member-version, and registry-dist-tag branches may
enter external metadata lookup and version selection.

Name collisions among members or between the root package and a member are
invalid discovery input and must fail before graph traversal. A missing or
malformed member supplied by the manifest boundary is likewise an input error,
not an external-package fallback. Package-name acceptance follows the same
current structural non-empty rule described under "Package name parsing";
workspace discovery and resolution must not add an independent syntax gate.

This issue defines identity and input boundaries only. Workspace lockfile
records and compatibility are owned by #146, local and external filesystem
links are owned by #147, and workspace command targeting is owned by #148.
Those follow-up contracts must consume the same member table and must not
redefine member order, root confinement, or local-versus-external identity.

Resolver graph construction does not schedule lifecycle scripts. Workspace
lifecycle activation remains disabled and is owned by #222.

Traversal policy is behind a replaceable `ResolutionStrategy` boundary, or an
equivalent internal abstraction, owned by the `src/core/resolver` root module.
Concrete strategies may live in private child modules, but callers depend on
the resolver facade rather than a concrete queue or worklist type. The resolver
must not rely on recursive calls for correctness.

The first strategy is an iterative FIFO worklist:

1. Seed the worklist with the deterministic root and member direct-request
   sequence defined by the workspace boundary; a root-only project supplies
   only the project-root sequence.
2. Pop the oldest pending request.
3. Apply the workspace-local classification branch defined above. When a
   compatible member satisfies the request, attach the edge to that existing
   member resolution-root node and continue with the next pending request. This
   branch performs no registry/cache metadata read, external version selection,
   member-root creation, or member dependency reseeding.
4. For an external branch only, read package metadata through the metadata
   abstraction.
5. Select an external version through the version selection abstraction.
6. Add or merge the resolved external package into the graph.
7. Enqueue that external package's dependency requests as transitive requests.
8. Continue until the worklist is empty or resolution fails.

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

### Peer-requirement diagnostics ownership

Peer-requirement diagnostics are owned by this SPEC (the resolver boundary) so
that the future human-readable output for peer requirements and conflicts does
not have to be re-derived by, and cannot silently diverge across, the CLI, the
registry boundary, the manifest reader, or the lockfile writer. The ownership
is over the *shape* of the diagnostics, not over an active emitter today: under
the non-peer-aware strategy no peer diagnostic is emitted at all (see the
non-emission policy above). The first peer-aware strategy SPEC that consumes
`peerDependencies` as enforced edges owns the active emission — which command
phases emit, how often, and in what order — and must follow the shape defined
here.

Peer-requirement diagnostics must keep two cases distinguishable in the
information they carry, regardless of output format:

- **Missing peer** — a declared `peerDependencies` entry whose target package is
  absent from the resolved graph (no version selected, no install record).
- **Incompatible peer range** — a declared `peerDependencies` entry whose target
  package *is* present in the resolved graph, but at a version that does not
  satisfy the peer's requested range.

A diagnostic for either case must name the declaring package, the peer target
package, and the peer's requested range; an incompatible-range diagnostic must
additionally name the resolved version that failed to satisfy it. The two cases
must not collapse into a single generic "peer problem" message: a missing peer
and an incompatible peer range imply different user actions (install the peer
vs change the peer's version), so the diagnostic shape must preserve the
distinction even when the human-readable wording is later stabilized.

Only human-readable diagnostics are in scope for the peer-aware strategy's first
output. A diagnostic line is a single line of UTF-8 text on stderr, addressed to
a human reader; it is not a stable API. Stable exit codes, structured
machine-readable output (JSON or otherwise), stdout/stderr channel ownership
beyond "diagnostics go to stderr", and a stable diagnostic envelope/category
taxonomy are owned by the M8 diagnostics contract (issues #150 and #151) and
must not be introduced through the peer-aware strategy SPEC. In particular: a
peer-requirement diagnostic must not be exposed as a stable non-zero exit code,
and no field name, key, or JSON shape emitted for peer diagnostics may be
treated as a public contract, until the owning diagnostics SPEC exists.

The human-readable wording itself is intentionally not frozen. A golden-output
fixture for peer diagnostics must assert only the distinguishable information
above (declaring package, peer target, requested range, and — for the
incompatible case — the resolved version) plus that the output is a single line
on stderr; it must not assert the exact prose, punctuation, or ordering of
fields, so the diagnostics contract can still stabilize wording later without
breaking peer-aware coverage. Once the M8 diagnostics contract stabilizes a
diagnostic envelope, the peer-aware strategy SPEC must adopt it and this
wording-not-frozen allowance is superseded for any field the envelope covers.

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
records with selected versions and expected edges with requested ranges and
request kinds. Integration fixtures may add
expected lockfile snapshots or filesystem trees for later installer phases, but
resolver fixtures should not mutate the repository root, `.rpm`, `rpm.lock`, or
`node_modules`.

The semver baseline fixtures are defined by
`docs/specs/core/semver/SPEC.md` and must be used before installer flow relies
on semver range behavior.

### Workspace boundary fixtures

Planned offline resolver coverage includes a root package with two ordered
workspace members, a satisfying workspace-local dependency edge, a same-name
member whose incompatible version falls back to an external compatible
version, and a member-only external edge when the project root has no dependency
on either the member or its dependency. That member-only fixture records the
member origin and proves production and development seeds retain their distinct
direct request kinds. A shared-external-node fixture has two members request
different ranges that select the same `<name>@<version>`, with one production
edge and one development edge. It proves both edges retain their own requested
range, distinct direct request kind, and member origin after node deduplication.
A shared-transitive-node fixture routes different requested ranges through two
resolved external parents to the same selected
`<name>@<version>` and proves both `Transitive` edges retain their own requested
range and resolved parent. Coverage also keeps a local member node distinct
from an external node with equal name and version text, preserves the same
deterministic member ordering for external edges, rejects duplicate member
names and root/member name collisions, and rejects a discovery result that
escapes the canonical root. An inter-phase replacement case proves request
seeding consumes the immutable root/member snapshots without reopening either
path. Equivalent
POSIX and Windows native path fixtures prove graph identity, request origin, and
ordering use the same NFC `/`-separated `member_path_key` and never a native
canonical path or separator. Overlapping `dependencies` and `devDependencies`
cases use ranges that would otherwise select different local/external targets
and prove the production declaration wins with exactly one `DirectProduction`
request. An empty-range request such as `"foo": ""` is normalized to `latest`
before classification and remains external, while an explicit satisfying
semver range for the same member is classified local. A local-branch fixture
uses a metadata provider that records every
request and fails if queried for a compatible member; multiple root/member
edges target the same compatible member and prove that its resolution root and
snapshot dependency seeds are created exactly once. Paired incompatible and
dist-tag cases prove only those external branches reach metadata lookup.
Resolver workspace fixtures stop at graph construction. Lifecycle activation
and its fixtures remain deferred to #222.

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

### Planned peer-requirement diagnostic fixtures (for implementation follow-up)

The scenarios below are listed for the first peer-aware strategy that emits
peer-requirement diagnostics. They are not part of the current non-peer-aware
test set (which emits no peer diagnostic at all); each must be paired with an
owning peer-aware implementation that follows the shape in "Peer-requirement
diagnostics ownership":

- Missing peer: a package declares a `peerDependencies` entry whose target is
  absent from the resolved graph; the diagnostic names the declaring package,
  the missing peer target, and the requested range, and the case is
  distinguishable from an incompatible range.
- Incompatible peer range: a package declares a `peerDependencies` entry whose
  target is present in the resolved graph at a version that does not satisfy
  the requested range; the diagnostic additionally names the resolved version.
- Deferred / unsupported peer-aware resolution: under the current
  non-peer-aware strategy, the same inputs produce no peer diagnostic at all,
  proving that peer-requirement diagnostics are gated on a peer-aware strategy
  and do not leak out of the non-peer-aware path.

A golden-output assertion for any of the above must follow the
wording-not-frozen policy: assert only the distinguishable information and that
the output is a single line on stderr, not exact prose.

## Resolved Follow-Up

ADR 0006 records the resolved #58 boundary decisions for
`ResolutionStrategy` ownership, pre-peer-aware dependency representation, and
M1 graph-conflict diagnostics.
