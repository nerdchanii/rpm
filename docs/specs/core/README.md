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
- `install/scripts/SPEC.md`
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
| lifecycle script fields (`preinstall`, `install`, `postinstall`, `prepare`, ...) | `registry/SPEC.md` (per-version read/preserve), `manifest/SPEC.md` (root read/preserve), `install/scripts/SPEC.md` (active execution) | per-version `scripts` is now read and preserved as a `string -> string` map at the registry boundary (moved out of the ignored list, with tolerant wrong-type handling kept) and the root `scripts` map is read and preserved by the manifest SPEC; active lifecycle execution is owned by `install/scripts/SPEC.md`, which fixes the supported hook names (`preinstall`, `install`, `postinstall`, `prepare`), the `string -> string` value type, and the working-directory and PATH policy | delivered: #141 |
| script command parsing | `cli/run/SPEC.md` (shell invocation model), `install/scripts/SPEC.md` (lifecycle reuse) | lifecycle hook values are strings-only and reuse the `rpm run` shell invocation model (`/bin/sh -c` on Unix, `cmd /C` on Windows) and the same `node_modules/.bin` PATH prepend, so there is a single script-execution contract rather than two; the relationship is made explicit in both `cli/run/SPEC.md` and `install/scripts/SPEC.md` | delivered: #141 |
| lifecycle execution as an install phase | `install/recovery/SPEC.md`, `install/scripts/SPEC.md` | the recovery phase pipeline now includes a `scripts` phase between `link` and `write`, with the phase label and position contracted in `install/recovery/SPEC.md`; the within-package ordering (`preinstall`, `install`, `postinstall`, `prepare`) is owned by `install/scripts/SPEC.md`; active execution is deferred to #142 | delivered: #141 (contract); #142 (execution) |
| lifecycle script failure preserving install state | `install/recovery/SPEC.md`, `install/scripts/SPEC.md` | a failed `scripts` phase cannot publish partial successful install state: it runs between `link` and `write`, so the staged tree is discarded and the previous `node_modules`, `rpm.lock`, and `package.json` remain unchanged; the invariant is stated in both SPECs and an M6 lifecycle row is added to the recovery side-effect audit | delivered: #141 |

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
- Lifecycle scripts are now under contract. Per-version `scripts` was previously
  classified as ignored registry metadata and the manifest SPEC named `scripts`
  in its Purpose but defined no field contract; the recovery phase pipeline had
  no `scripts` phase, and the M3/M4 side-effect audits had no lifecycle row.
  #141 has delivered the whole lifecycle cluster: supported phases (`preinstall`,
  `install`, `postinstall`, `prepare`), within-package ordering, the
  `string -> string` value type, working-directory and PATH policy, failure
  behavior, and the rollback invariant that a failed `scripts` phase cannot
  publish partial successful install state. The registry SPEC moves per-version
  `scripts` out of the ignored list to read-and-preserve (with tolerant
  wrong-type handling kept), the recovery SPEC adds a `scripts` phase between
  `link` and `write` plus an M6 lifecycle side-effect row, and the run SPEC
  records that lifecycle execution reuses the `rpm run` shell invocation model
  rather than defining a second one. Active execution of the first phase is
  tracked by #142; cross-package ordering, npm-specific environment variables,
  and any opt-in skip-on-failure policy remain Open Questions in
  `install/scripts/SPEC.md`.
- `rpm run` integration is mostly owned: `cli/run/SPEC.md` already prepends
  `node_modules/.bin` to PATH and propagates exit codes without reinstalling. The
  one remaining gap — behavior when `.bin` is absent — is owned by #143, which
  proves project-local binaries are reachable through `rpm run` without mutating
  install output.
- The delivery order follows the issue: (1) this contract and gap audit, (2) #139
  `.bin` and `bin` contract, (3) `.bin` fixture coverage, (4) #140 first `.bin`
  link forms, (5) #141 lifecycle policy (delivered), (6) #142 first lifecycle
  phase with failure-safe install state, (7) #143 `rpm run` PATH verification.
  Lifecycle behavior is kept separable from linker behavior throughout so
  #139/#140 can land without forcing #141/#142, and vice versa.
