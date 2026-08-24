---
spec_id: install_lifecycle_scripts
title: Install Lifecycle Scripts
status: draft
owner: core/install/scripts
last_reviewed: 2026-08-24
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
related_issues:
  - 138
  - 141
  - 142
---

# Spec: Install Lifecycle Scripts

Status: Draft
Owner: core/install/scripts
Last reviewed: 2026-08-24

## Purpose

Install-time lifecycle scripts can mutate the filesystem, so their execution
must be a contracted install phase rather than an ad-hoc side effect. This
contract defines which lifecycle hooks RPM recognizes, when they run during
install, the environment they execute in, how their failure is reported, and the
invariant that a failed script phase cannot publish partial successful install
state.

This contract is the M6 lifecycle policy named by issue #141. Issue #142
implements the first phase selected here, and the remaining phases stay
deferred under this contract until a later issue claims them.

## Contract

### Lifecycle hook inventory

RPM recognizes the following install lifecycle hooks, read from the
`scripts` map of the root package manifest and of each resolved package's
per-version registry metadata:

| Hook | Phase owner | Scope | Status |
| --- | --- | --- | --- |
| `preinstall` | `install/scripts` | root and resolved packages | implemented (#142) |
| `install` | `install/scripts` | root and resolved packages | deferred under this contract |
| `postinstall` | `install/scripts` | root and resolved packages | deferred under this contract |
| `prepare` | `install/scripts` | root and resolved packages | deferred under this contract |

All other `scripts` entries (for example `prepublish`, `prestart`, `start`,
`poststart`, `prestop`, `stop`, `poststop`, `test`, `build`, and any custom
name) are **not lifecycle hooks**. RPM preserves them on the manifest and the
per-version registry record but never invokes them during install. They remain
reachable as user-invoked scripts through `rpm run`
(`docs/specs/cli/run/SPEC.md`), which is a separate execution path and is not an
install side effect.

The set of supported install lifecycle hooks is exactly the four listed above.
Adding, removing, or reordering a hook is a contract change to this SPEC, not an
implementation detail.

### Workspace-member lifecycle boundary (planned)

Workspace discovery and resolution do not activate lifecycle execution. The
current implementation reads hooks only from the project-root manifest and
registry-resolved package metadata. A local workspace member's manifest is a
third script source owned by this SPEC, and member hooks remain disabled until a
dedicated workspace lifecycle implementation issue claims the behavior below.

When workspace lifecycle execution is activated, it follows these deterministic
rules:

- A member hook is read from that discovered member's validated manifest. Only
  hooks whose phase is implemented under the inventory above execute;
  `preinstall` is the only implemented phase today.
- The scripts phase visits the root first, workspace members next in the
  manifest discovery table's canonical root-relative path order, and external
  resolved packages last in sorted lock-key order. Within each package, hook
  order remains `preinstall`, `install`, `postinstall`, then `prepare` as phases
  become implemented. Input enumeration, hash-map order, and network timing
  cannot change either order.
- A member hook runs in a transaction-owned staged member execution view. Its
  canonical execution root corresponds to the discovered member path inside
  the staged workspace root; it never runs in the live member source directory
  or in a previously published `node_modules` tree. The source member manifest
  is immutable input for the transaction. The hook process is confined to the
  transaction staging root: live member source and previously published
  `node_modules` are not exposed as hook read or write targets. If the execution
  platform cannot enforce this boundary, RPM must fail closed without running
  member hooks. The workspace install transaction's staged root `.bin`
  directory remains prepended to `PATH`, and the lexical symlink spelling used
  by the workspace declaration never selects a different execution root.
- Before the first member hook runs, RPM canonicalizes every staged symlink or
  link target that the hook could observe. Each target must remain inside the
  transaction staging root, be non-dangling and acyclic, and must not resolve
  to the live member source or a previously published install tree. A failed
  canonicalization or any boundary violation fails the `scripts` phase before
  hook execution. Link construction remains owned by #147; links created by a
  hook are subject to staging-root write confinement and post-hook validation.
- A staged execution view must not share a hard-link inode/device identity with
  the live member source or a previously published install tree. Member files
  in the view are materialized or copied up as regular files. Before the first
  member hook, RPM compares no-follow `lstat`/`fstat`-equivalent identities and
  fails the `scripts` phase if a shared hard-link alias is detected; #147's link
  construction ownership is unchanged.
- Any member-hook failure fails the single `scripts` phase and the whole
  workspace install transaction. RPM discards every staged root/member install
  output and preserves the previously published `node_modules`, `rpm.lock`, and
  root and member `package.json` files, including their original permissions.
  A later hook failure discards all staged member execution views, including
  changes made by earlier successful hooks, so every previously published root
  and member `node_modules` tree remains byte-identical. As with existing root
  and resolved-package hooks, RPM cannot reverse arbitrary hook writes to a
  live member source tree or outside the workspace; those writes are outside
  the transaction boundary.
- After a member hook exits zero, RPM validates the staged member
  `package.json` against its pre-hook snapshot. A change to that staged file is
  a `scripts`-phase post-hook validation failure, even when the child exits
  zero. RPM does not reload or re-resolve from the changed staged manifest and
  never writes it to the source member manifest. The transaction retains the
  source manifest's pre-transaction bytes and permissions. The snapshot and
  validation use no-follow `lstat`/`fstat`-equivalent operations and require a
  regular, non-symlink file with equal type, stable file identity, bytes, and
  permissions. A symlink, directory, special file, identity replacement, mode
  change, or byte change fails validation without opening or reading the new
  target.

The activating issue must coordinate the single staged transaction with
`docs/specs/core/install/recovery/SPEC.md` and workspace linking with #147 before
member hooks can run. The discovery/resolver implementation may land earlier,
but it must not call this execution path.

### Unsupported lifecycle phases

npm defines additional install-time and publish-time lifecycle hooks (for
example `prepublishOnly`, `prepack`, `postpack`, `prepublish`, `preinstall`,
`install`, `postinstall`, `preprepare`, `prepare`, `postprepare`,
`preuninstall`, `uninstall`, `postuninstall`). Of these, RPM supports only
`preinstall`, `install`, `postinstall`, and `prepare`. Every other npm
lifecycle hook is explicitly **unsupported** during install: it is preserved on
the manifest and registry record, never invoked, and never an install side
effect. A package that declares an unsupported hook installs normally; the hook
is ignored, not an error.

### Hook value type

Lifecycle hook values are **strings only**. RPM reads the `scripts` map as
`string -> string`. A hook whose value is not a string is discarded as absent
during deserialization, consistent with the tolerant wrong-type handling for
preserved fields (`docs/specs/core/manifest/SPEC.md`,
`docs/specs/core/registry/SPEC.md`). An array-valued or object-valued hook does
not run and does not fail the install.

Lifecycle hooks do not introduce a second script-execution model. They reuse
the `rpm run` shell invocation model (`docs/specs/cli/run/SPEC.md`): each hook
value is executed through the platform shell (`/bin/sh -c` on Unix, `cmd /C` on
Windows), so command chaining, quoting, and environment assignment follow
normal package-script semantics. This contract does not define a departure from
that model.

### Ordering within an install

When lifecycle execution is implemented, hooks run as a distinct install
**phase**, inserted into the recovery phase pipeline between `link` and `write`
(see `docs/specs/core/install/recovery/SPEC.md`). The phase label is `scripts`.

Within the `scripts` phase, the per-package ordering for install hooks is:

1. `preinstall`
2. `install`
3. `postinstall`
4. `prepare`

This ordering is fixed by this contract. A later hook does not run if an
earlier hook in the same package has already failed the phase (see "Failure
behavior").

Across packages, the current root-only install visits the root first and
registry-resolved packages afterward in sorted lock-key order. The planned
workspace order is fixed by the workspace-member boundary above. Neither order
claims npm-compatible dependency-topological semantics, and changing either
order requires a contract update. The `scripts` phase must remain sequential
and must not rely on hash-map iteration order or network timing.

### Hook environment and PATH

Lifecycle hooks execute with an environment contract that is narrower than
npm's. This contract defines only what RPM guarantees today:

- **Working directory.** A root lifecycle hook runs with the project root as its
  working directory. A resolved-package lifecycle hook runs with that package's
  directory in the staged replacement tree, which becomes the corresponding
  directory under `node_modules/` after the `write` phase. This gives hooks the
  package-local working directory they will have after publication while keeping
  the previous install untouched during failure handling.
- **PATH.** Lifecycle hooks receive the same PATH prepend policy as `rpm run`:
  the staged replacement tree's `.bin` directory is prepended to the inherited
  `PATH`. For resolved-package hooks, `.bin` generation
  (`docs/specs/core/linker/SPEC.md`) has already run in the preceding `link`
  phase, so the staged project `.bin` is populated before any hook runs. Root
  hooks use the same staged directory; the published layout is equivalent after
  a successful `write` phase.
- **Child status propagation.** The child process exit status is propagated per
  `docs/specs/cli/run/SPEC.md`: a hook that exits non-zero fails the phase with
  that status; a hook that cannot be spawned surfaces a readable run error.

RPM does **not** set npm-specific environment variables today (`npm_lifecycle_event`,
`npm_lifecycle_script`, `npm_config_*`, `npm_package_*`, `INIT_CWD`). These are
deliberately out of scope for the first phase. Adding any of them is a contract
change to this SPEC, not an implementation detail. A future issue must own
which, if any, are added.

### Failure behavior and install state

A failed lifecycle hook fails the `scripts` phase. The phase failure is reported
with the phase label `scripts`, matching the recovery contract's labeled-phase
error guarantee.

**Invariant: a failed `scripts` phase cannot publish partial successful install
state.** Because the `scripts` phase runs between `link` and `write`, a hook
failure occurs while the previous `node_modules` is still in place: the staged
replacement has been linked but not yet renamed into place. The recovery
contract's existing guarantees therefore apply unchanged:

- A failed `scripts` phase leaves the previous `node_modules` directory
  untouched (the staged replacement is discarded, not published).
- A failed `scripts` phase is not reported as a successful install.
- A failed `scripts` phase must not write or rewrite `rpm.lock` or
  `package.json`; the `write` phase (which owns those writes) has not run.

There is no force-continue or skip-on-failure policy for lifecycle hooks today.
A failed hook fails the install for the whole transaction. A future issue may
own an opt-in skip policy; until then, any hook failure is fatal to the install.

When a successful root `preinstall` hook changes `package.json` or `rpm.lock`,
RPM reloads those files before the install write. The hook-written state is
authoritative for existing fields and entries; generated package entries that
are absent from a hook-written lockfile are merged so the published lockfile
still records the installed graph. RPM rebuilds the staged install from the
reloaded lockfile graph before publishing, and does not re-resolve dependency
declarations or repeat the root hook during that rebuild. Dependency
declarations changed by a root hook therefore take effect on a subsequent
install. Resolved-package hooks run after this reconciliation and run once
against the final staged tree. If the scripts phase fails, the pre-hook state
is restored for both files, including their original permissions.

A hook that mutates files inside or outside the workspace is still subject to
the user-controlled filesystem safety rules: RPM confines its own writes to
approved roots and validates inputs before mutation. Lifecycle hooks execute
arbitrary user/registry-controlled commands, so RPM does not guarantee a hook's
internal effects are reversible outside the protected staging boundary. The
arbitrary-write disclaimer does not permit access to live member source or
previously published install trees; those paths are not exposed to the hook,
and an unavailable isolation boundary fails closed. What RPM guarantees is
narrower: the install transaction either reaches `write` (and publishes a
complete, consistent install) or it does not publish any install state. A hook
that has already run and mutated the staged tree before a later hook fails does
not get its effects rolled back inside the staged tree, but the staged tree
itself is discarded, so the published install never reflects a partial
lifecycle run.

### Relationship to `rpm run`

Lifecycle hook execution and `rpm run` share a shell invocation model but are
different execution paths:

- `rpm run <script>` is a user-invoked command. It must not reinstall or mutate
  install output (`docs/specs/cli/run/SPEC.md`). It reads the root manifest's
  `scripts` map only.
- Lifecycle hooks are install-driven. They run during the `scripts` phase, read
  from both the root manifest and resolved-package registry metadata, and their
  failure controls install state.

This contract does not redefine `rpm run`. It reuses `rpm run`'s shell
invocation and PATH prepend so there is one script-execution contract, not two.

## Error Cases

- A lifecycle hook value that is not a string is discarded as absent; the hook
  does not run and the install is not failed. This is the tolerant wrong-type
  handling shared with `docs/specs/core/manifest/SPEC.md` and
  `docs/specs/core/registry/SPEC.md`.
- A supported lifecycle hook that exits non-zero fails the `scripts` phase with
  that exit status. The phase label `scripts` must appear in the error.
- A supported lifecycle hook that cannot be spawned surfaces a readable run
  error and fails the `scripts` phase; it is not reported as a successful
  install.
- An unsupported lifecycle hook name (anything outside `preinstall`, `install`,
  `postinstall`, `prepare`) is never an error: it is preserved and ignored.
- A failed `scripts` phase must not publish partial install state (see
  "Failure behavior and install state").

## Test Fixtures

The first lifecycle phase (`preinstall`) landed via #142. The following fixture
scenarios live under `tests/fixtures/install-projects/` and follow
`docs/conventions/install_fixture_outputs.md`; they stay offline and
deterministic:

- `lifecycle-preinstall-success`: a successful resolved-package `preinstall`
  hook that runs during install and writes a proof file inside its installed
  package directory;
- `lifecycle-preinstall-failure`: a resolved-package `preinstall` hook that
  exits non-zero and fails the `scripts` phase with the `scripts` label, while
  the previous `node_modules` and the root `package.json` remain unchanged;
- `lifecycle-preinstall-missing-command`: a hook whose command is missing,
  surfacing the shell's readable error and a `scripts failed` label without
  publishing install state;
- `lifecycle-preinstall-wrong-type`: a wrong-type hook value (array) that is
  discarded as absent by the manifest deserializer so the install proceeds
  normally;
- `lifecycle-preinstall-root`: the root manifest's `preinstall` hook runs with
  the project root as its working directory.

Each scenario is a single deterministic fixture under
`tests/fixtures/install-projects/`, scaffolded by `scripts/new-install-fixture.sh`
or `just fixture <name>`, and does not assert behavior outside this contract.
Later lifecycle phases (`install`, `postinstall`, `prepare`) will add their own
fixtures when a follow-up issue claims them; until then they stay deferred.

Workspace lifecycle activation additionally requires two copied, offline
fixtures before production execution is enabled:

- `workspace-lifecycle-order-cwd` supplies root, member, and external
  `preinstall` hooks in deliberately reversed input order and records the exact
  root/member-path/external-lock-key visit order plus each hook's working
  directory relative to the copied fixture root;
- `workspace-lifecycle-failure` makes a member `preinstall` exit non-zero and
  proves the `scripts` label and child status propagate while the previous root
  and member install trees, `rpm.lock`, and every participating `package.json`
  remain byte-for-byte and permission-for-permission unchanged.
- `workspace-lifecycle-member-manifest-mutation` makes a member `preinstall`
  mutate its staged `package.json` and exit zero, proving post-hook validation
  fails without reload, re-resolution, or source-manifest writes and that the
  pre-transaction bytes and permissions remain unchanged.
- `workspace-lifecycle-published-tree-write` attempts an absolute write to a
  previously published `node_modules` path, proving the staged-root boundary
  denies the target and fails closed without publishing member output;
- `workspace-lifecycle-staged-link-boundary` supplies escaping, dangling,
  cyclic, live-source, and previously published-tree staged symlink/link
  targets, proving each is rejected before a member hook starts;
- `workspace-lifecycle-staged-hardlink-alias` supplies a staged regular file
  sharing inode/device identity with the live source or published tree,
  proving the alias is rejected before a member hook starts;
- `workspace-lifecycle-member-manifest-replacement` replaces staged
  `package.json` with a symlink, directory, and mode-changing file in separate
  deterministic cases, proving no-follow validation rejects each replacement
  without reading its target.

The fixtures must use expected output committed with the fixture, must copy all
mutable input to a temporary directory, and must not depend on a live registry,
the host's absolute path, directory enumeration order, or ambient caches.

## Open Questions

Each open question is a deferred decision that does not block the first phase
(#142). They are listed here so #142 does not silently resolve them in code.

- Whether a future dependency-aware lifecycle implementation replaces the
  current root/sorted-external order or the planned
  root/member-path/sorted-external workspace order. Until a contract change
  decides otherwise, the deterministic sequential orders above are normative.
- Which, if any, npm-specific environment variables (`npm_lifecycle_event`,
  `npm_lifecycle_script`, `npm_config_*`, `npm_package_*`, `INIT_CWD`) RPM sets
  for lifecycle hooks. None are set today.
- Whether RPM supports an opt-in skip-on-failure or force-continue policy for
  lifecycle hooks. None exists today; any hook failure is fatal to the install.
- Whether `prepare` (which npm also runs at git-dep install and at local
  `npm install` without arguments) gains additional trigger points beyond the
  install ordering fixed here. Today `prepare` is only an install-phase hook
  with the same trigger as the other three.
