# Core SPECs

This directory holds core package-manager contract documents.

Core SPECs define behavior that must remain callable without CLI parsing or
terminal presentation. That includes manifest handling, semver policy,
dependency resolution, lockfile behavior, install staging, and linking.

Current core contracts:

- `manifest/SPEC.md`
- `semver/SPEC.md`
- `resolver/SPEC.md`
- `registry/SPEC.md`
- `lockfile/SPEC.md`
- `install/cache/SPEC.md`
- `install/recovery/SPEC.md`
- `install/performance/SPEC.md`
- `linker/SPEC.md`

## M4 Ownership and Gap Audit

The 2026-08-07 M4 audit maps each M4 behavior area to its owning SPEC/ADR and
records whether the contract is explicitly stated. M4 is a measurement and
deduplication milestone: it must observe duplicate graph nodes and duplicate
downloads deterministically before expanding npm compatibility or adding
concurrency. All follow-up tickets below landed and merged to `main`; M4 is
complete.

| M4 behavior area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| install pipeline shape | `install/performance/SPEC.md` | states the current recursive bottleneck and the future staged pipeline (resolve → dedupe → fetch → download → verify → extract → link → write) | none |
| resolver graph deduplication | `resolver/SPEC.md`, ADR 0006 | resolved graph preserves requested range and selected version; node uniqueness by `<name>@<version>` is stated in the resolver contract | closed by this audit |
| tarball download deduplication | `install/performance/SPEC.md`, `install/cache/SPEC.md` | performance SPEC states a selected version downloads once; cache SPEC's version-keyed filename `<name>@<version>.tgz` yields one cache file per selected version | none |
| cache behavior | `install/cache/SPEC.md` | staged write plus same-directory rename publication; metadata reads are side-effect free | none |
| lockfile preservation | `lockfile/SPEC.md` | `<name>@<version>` key; requested range and selected version recorded as separate fields | none |
| manifest reads | `manifest/SPEC.md` | `package.json` read and save contract | none |
| recovery behavior | `install/recovery/SPEC.md` | staged `node_modules` replacement, phase labels (`resolve|fetch|extract|link|write`), M3 and M4 side-effect audit tables | #96 added the M4 side-effect audit (completed, landed via #107) |
| measurement harness | `install/performance/SPEC.md`, ADR 0005 | harness records metadata fetch and tarball download counts through a fake registry API owned by the install domain | #93 added the metadata-read counter (completed, landed via #106); the tarball download counter landed in #103 |

Findings:

- Ownership exists for every M4 behavior area; no area is unowned.
- Graph node uniqueness was implied by the resolver merge step but was not
  stated as an invariant in the owning resolver SPEC. This audit adds the
  invariant there; the dedup behavior was already proven by the resolver test
  tracked by #94 (landed via #74). The download-dedup proof is a separate
  install-layer test landed in #103.
