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
  - 145
  - 222
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
workspace lifecycle implementation under #222 claims the behavior below.

When workspace lifecycle execution is activated, it follows these deterministic
rules:

- The root hook is selected from the immutable parsed root snapshot returned by
  discovery. Workspace staging materializes the staged root manifest from those
  exact bytes; neither staging nor script selection reopens the live root
  manifest path. A final live-root identity/bytes/permissions check is required
  before publication under the recovery contract.
- A member hook is read from the immutable parsed manifest snapshot carried by
  that discovered member's validated table row. The scripts phase does not
  reopen the source member manifest by path. Only hooks whose phase is
  implemented under the inventory above execute; `preinstall` is the only
  implemented phase today.
- The scripts phase visits the root first, workspace members next in the
  manifest discovery table's unsigned UTF-8 `member_path_key` order, and
  external resolved packages last in sorted lock-key order. Within each package,
  hook order remains `preinstall`, `install`, `postinstall`, then `prepare` as
  phases become implemented. Input enumeration, hash-map order, and network
  timing cannot change either order.
- When workspace lifecycle execution is activated, the root hook also runs in a
  transaction-owned view whose working directory is the staged workspace root.
  It does not run in the live project root and cannot address a live root/member
  source path or any previously published root/member `node_modules` tree. This
  workspace-specific boundary leaves the current root-only execution path
  unchanged until #222 activates the workspace path.
- A member hook runs in a transaction-owned staged member execution view. Its
  canonical execution root corresponds to the discovered member path inside
  the staged workspace root; it never runs in the live member source directory
  or in a previously published `node_modules` tree. The source member manifest
  is immutable input for the transaction.
- An external resolved-package hook runs from that package's transaction-owned
  directory in the staged replacement tree. Root, member, and external hook
  processes all use the same staging-root process confinement: live source and
  previously published install trees are not exposed as read or write targets.
  The boundary covers the hook's complete descendant process tree; RPM does not
  advance to post-hook validation while a descendant survives or retains a
  writable handle outside transaction control.
  If the execution platform cannot enforce this boundary, RPM fails closed
  before running any workspace root, member, or external hook. The transaction's
  staged root `.bin` directory remains prepended to `PATH`, and the lexical
  symlink spelling used by the workspace declaration never selects a different
  execution root.
- Before the first workspace root, member, or external hook runs, RPM
  canonicalizes every staged symlink or link target that a hook could observe.
  Each target must remain inside the transaction staging root, be non-dangling
  and acyclic, and
  must not resolve to any live root/member source or a previously published
  install tree. A failed canonicalization or any boundary violation fails the
  `scripts` phase before hook execution. Link construction remains owned by
  #147; links created by a hook are subject to staging-root write confinement
  and post-hook validation.
- A staged execution view must not share a hard-link inode/device identity with
  any live root/member source or previously published install tree. Files in the
  view are materialized or copied up as regular files. Before the first
  workspace root, member, or external hook, RPM compares no-follow
  `lstat`/`fstat`-equivalent identities and fails the `scripts` phase if a shared
  hard-link alias is detected; #147's link construction ownership is unchanged.
- When the staged workspace view is materialized, RPM opens and retains a
  descriptor for the staged workspace root and every staged member directory,
  pins each directory's native identity, and records the exact
  descriptor-relative native parent/name chain copied from the discovery row.
  These values are transaction validation state, never graph origins. Immediately
  before and after every root, member, and external hook and immediately before
  publication, RPM walks every retained member chain from the staging-root
  descriptor without following links. Every parent identity and directory-entry
  name must match, the final entry must still name the retained member descriptor,
  and serializing the chain must still yield the row's `member_path_key`. A
  rename to another in-root name fails even when the retained descriptor still
  has the pinned inode or platform identity. Replacement, mount or reparse
  substitution, missing parent/name entry, containment failure, or an unsupported
  identity primitive also fails without reopening an independently constructed
  path.