## M8 Ownership and Gap Audit

The M8 audit maps each CLI diagnostics, exit-code, stdout/stderr, config, and
CI-friendly install behavior area to its owning SPEC/ADR and records whether the
contract is explicitly stated. M8 is a user-facing CLI stability milestone: it
must convert internal failure classes into stable command behavior — diagnostic
envelope, exit-code mapping, channel ownership, config precedence, and
frozen/lockfile-only install modes — before command expansion such as `remove`
or `update`, because those commands need stable stdout/stderr ownership, exit
codes, configuration precedence, and lockfile mutation policy before they can be
implemented safely. It must not fold workspace implementation, raw performance
concurrency claims, release packaging, or new package-manager semantics into
diagnostics work. Every gap below is assigned to an owning SPEC and a follow-up
ticket so the diagnostic and install-mode surface becomes SPEC-owned *before*
implementation, satisfying the M8 exit criteria.

Today the public diagnostics surface is an ad hoc convention, not a contract.
`rpm` exits through `std::process::ExitCode`: RPM-generated command outcomes
currently collapse to `0`/`1`, while `rpm run` preserves the child process
status through `std::process::exit(status)`; StructOpt owns parser-generated
help, version, and argument-error exits and their output channels. ADR 0002
assigns terminal presentation and exit-code mapping to the CLI and requires
resolver/core code to remain callable without terminal I/O. Core progress paths
include `src/lib/command/working_process/add.rs`, `src/lib/node_linker/mod.rs`,
and `src/lib/package_manifest/mod.rs`; `src/lib/command/working_process/run.rs`
prints `Running script`, while `src/main.rs` emits install/timing output and
errors at the CLI boundary. Failure classes are typed internally — `ResolutionError`
distinguishes missing metadata, version selection, invalid declarations,
missing parents, and npm alias rejection (`docs/specs/core/resolver/SPEC.md`) —
but installer phase failures are formatted `io::Error` prose from `phase_error`,
not a typed enum (`src/lib/command/working_process/add.rs`,
`src/lib/node_linker/mod.rs`). The direct core/library output is an existing
ADR 0002 boundary violation. No contract maps these classes to stable
diagnostic categories or channel ownership; this audit records that absence as
intentional deferral and assigns each gap an owner rather than treating it as
implicit scope.