- The performance SPEC states the measurement-harness contract (metadata fetch
  and tarball download counts via a fake registry). Both counters are now
  implemented: the tarball download counter (#103) and the metadata-read
  counter (#93, landed via #106).
- The M4 delivery order was decomposed into phase-isolated tickets, all
  completed: #93 (measurement harness, landed via #106), #94 (graph dedup
  proof), #103 (download dedup proof), #96 (phase side-effect audit, landed
  via #107), and #97 (fixture output convention, landed via #108).

## M5 Ownership and Gap Audit

The M5 audit maps each npm metadata compatibility area to its owning SPEC/ADR
and records whether the contract is explicitly stated. M5 is an npm metadata
compatibility milestone: it must classify every registry metadata category as
consumed, ignored, or rejected before any category gains active behavior, so
RPM does not treat unsupported metadata as successful compatibility.

| M5 compatibility area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| registry metadata fields consumed by RPM | `registry/SPEC.md` | consumed / ignored / rejected classification is explicit (root `name`, `dist-tags`, `versions`; per-version `dependencies`, `dist`; `dist.tarball`, `dist.integrity`, `dist.shasum`); legacy single-version shape also consumes root `version`, `dist`, and `dependencies` as documented in the SPEC's "Legacy root fallbacks" section | delivered: #110 landed via #112 |
| ignored-field tolerant deserialization | `registry/SPEC.md` | every ignored metadata field deserializes leniently: a missing, null, or wrong-type value is discarded as absent rather than failing the packument, and `bundledDependencies` accepts map or array (applies uniformly to all ignored fields, not only the originally-tolerated set) | delivered: #113 landed via #116; uniform coverage landed via #122 |
| dist-tag and root metadata fallback gating | `registry/SPEC.md` | a dist-tag target absent from `versions` is rejected; root `dist` / `dependencies` fallback only applies to the legacy single-version shape | delivered: #114 landed via #118 |
| dist-tags / `latest` / semver range selection boundary | `registry/SPEC.md`, `semver/SPEC.md` | dist-tags are registry selectors, not semver ranges; `latest` and tag precedence over ranges is defined | none |
| build-metadata deterministic selection | `registry/SPEC.md` (Registry Boundary, precedence step 3) | registry-owned raw-key sort before `max_satisfying` makes selection repeatable across `HashMap` seedings | delivered: #115 / #117 landed |
| optionalDependencies | `registry/SPEC.md` (ignored list), `resolver/SPEC.md` (non-enqueue guard and deferred optional-aware policy), `manifest/SPEC.md` (root read/preserve) | classified as ignored at the registry boundary with the non-optional-aware non-enqueue guard; root manifest reads and preserves `optionalDependencies` without consuming them; the deferred optional-aware strategy policy (skip-and-warn on resolution/download/install failure, skip-silently on platform mismatch, record only successful installs) is now owned by the resolver and lockfile SPECs; active optional-aware resolution and reporting remain deferred | delivered: #133 |
| peerDependencies | `resolver/SPEC.md`, `registry/SPEC.md` (ignored list), `manifest/SPEC.md` (root read/preserve) | classified as ignored at the registry boundary with the non-peer-aware non-enqueue guard; root manifest reads and preserves `peerDependencies` without consuming them; active peer-aware resolution and active diagnostic emission are deferred, but the *shape* of peer-requirement diagnostics (missing-peer vs incompatible-range distinguishability, human-readable-only, exit codes / machine-readable output deferred to M8) is now owned by the resolver SPEC | delivered: #130 (read/preserve + non-enqueue); #135 (diagnostic shape) |
| engines, os, cpu | `registry/SPEC.md` (ignored list), `manifest/SPEC.md` (root read/preserve) | classified as ignored at the registry boundary with an explicit no-filtering/warning/rejection contract decision; root manifest reads and preserves npm-accurate `engines`/`os`/`cpu` without consuming them; active platform gating deferred | delivered: #127 |
| package bin metadata | `manifest/SPEC.md`, `registry/SPEC.md`, `linker/SPEC.md` | `.bin` generation and `bin` field interpretation (string vs object) are now owned by the linker, manifest, and registry SPECs; per-version `bin` is read and preserved for `.bin` generation | delivered: #139 |
| scoped package names | `resolver/SPEC.md`, `registry/SPEC.md`, `lockfile/SPEC.md`, `install/cache/SPEC.md`, `linker/SPEC.md` | scoped names are owned throughout: resolver splits `@scope/name` on the scope separator, registry consumes the scoped `name` and must percent-encode `/` as `%2F` only in the lookup path, lockfile and linker keep the raw scoped name, and the cache filename is the only place `/` is rewritten (to `-`); the `%2F` lookup-path code fix is tracked by a follow-up issue | delivered: #136 (contract); `%2F` code fix follow-up |
| npm aliases | `registry/SPEC.md` (Unsupported metadata behavior) | npm alias declarations (`npm:<name>@<version>` range values) are classified as rejected input errors and actively rejected at the dependency-declaration boundary for both root-manifest and transitive paths, with a typed error naming the offending package and alias target | delivered: #125 landed via #129 |

Findings:

- Ownership exists for the registry metadata boundary. The consumed / ignored /
  rejected classification landed in #112, and the deserialization behavior that
  the classification implies was made tolerant in #116 and gated against stale
  root fallbacks in #118.
- The dist-tag and semver range selection boundary is fully owned across
  `registry/SPEC.md` and `semver/SPEC.md`; the build-metadata deterministic
  tie-break closes the last selection-repeatability gap (#115 / #117).
- The remaining M5 frontier is per-field classification: package bin metadata
  still needs an active-behavior contract (or an explicit deferred decision)
  before implementation; it is represented by a compat draft task in Project #7.
  Optional dependencies (#133) now join peer dependencies (#130) and engines,
  OS, and CPU metadata (#127) with explicit deferred policies: the registry
  boundary classifies `optionalDependencies` as ignored with the
  non-optional-aware non-enqueue guard, the root manifest reads and preserves
  them without consuming them, and the resolver and lockfile SPECs own the
  reserved failure policy for a future optional-aware strategy. npm aliases
  (#125) now have both the classification and the active rejection landed (via
  #129). Scoped package and npm alias edge-case contracts (#136) are now
  explicit across resolver, registry, lockfile, cache, and linker ownership:
  scoped names split and round-trip verbatim everywhere except the one registry
  lookup path that must percent-encode `/` as `%2F`, and the cache filename that
  rewrites `/` to `-`; the `%2F` lookup-path code fix is tracked by a follow-up
  issue.
- Package `bin` metadata was deferred to the M6 linker milestone, where `.bin`
  generation is now owned; the M6 `.bin` and `bin` field contract landed in
  #139. It is listed here so the boundary is explicit.

## M6 Ownership and Gap Audit

The M6 audit maps each runtime-linking and lifecycle-script behavior area to its
owning SPEC/ADR and records whether the contract is explicitly stated. M6 is a
runtime usability milestone: it must make installed packages runnable in normal
Node workflows while keeping linker behavior separate from lifecycle/script
execution behavior. It must not fold resolver, cache, or npm metadata
compatibility expansion into runtime usability work. Every gap below is assigned
an owning SPEC and a follow-up ticket so `.bin` generation and lifecycle
behavior become SPEC-owned *before* implementation, satisfying the M6 exit
criteria.

| M6 behavior area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| package-local dependency links | `linker/SPEC.md` | unscoped and scoped (`@scope/name`) dependency symlinks are defined; raw scoped name is reused verbatim; filesystem failures are returned as errors | none |
| `.bin` generation | `linker/SPEC.md` | link layout is defined: one `node_modules/.bin/<name>` entry per exposed binary, pointing at the target file inside the installed package directory; lifecycle scripts are kept separate | delivered: #139 |
| `bin` field interpretation (string vs object form) | `manifest/SPEC.md`, `registry/SPEC.md` | both forms read and preserved: string form exposes one binary (unscoped = package name, scoped = unscoped name); object form uses map keys verbatim; wrong-type values discarded as absent | delivered: #139 |
| scoped vs unscoped binary links in `.bin` | `linker/SPEC.md` | binary-name mapping is defined: scoped string form drops the scope prefix, object form uses keys verbatim | delivered: #139 |
| executable shims / symlinks in `.bin` | `linker/SPEC.md` | `.bin` entries are symlinks on every platform; RPM does not synthesize or rewrite shebangs | delivered: #139 |
| platform considerations (`.cmd`, shebang) | `linker/SPEC.md` | explicitly deferred inside #139: the link layout is defined; Windows `.cmd`/`.ps1` shim generation, executable-bit handling, and permission normalization are deferred until a platform-packaging strategy SPEC (M10 / #163) owns them | delivered: #139 (active layout); deferred to M10 (platform shims) |
| `rpm run` PATH prepend | `cli/run/SPEC.md` | `rpm run` prepends the project `node_modules/.bin` to `PATH` and propagates the child exit code; running a script must not reinstall or mutate install output | none |
| missing `.bin` directory behavior in `rpm run` | `cli/run/SPEC.md` | the run SPEC assumes `.bin` is populated and does not own how it is populated (that is linker work), but it already owns the absent-binary case: a binary that is missing from `PATH` (including when `node_modules/.bin` is absent) must surface the shell's readable error and non-zero status (`cli/run/SPEC.md` Error Cases); #143 proves project-local binaries are reachable without mutating install output rather than redefining that existing behavior | #143 |
| lifecycle script fields (`preinstall`, `install`, `postinstall`, `prepare`, ...) | `registry/SPEC.md` (ignored per-version), `manifest/SPEC.md` (root field) | the registry SPEC already classifies per-version `scripts` as ignored metadata and requires no install behavior to depend on it, including tolerant wrong-type handling; what is unowned is active lifecycle execution — there is no field contract for which hook names run, in what order, with what environment — so #141 must explicitly update the registry contract (including its tolerant wrong-type behavior) before #142 consumes transitive scripts, rather than treating the field as absent from every SPEC | #141 |
| script command parsing | `cli/run/SPEC.md` (shell invocation only) | shell invocation is already owned for `rpm run`: scripts execute through the platform shell so command chaining, quoting, and environment assignment follow normal package-script semantics; what is unowned is the lifecycle-specific part — whether hook values are strings-only or arrays, and whether lifecycle hooks reuse the `rpm run` shell model or define a departure — so #141 must share or explicitly diverge from the existing run SPEC rather than create a second script-execution contract | #141 |
| lifecycle execution as an install phase | `install/recovery/SPEC.md` | absent from the phase pipeline: the recovery contract enforces `resolve`, `fetch`, `extract`, `link`, `write` labels and has no `scripts` phase | #141 |
| lifecycle script failure preserving install state | `install/recovery/SPEC.md` | no contract for rollback or partial-success prevention when a lifecycle script fails mid-install; the M3/M4 side-effect audit tables have no lifecycle row | #141 |

Findings:

- Runtime linking is split into an owned core and a now-contracted `.bin`
  frontier. Package-local dependency links (unscoped and scoped) are owned by
  `linker/SPEC.md` and needed no M6 contract change. `.bin` generation was the
  deferred frontier named in the linker SPEC's Out Of Scope section and in the
  M5 audit row above; #139 has now brought it under contract.
- The `.bin` cluster carried five related gaps (`.bin` generation, `bin` field
  interpretation, scoped vs unscoped binary links, shims/symlinks, platform
  considerations). #139 owned the `.bin` and `bin` contract as one unit so the
  link layout, the manifest field form, and the binary-name mapping were decided
  together before any linker implementation in #140. The symlink link layout is
  defined for every platform; platform-specific shim or `.cmd` behavior is
  explicitly deferred inside #139 until M10 / #163 owns a platform-packaging
  strategy.
- Lifecycle scripts are the larger ownership gap: they are not covered by an
  active execution SPEC. Per-version `scripts` are already classified as ignored
  registry metadata (`registry/SPEC.md`) and the manifest SPEC names `scripts` in
  its Purpose but defines no field contract, the recovery SPEC's phase pipeline
  has no `scripts` phase, and the M3/M4 side-effect audits have no lifecycle row.
  #141 owns the whole lifecycle cluster: supported phases, ordering, environment,
  PATH, failure behavior, and rollback expectations, plus the registry SPEC
  update that moves `scripts` from ignored to consumed (including its tolerant
  wrong-type behavior) before #142 consumes transitive scripts, and the recovery
  SPEC update that adds a `scripts` phase and the invariant that a failed script
  phase cannot publish partial successful install state.
- `rpm run` integration is mostly owned: `cli/run/SPEC.md` already prepends
  `node_modules/.bin` to PATH and propagates exit codes without reinstalling. The
  one remaining gap — behavior when `.bin` is absent — is owned by #143, which
  proves project-local binaries are reachable through `rpm run` without mutating
  install output.
- The delivery order follows the issue: (1) this contract and gap audit, (2) #139
  `.bin` and `bin` contract, (3) `.bin` fixture coverage, (4) #140 first `.bin`
  link forms, (5) #141 lifecycle policy, (6) #142 first lifecycle phase with
  failure-safe install state, (7) #143 `rpm run` PATH verification. Lifecycle
  behavior is kept separable from linker behavior throughout so #139/#140 can
  land without forcing #141/#142, and vice versa.