- After `link` and before the first hook, RPM records the descriptor identities,
  types, and targets of every linker-created entry in the complete staged
  managed tree. Immediately before and after every root, member, and external
  hook, and once more immediately before publication, RPM recursively scans that
  complete tree from the retained staging-root descriptor without following
  links. The scan rejects a new symlink or hard link, a changed pinned link or
  target, duplicate inode/device or platform file identity, a cross-device or
  reparse alias, and any identity shared with a pinned live source or previously
  published tree. A hook-created ordinary file is allowed only when it is a
  regular non-symlink with one link and a unique identity on the transaction's
  staging volume. If the platform cannot provide equivalent no-follow tree and
  identity guarantees, workspace hook execution fails closed.
- The managed-tree scan covers every publishable root/member `node_modules`
  subtree, all descendants, and every linker-created entry. Staged manifests and
  `rpm.lock` are explicit write state with the dedicated snapshot checks in this
  SPEC. Temporary source-overlay paths are outside the managed-tree scan because
  they are discarded and never enter the publication transaction record. Their
  link safety is owned by hook-process confinement: every hook filesystem
  lookup, link, rename, and reparse resolution remains rooted in the retained
  staging capability, including when a later hook observes an earlier hook's
  source-overlay entry. A source-overlay symlink, hard link, or reparse entry
  cannot resolve or alias into a live source or previously published tree. A
  platform that cannot enforce this process-wide boundary fails closed before
  workspace hooks run.
- When staged views are materialized and before the root hook runs, RPM records
  each staged member manifest's regular-file identity and requires its bytes and
  permissions to equal the immutable discovery snapshot. Every later check
  compares against this transaction-start identity and the discovery bytes and
  permissions; a fresh snapshot is not taken after an earlier hook can write the
  shared view.
- After resolution/linking produces the staged `rpm.lock` and before the first
  hook, RPM opens it descriptor-relative without following links and requires a
  regular file with exactly one link. RPM pins its descriptor identity, exact
  bytes, and permissions. Immediately before and after every root, member, and
  external hook and immediately before publication, the same descriptor and
  no-follow path entry must retain that type, one-link count, identity, bytes,
  and permissions. A byte or mode change, replacement, symlink, hard link, or
  special file fails the scripts phase without reading a replacement target.
- The staged workspace view has two explicit publication classes. Managed
  install output consists only of the transaction-owned root/member
  `node_modules` trees and may be published atomically by `write`. The staged
  root `package.json` and `rpm.lock` are explicit write-phase state and may be
  published only after the reconciliation and validation rules below succeed.
  Every other root/member source path in the execution view is a temporary
  source overlay: hook-created, modified, or deleted ordinary files remain
  visible to later hooks in that same staged view, then are discarded after the
  phase even on success and are never copied to a live source directory. A
  member hook output under its staged `node_modules` is managed install output;
  an ordinary generated file beside the member's staged `package.json` is
  source-overlay output. The member `package.json` remains immutable and is
  governed by the stricter validation below. Publication uses the recovery
  SPEC's single multi-output transaction record; this SPEC does not permit
  per-member success or early backup deletion.
- `write` never publishes the staged `rpm.lock` inode or any link to it. After
  the final descriptor validation, RPM reads the pinned bytes through that
  descriptor and materializes them into a new transaction-owned, single-link
  regular temporary file on the lockfile target filesystem. It fsyncs the file,
  verifies the materialized bytes, permissions, distinct identity, and one-link
  count, then publishes that file through the recovery protocol. The staged
  inode remains staging-only and is discarded.
- Any workspace root/member hook failure or post-hook validation failure fails
  the single `scripts` phase and the whole workspace install transaction. RPM
  discards every staged root/member install output and preserves the previously
  published `node_modules`, `rpm.lock`, and root and member `package.json` files,
  including their original permissions.
  A later hook failure discards all staged member execution views, including
  changes made by earlier successful hooks, so every previously published root
  and member `node_modules` tree remains byte-identical. Workspace root/member
  hooks cannot reach live source or published install trees through their
  execution view; an attempted escape fails closed under the confinement rule.
- After a member hook exits zero, RPM validates the staged member
  `package.json` against its transaction-start snapshot. A change to that staged
  file is a `scripts`-phase post-hook validation failure, even when the child
  exits zero. RPM does not reload or re-resolve from the changed staged manifest
  and never writes it to the source member manifest. The transaction retains the
  source manifest's pre-transaction bytes and permissions. The snapshot and
  validation use no-follow `lstat`/`fstat`-equivalent operations and require a
  regular, non-symlink file with equal type, stable file identity, bytes, and
  permissions. A symlink, directory, special file, identity replacement, mode
  change, or byte change fails validation without opening or reading the new
  target.