| M8 behavior area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| diagnostic envelope and category taxonomy | ADR 0002 (CLI/core presentation boundary); `cli/run/SPEC.md` owns only `rpm run` output; resolver owns typed internal failure classes while recovery owns phase labels | absent: there is no cross-command diagnostic envelope, category taxonomy, or stable human-output shape; `ResolutionError` variants are typed, while installer phase failures remain formatted `io::Error` prose | #151 |
| exit-code matrix | ADR 0002 and `src/main.rs` own CLI presentation: RPM-generated `0`/`1` outcomes and `rpm run` child-status passthrough; StructOpt owns parser help/version/error exits and channels | absent: no SPEC maps resolver failure classes or installer phase failures (including `integrity`) to stable non-zero exit codes beyond the current binary outcomes | #151 |
| stdout/stderr channel ownership | ADR 0002 owns the CLI/core boundary; core progress paths are `working_process/add.rs`, `node_linker/mod.rs`, and `package_manifest/mod.rs`; `working_process/run.rs` prints `Running script`; `src/main.rs` emits install/timing and errors; StructOpt owns parser output channels | absent as a cross-command contract: no SPEC states which human output belongs on stdout, which diagnostics go to stderr, or how machine-readable output is separated; direct core/library output is an existing ADR 0002 boundary violation | #151 |
| golden output fixture policy | none today; resolver and recovery SPECs list offline fixtures for behavior but not output wording | absent: no SPEC states how golden stdout/stderr snapshots are pinned (full-text vs information-only assertions), so future stabilization risks freezing unstable prose; the resolver peer-diagnostic "wording-not-frozen" policy is the only precedent and is explicitly superseded once this exists | #151 |
| machine-readable output (JSON or otherwise) | none today | explicitly deferred: no SPEC owns whether/when machine-readable output is added; resolver and peer-diagnostic contracts gate all structured output on "an owning diagnostics SPEC" existing first, so this audit records the dependency rather than introducing a shape | #151 |
| resolver failure diagnostics | `resolver/SPEC.md` (typed internal classes), `cli/run/SPEC.md` (run only) | partially owned internally: `ResolutionError` already distinguishes missing metadata, version selection, invalid declarations, missing parents, and npm alias rejection, and the SPEC requires failures stay typed enough to distinguish them; what is unowned is the stable human-readable mapping and exit code for each | #151 (envelope), then #152 (implementation) |
| installer phase failure diagnostics | `install/recovery/SPEC.md` (phase labels and side effects `resolve|fetch|extract|link|scripts|write`), `install/performance/SPEC.md` and `registry/SPEC.md` (integrity verification/error behavior), `install/cache/SPEC.md` (cache failure context) | partially owned internally: recovery contracts the phase labels and side effects, while performance and registry contracts own integrity verification/error behavior; what is unowned is the stable diagnostic envelope and exit-code mapping, with #154 assigned the structured installer error implementation | #151 (envelope), then #154 (structured error implementation) |
| config file discovery | none today; no config file is read by any command | absent: no SPEC owns whether RPM reads a config file, where it is discovered (project-local, user-global), or how discovery interacts with the manifest and lockfile; `manifest/SPEC.md` owns `package.json` but declares no RPM config field | #153 |
| environment variable precedence | none today; the only `RPM_*` variable is `RPM_REGISTRY_FIXTURE_ROOT`, which is test-only (`#[cfg(test)]`-gated in the fake registry API) and is not a public config surface | absent: no SPEC owns which environment variables are public, how they rank against a config file and command-line flags, or how invalid values fail; the test-only fixture root is explicitly not a config contract | #153 |
| supported config keys and invalid-value behavior | none today | absent: no SPEC lists supported config keys or defines whether unsupported keys and invalid values fail or warn; config must not be added before each key has owning behavior in install/cache/recovery/diagnostics SPECs | #153 |
| frozen install mode | none today; `install()` always re-resolves from `package.json` against `rpm.lock` (`src/lib/command/working_process/install.rs`); there is no `--frozen` flag or lockfile-as-authority policy | absent: no SPEC owns a mode where install refuses to mutate `rpm.lock` or `package.json` and fails on drift between manifest and lockfile, which CI reproducibility requires | #155 |
| lockfile-only install mode | none today; there is no mode that installs strictly from `rpm.lock` without consulting `package.json` ranges | absent: no SPEC owns a mode where the lockfile is the sole dependency authority and manifest ranges are not re-resolved | #155 |
| lockfile mutation policy per mode | `lockfile/SPEC.md` (v1 format and save contract), `install/recovery/SPEC.md` (backup/restore on write) | owned for the default path: saving writes the complete lockfile with backup/restore; what is unowned is how frozen and lockfile-only modes change that policy (forbid writes, forbid drift, fail vs update) | #155 |
| `remove`, `list`, and `version` command CLI contracts | none today; `Command::Remove`, `Command::List`, and `Command::Version` are declared or parser-visible but lack owning CLI contracts (unimplemented branches remain inert) | absent: no SPEC owns their argument handling, output, lockfile/manifest mutation, exit behavior, or diagnostics; each command waits for an owning CLI SPEC built on the M8 diagnostics and exit-code contract | future CLI SPEC (post-#151) |
| `update` command CLI contract | none today; there is no `update` command in `Command` and no owning CLI SPEC | absent: no SPEC owns `rpm update` argument handling, range refresh policy, lockfile mutation, or diagnostics; it is out of scope for M8 beyond recording that command expansion must follow the diagnostics and config contracts | future CLI SPEC (post-#151, #153, #155) |
| diagnostic envelope relationship to peer/optional diagnostics | `resolver/SPEC.md` ("Peer-requirement diagnostics ownership", optional-aware warnings deferral) | peer-requirement diagnostics are shape-gated on this envelope; optional-aware behavior remains deferred with only stable stderr and non-zero exit requirements reserved for its future contract | #151 (defines the envelope the resolver SPEC depends on) |

Findings:

- The public diagnostics surface is the largest M8 gap: it is a code
  convention, not a contract. RPM-generated exit codes are binary
  (`SUCCESS`/`FAILURE`) while `rpm run` passes through its child status, and
  output is unstructured prose on whichever stream the emitters reach. No SPEC
  owns categories, an envelope, or golden-output policy. `ResolutionError` is
  typed; installer phase failures remain formatted `io::Error` prose even where
  integrity behavior is contract-owned, so #151 defines the envelope and #154
  owns the structured installer error implementation.
- The diagnostics envelope is the M8 foundation: #152 (resolver failure
  diagnostics) and #154 (installer phase diagnostics) both depend on #151, and
  the resolver SPEC's peer-requirement diagnostic shape is explicitly gated on
  "the owning diagnostics SPEC" existing first. Optional-aware behavior keeps
  only stable stderr and non-zero exit requirements deferred until its own
  contract. #151 must be delivered before active diagnostic stabilization so
  wording and exit codes are intentional rather than frozen ad hoc.
- Config precedence (#153) is a separate foundation: it must define discovery
  (config file, environment variables, command-line override), supported keys,
  and invalid-value behavior before any command reads a config. The only
  `RPM_*` variable today is test-only (`RPM_REGISTRY_FIXTURE_ROOT`) and is
  explicitly not a public config surface; #153 owns the first public one.
- Frozen and lockfile-only install modes (#155) are CI-reproducibility
  contracts: they define when install may mutate `rpm.lock` and
  `package.json`, and how manifest/lockfile drift fails. The default
  install/recovery contract already owns backup/restore and the save policy;
  #155 owns how the two CI modes depart from that default (forbid writes,
  forbid drift). #155 depends on #151 because frozen-mode drift failures must
  surface as stable diagnostics and exit codes, not new ad hoc prose.
- Command expansion (`remove`, `list`, `version`, `update`) is intentionally
  kept behind owning CLI SPECs that build on the M8 contracts. These commands
  need stable stdout/stderr ownership, exit codes, config precedence, and
  lockfile mutation policy before implementation, so they are out of scope for
  M8 beyond this audit recording that the contracts must precede them.
- Machine-readable output is explicitly deferred, not silently absent: the
  resolver SPEC gates all structured peer-diagnostic output on this audit's
  owning diagnostics SPEC existing first, and #151 must decide whether
  machine-readable output is supported now or explicitly deferred. This audit
  introduces no JSON shape, field name, or key.
- The delivery order follows the issue: (1) this contract and gap audit,
  (2) #151 diagnostic envelope, exit codes, and human output, (3) #153 config
  file and environment variable precedence, (4) #155 frozen and lockfile-only
  install modes, (5) #152 stable resolver failure diagnostics, (6) #154 stable
  installer phase failure diagnostics, (7) golden stdout/stderr fixtures where
  behavior becomes stable. Diagnostics envelope work precedes config and
  install-mode work where they intersect, and precedes all command expansion.

## M7 Ownership and Gap Audit

The M7 audit maps each npm workspace behavior area to its owning SPEC/ADR and
records whether the contract is explicitly stated. M7 is a workspace support
milestone: it must add multi-package repository support without weakening root
safety rules, lockfile reproducibility, or the strict per-package dependency
visibility contract owned by `linker/SPEC.md`. It must not fold resolver
strategy changes, cache behavior, npm metadata compatibility, or runtime
linking changes into workspace work. Every gap below is assigned an owning SPEC
and a follow-up ticket so workspace behavior becomes SPEC-owned *before*
implementation, satisfying the M7 exit criteria.

Workspace implementation remains a greenfield gap: no code path reads the
`workspaces` field, no workspace-vs-external distinction exists in the
lockfile, the linker creates only registry-resolved dependency links, and no
CLI flag targets a workspace. The planned manifest-discovery and resolver
boundary contracts are now defined by #145; their implementation and fixtures
remain deferred to #221. Issues #146-#149 own later lockfile, linker, CLI, and
integration-fixture work. Workspace lifecycle/recovery activation remains
disabled and is owned separately by #222.

| M7 behavior area | Owning SPEC / ADR | Contract status | Follow-up |
| --- | --- | --- | --- |
| workspace manifest declaration (`workspaces` field) | `manifest/SPEC.md` | contract defined, implementation deferred: array and `{ "packages": [...] }` forms, descriptor-rooted root/member snapshots, single-link manifest identity, preservation-before-write, and planned replacement/hard-link coverage are specified; current manifest code still does not read or preserve the field | #221 |
| workspace glob expansion and member discovery | `manifest/SPEC.md` | contract defined, implementation deferred: the portable glob dialect, candidate selection, canonical-root and symlink confinement, install-artifact exclusions, NFC `/`-separated UTF-8 member keys across POSIX/Windows native paths, and planned fixtures are specified | #221 |
| root vs workspace vs external package boundary | `manifest/SPEC.md`, `resolver/SPEC.md` | contract defined, implementation deferred: immutable root/member dependency snapshots, portable `member_path_key` graph origin, production-over-development overlap precedence, compatible-range local classification, external fallback, and native identity restricted to filesystem validation are specified | #221 |
| workspace package lockfile records | `lockfile/SPEC.md` | absent: lockfile v1 keys every entry by `<name>@<version>` with registry metadata and records no local-path or workspace-origin marker; local workspace records need not require tarball or integrity, while external records may use `shasum` when integrity is absent; whether v1 extends safely or a version bump is required is an open question for #146 | #146 |
| external dependency edges under a workspace root | `lockfile/SPEC.md`, `resolver/SPEC.md` | partially owned in the non-workspace case: the resolver already deduplicates by `<name>@<version>` and the lockfile records requested range and resolved version distinctly, but neither owns how a shared external transitive reached from several workspace members is represented when each member requests a different range | #146 |
| workspace-to-workspace linking (local symlink) | `linker/SPEC.md` | absent: the linker creates symlinks whose targets are extracted registry packages under `node_modules/`; there is no contract for linking a workspace member that exists as a local source directory rather than a downloaded tarball, or for confining that target to the canonical workspace root | #147 |
| workspace-to-external linking | `linker/SPEC.md` | code and SPEC currently diverge on strict per-package dependency visibility; #147 must reconcile the implementation first, then extend the strict contract to workspace members so a member's `node_modules` exposes only that member's declared dependencies, with regression coverage | #147 |
| missing workspace link target | `linker/SPEC.md` | absent: the linker already fails when a registry dependency target is not extracted, but there is no contract for a workspace dependency whose declared local path does not exist or does not contain the expected package | #147 |
| workspace member writes and recovery | `install/recovery/SPEC.md`, `install/scripts/SPEC.md`, `linker/SPEC.md` | planned split defined: #147 owns workspace link construction; #222 owns an exclusive full-target publication guard, post-acquisition drift validation, one all-output transaction record, backup retention through final verification, exact multi-output rollback, and boundary-race fixtures | #147; #222 |
| workspace member lifecycle scripts | `install/scripts/SPEC.md`, `install/recovery/SPEC.md` | planned contract defined, implementation disabled: immutable root/member snapshot sourcing, portable order/origin, exact staged-member parent/name mapping, full no-follow managed-tree scans at every hook boundary, process-confined source overlays, frozen `workspaces`, and fatal transaction recovery are specified | #222; #147 is a staging prerequisite and #149 does not own these fixtures |
| package-name and dependency-name root confinement | `resolver/SPEC.md`, `linker/SPEC.md` | existing package metadata and lockfile names are not fully confined before extraction and dependency linking; names such as `../../outside` can escape the staged tree, so the resolver/linker boundary must reject traversal and verify canonical destinations before any write; #147 must include this regression coverage for workspace and external edges | #147 |
| workspace member binary links | `linker/SPEC.md` | absent: the existing `.bin` contract does not state whether a workspace member's `bin` field is exposed; #147 must decide the link layout and cover it in the minimal workspace fixture (#149) | #147; #149 |
| workspace command targeting (`--workspace`, `--all`, root) | `cli/run/SPEC.md` and future CLI command SPECs | absent: no command targeting contract exists; `rpm run` reads only the root manifest, and there is no rule for root-only, all-workspace, or selected-workspace command scope | #148 |
| partial workspace failure and exit behavior | `cli/run/SPEC.md` (deferred to M8 for stable exit codes) | absent: no contract for how a command behaves when one workspace member fails and others succeed; stable exit codes and stdout/stderr ownership for this are owned by the M8 diagnostics contract (#150, #151) before they become public | #148 (targeting); M8 (exit-code stability) |

Findings:

- Workspace implementation remains a greenfield gap across manifest, resolver,
  lockfile, linker, and CLI, and every executable fixture is still single-root.
  The manifest and resolver SPECs now own the planned `workspaces` contract, so
  follow-up work starts from defined inputs and identities instead of an
  implicit frontier.
- The discovery boundary (#145) defines supported declarations, portable glob
  expansion, invalid-member behavior, canonical-root confinement, deterministic
  Unicode member keys, no-follow single-link root/member snapshots, portable
  graph origins, member resolution-root seeding, and local-versus-external edge
  classification. #221 owns its implementation and executable fixtures. #146,
  #147, and #148 must consume the same member table and origin model without
  redefining them.
- Workspace-member lifecycle activation is owned by #222. The install-script
  and recovery contracts fix validated snapshot sourcing, deterministic order,
  isolated staged directories with exact key-to-parent/name validation, full
  hook-boundary managed-tree scans, process-confined source overlays, frozen
  workspace identity, an exclusive full-publication guard, one multi-output
  transaction record, PATH, and exact failure recovery. #222 consumes the staged
  link construction from #147 and owns the order/cwd, mutation, publication,
  race, and recovery fixtures before any member hook runs. #149's minimal install
  fixture does not absorb this lifecycle coverage.
- Lockfile representation (#146) carries one open compatibility decision:
  whether workspace package records can extend lockfile v1 with a local-origin
  marker, or whether a workspace-aware lockfile requires a version bump and a
  migration note. That decision belongs to #146, not to this audit; the audit
  only records that v1 has no such marker today.
- Linker ownership (#147) splits cleanly: workspace-to-external linking must
  first reconcile the current code/SPEC mismatch on strict dependency
  visibility, while workspace-to-workspace linking is new and must define
  local symlink targets, traversal guards for member-controlled paths, and the
  missing-target failure. Member-local writes must remain inside root staging
  and rollback. The linker's existing `.bin` generation
  (`linker/SPEC.md` "Executable bin links") also needs a workspace-member
  decision and fixture coverage (#149).
- CLI targeting (#148) depends on #145 but not on #146 or #147: command
  targeting semantics (root, all, selected, unsupported selector) can be
  specified as soon as discovery is owned. Partial-failure exit behavior is
  explicitly aligned to M8 (#150, #151): this audit does not introduce stable
  exit codes or stdout/stderr ownership for workspace commands, because that
  ownership belongs to the diagnostics contract.
- Root safety rules remain an explicit constraint and include existing package
  metadata and dependency-name traversal risks. The M3/M4 staged-replacement
  and side-effect audit guarantees (`install/recovery/SPEC.md`) apply to a
  workspace install, while the current resolver/linker escape paths require
  follow-up hardening before that guarantee is complete. A workspace install
  is still intended to be one staged root/member transaction; the added risks
  are member-controlled local paths reaching the linker and lifecycle writes
  escaping the staged execution views, which #147/#222 must confine and recover.
- The delivery order follows the issue: (1) this contract and gap audit, (2)
  #145 workspace discovery and root boundaries, (3) #146 lockfile records and
  external edges, (4) #147 workspace dependency linking, (5) #148 command
  targeting, (6) a minimal two-package workspace fixture (#149) with
  reviewable expected output, (7) discovery/resolver implementation under #221,
  and (8) workspace lifecycle/recovery integration under #222 after its fixtures
  exist. Discovery and lockfile work is kept separable from linker work so #221
  and #146 can land without forcing #147, and CLI targeting (#148) can land
  after the discovery contract lands.