- Discovery freezes the root manifest's parsed `workspaces` declaration and the
  resulting ordered `member_path_key` table before any hook starts. After a
  workspace root hook exits zero, RPM validates and parses the staged root
  `package.json` through its transaction-start descriptor. The staged file must
  remain a regular non-symlink with one link and the same native identity; only
  its allowed bytes may change. The post-hook declaration must have identical
  presence, supported array-or-object shape, pattern strings, and pattern order.
  Any change, including adding or removing `workspaces`, fails the `scripts`
  phase before a member or external hook runs. RPM does not rediscover members,
  reseed requests, or publish the changed root manifest.
- The same post-root validation freezes every root field that determines graph
  identity or request seeding: `name`, `version`, `dependencies`, and
  `devDependencies`, including field presence, map keys, and exact values. A
  root-name change fails even when the new name would not collide, and a change
  that creates a root/member or duplicate-package collision is never accepted by
  reloading. Non-graph root fields may continue through the existing
  reconciliation rule below.
- The same post-root boundary validates every staged member `package.json`
  against its transaction-start identity and immutable discovery bytes and
  permissions before the first member hook. The frozen root declaration and all
  member manifests are validated again after each later hook that can write the
  shared staged view and immediately before `write`. No lifecycle hook runs
  after the final validation. A root, member, or external hook that changes any
  frozen manifest therefore fails the phase; a later hook cannot reintroduce a
  declaration or member-manifest change after an earlier check.
- The recovery SPEC's cooperative per-workspace RPM lock is acquired before
  discovery validation, expected-state capture, and hook execution. Immediately
  before the first backup and each later live mutation, RPM repeats the guarded
  descriptor checks for the root/member manifests and every output target. The
  lock remains held across journal recovery, staging, hooks, backup preparation,
  publication, final postconditions, and backup cleanup or rollback. It excludes
  other conforming RPM writers. Non-cooperating external writers remain within
  the explicitly unsupported race boundary defined by the recovery SPEC.

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

- **Working directory.** In the active root-only path, a root lifecycle hook
  runs with the project root as its working directory. In the planned workspace
  path, the root hook runs at the staged workspace root and each member hook runs
  at its `member_path_key` location inside that staged root. A resolved-package
  lifecycle hook runs with that package's directory in the staged replacement
  tree, which becomes the corresponding directory under `node_modules/` after
  the `write` phase. These staged directories keep the previous install and
  live workspace sources untouched during failure handling.
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

In the active root-only path, RPM reloads a successful root `preinstall` hook's
changes to `package.json` or `rpm.lock` before the install write. Hook-written
state remains authoritative there; generated package entries absent from a
hook-written lockfile are merged so the published lockfile records the installed
graph. RPM rebuilds the staged install from that reloaded lockfile graph without
repeating the root hook, and root-hook dependency changes take effect on a
subsequent install.

The planned workspace path is stricter. It reloads only accepted non-graph root
manifest fields after the frozen-field validation above. The staged `rpm.lock`
is immutable hook input, so a root, member, or external hook change fails instead
of being merged or reloaded. Resolved-package hooks run once against the final
staged graph. If the scripts phase fails, the staged manifest and lockfile are
discarded before any live write; the active root-only restoration behavior and
original permissions remain unchanged.

Lifecycle hooks execute arbitrary user/registry-controlled commands. In the
active root-only path, RPM cannot guarantee that a root hook's writes outside
managed install state are reversible. The planned workspace path under #222
uses the stricter confinement boundary above for root, member, and external
hooks; it does not expose live source or previously published install paths, and
an unavailable isolation boundary fails closed. The workspace transaction
either reaches
`write` and publishes only the defined managed outputs and accepted write-phase
state, or it publishes none of them. A hook that already mutated a staged view
before a later failure does not need an in-place rollback because the whole view
is discarded.

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

Workspace lifecycle activation under #222 requires the following copied,
offline fixtures before production execution is enabled:

- `workspace-lifecycle-order-cwd` supplies root, member, and external
  `preinstall` hooks in deliberately reversed input order and records the exact
  root/member-path/external-lock-key visit order plus each hook's working
  directory relative to the copied fixture root;
- `workspace-lifecycle-failure` makes a member `preinstall` exit non-zero and
  proves the `scripts` label and child status propagate while the previous root
  and member install trees, `rpm.lock`, and every participating `package.json`
  remain byte-for-byte and permission-for-permission unchanged.
- `workspace-lifecycle-root-published-tree-write` makes the root `preinstall`
  attempt an absolute write into a previously published member `node_modules`,
  proving the staged-root confinement denies the target before mutation and no
  later hook or publication occurs;
- `workspace-lifecycle-root-workspaces-mutation` makes the root `preinstall`
  change the staged declaration and exit zero, proving frozen-declaration
  validation fails before member/external hooks without rediscovery,
  re-resolution, or publication;
- `workspace-lifecycle-root-graph-field-mutation` changes root `name`, `version`,
  `dependencies`, and `devDependencies` in separate zero-exit cases, including a
  root/member name collision, and proves every case fails before later hooks or
  publication without reloading graph identity;
- `workspace-lifecycle-root-manifest-replacement` replaces the live root
  manifest after discovery and replaces the staged root manifest during the
  hook in separate cases, proving snapshot-only script input, stable staged
  identity, and final live identity/bytes/permissions validation;
- `workspace-lifecycle-root-member-manifest-mutation` makes the root
  `preinstall` replace a staged member manifest, proving the post-root member
  snapshot check fails before that member hook or any publication;
- `workspace-lifecycle-member-manifest-mutation` makes a member `preinstall`
  mutate its staged `package.json` and exit zero, proving post-hook validation
  fails without reload, re-resolution, or source-manifest writes and that the
  pre-transaction bytes and permissions remain unchanged.
- `workspace-lifecycle-member-output-publication` writes one ordinary generated
  file beside the staged member manifest and one proof file inside the staged
  member `node_modules`, then proves a successful `write` publishes only the
  managed install proof while the ordinary source-overlay file never appears in
  the live member source;
- `workspace-lifecycle-staged-lockfile-integrity` has root, member, and external
  hooks change staged `rpm.lock` bytes, mode, identity, file type, symlink target,
  and link count in separate cases, proving the next boundary fails without
  reading or publishing a replacement;
- `workspace-lifecycle-lockfile-materialization` proves a successful install
  publishes the pinned staged lockfile bytes through a new single-link regular
  inode with the expected permissions and no identity/link alias to staging;
- `workspace-lifecycle-published-tree-write` makes a member hook attempt an
  absolute write to a previously published `node_modules` path, proving the
  staged-root boundary denies the target and fails closed without publishing
  member output;
- `workspace-lifecycle-external-hook-confinement` makes an external package hook
  and a spawned descendant attempt absolute and link-mediated writes to live
  root/member sources and previously published install trees, proving
  staging-root process confinement denies every target, leaves no surviving
  descendant, and prevents publication;
- `workspace-lifecycle-staged-link-boundary` supplies escaping, dangling,
  cyclic, live-source, and previously published-tree staged symlink/link
  targets, proving each is rejected before a member hook starts;
- `workspace-lifecycle-staged-member-directory-replacement` replaces a staged
  member directory after the root hook and immediately before/after that member
  hook in separate injected cases, proving each pinned-identity boundary and the
  pre-publication check fails closed;
- `workspace-lifecycle-staged-member-directory-rename` renames the same pinned
  directory inode to another in-root parent/name entry before/after root, member,
  and external hooks and before publication in separate cases, proving exact
  `member_path_key` parent/name validation rejects every same-identity
  relocation;
- `workspace-lifecycle-hook-created-link-alias` has root, member, and external
  hooks create a symlink, hard link, duplicate inode/device identity, and
  published-tree alias in separate cases, proving the full no-follow managed-tree
  scan rejects each before the next hook or publication;
- `workspace-lifecycle-source-overlay-link-confinement` creates source-overlay
  links toward staged, live-source, and published-tree targets and proves the
  process boundary blocks every outside-staging resolution while the overlay
  entries remain outside managed-tree publication and are discarded;
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
