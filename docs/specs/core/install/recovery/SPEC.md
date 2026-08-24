---
spec_id: install_recovery
title: Install Recovery
status: draft
owner: core/install/recovery
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
  - 50
  - 79
  - 81
  - 141
  - 142
  - 145
  - 222
---

# Spec: Install Recovery

Status: Draft
Owner: core/install/recovery
Last reviewed: 2026-08-24

## Purpose

RPM must not destroy a working project while preparing replacement install
output. Recovery behavior defines when `node_modules` can be replaced and how
failures are reported to callers.

## Contract

Install output replacement is staged. RPM builds replacement `node_modules`
content in a temporary sibling directory first, while the existing
`node_modules` remains in place.

RPM replaces the existing directory only after extraction and linking both
complete successfully. If replacement itself fails, RPM attempts to restore the
previous directory before returning the write failure.

Failures must include the failed phase in the returned error message for cached
package installation. This contract enforces `resolve`, `fetch`, `extract`,
`link`, `scripts`, and `write` labels for cached package installation. The
`scripts` phase runs between `link` and `write` and is owned by
`docs/specs/core/install/scripts/SPEC.md` (#141); `preinstall` execution landed
via #142, while later hooks remain deferred. Registry fetch and cache-write
failures must be returned to callers instead of being ignored or reported as
successful downloads.

## Error Cases

A failed resolve, fetch, extract, or link phase must leave the previous
`node_modules` directory untouched. A failed write phase must not be reported as
a successful install.

A failed `scripts` phase must leave the previous `node_modules` directory
untouched, must not write or rewrite `rpm.lock` or `package.json` (those writes
belong to the `write` phase, which has not run), and must not be reported as a
successful install. Because the `scripts` phase runs between `link` and
`write`, a lifecycle hook failure occurs while the staged replacement has been
linked but not yet renamed into place; the staged tree is discarded, so the
published install never reflects a partial lifecycle run. This invariant is
owned jointly with `docs/specs/core/install/scripts/SPEC.md` (#141).

### Workspace lifecycle recovery boundary (planned)

Workspace discovery and resolution do not change the active recovery pipeline.
Before a workspace install may execute any root, member, or external lifecycle
hook, the installer must provide one workspace transaction that stages every root/member
install output governed by the operation, the explicit root manifest/lockfile
write state, and the temporary root/member source overlays used for execution.
The transaction owns the staged root execution view, each member view, and every
external resolved-package directory in the staged replacement tree.
The root hook's canonical execution root is the staged workspace root; a member
view corresponds to that member's `member_path_key` inside the staged root.
Neither points at a live root/member source directory or a previously published
`node_modules` tree. An external hook runs only from its staged resolved-package
directory. The validated member manifest snapshots remain immutable transaction
input. Root, member, and external hook processes are confined to the staging root
for both reads and writes. The boundary covers every descendant and retained
handle for the hook lifetime, and post-hook validation starts only after no hook
descendant survives. If the execution platform cannot enforce that isolation,
the transaction fails closed before any workspace hook runs.
Workspace linking under #147 is a prerequisite for that transaction; #147 does
not own lifecycle execution, which remains disabled until #222.

The only publishable managed output is the transaction-owned root/member
`node_modules` set. The staged root `package.json` and `rpm.lock` are separate
write-phase state and publish only after scripts reconciliation and validation.
All other staged root/member source-overlay writes are discarded after the
scripts phase even on success and are never copied to live source. This
publication boundary is owned jointly with
`docs/specs/core/install/scripts/SPEC.md`.

Before processing an active recovery journal, discovery, staging, hooks, or any
live-state validation for a workspace install, RPM acquires one durable
per-workspace cooperative RPM lock bound to the canonical workspace root. The
lock lives in the descriptor-confined RPM control directory and uses a platform locking
primitive that serializes every conforming RPM invocation for that workspace.
Its stable lock file is opened no-follow as a regular single-link file, fsynced
with its parent when first created, and never renamed or removed by transaction
cleanup. If the lock is contended, has the wrong path/type/identity, or is
unsupported, RPM fails closed without staging, backing up, renaming, or
publishing a live target.

The lock is a cooperative process boundary. It excludes other conforming RPM
transactions; it cannot reserve a heterogeneous target set against an unrelated
process or an already-open external handle. Callers that permit a non-cooperating
writer to mutate participating workspace paths during install are outside the
supported concurrency contract. RPM must not claim atomic preservation against
that actor. This limitation is explicit on Linux, macOS, and every other
platform without a filesystem transaction spanning the complete target set.

Before recording the expected-state table, RPM revalidates the live root
manifest and every discovered member manifest through the retained discovery
descriptors. Descriptor-relative no-follow lookup, regular single-link type,
native identity, exact bytes, and permissions must all match the immutable
snapshots. Any replacement or drift fails before baseline capture, staging,
backup, or publication and leaves the observed live value untouched. A fresh
path read must not become the baseline.

Before the first workspace hook, RPM records a read-only expected-state table for
the live root/member manifests, every root/member `node_modules` tree,
`rpm.lock`, and every other path classified as managed output. Each row pins
presence or absence, type, permissions, exact file/tree bytes, symlink targets
where applicable, and native identity through descriptor-relative no-follow
operations. This is the transaction-start baseline; a later live value must not
silently replace it.

After staged hooks complete and before final live validation or the first live
backup, rename, or write, RPM repeats every expected-state lookup while holding
the lock and compares live root/member manifests and outputs for presence or
absence, type, native identity,
exact bytes/tree, symlink target, and permissions. It repeats the relevant target
and retained-parent checks immediately before each backup, rename, publication,
restore, or cleanup operation. Drift observed at either check fails before that
operation and must not be adopted as a new baseline. The lock remains held
through journal recovery, staging, hooks, backup preparation, every publication
step, all final postconditions, and either successful backup cleanup or verified
rollback; releasing it is the transaction's last live-state action.

Only after the locked revalidation succeeds does RPM create one workspace
transaction record covering the root and every member `node_modules` tree, the
root `package.json`, `rpm.lock`, and every other path classified as managed
output by the operation. The record binds to the verified expected-state rows,
deterministic backup paths, and staged publication identities and digests.

Before the first backup rename, RPM durably writes that record as a recovery
journal in a descriptor-confined RPM control directory outside every publication
target. It writes and fsyncs a temporary journal file, atomically renames it to
the active name, and fsyncs the containing directory. Before each later backup,
publication, restore, or cleanup operation, RPM durably records and fsyncs the
intent. After the filesystem operation it fsyncs affected file/directory state
and durably records completion before advancing. Journal serialization and
recorded paths are deterministic and must not contain a host-absolute path.

Every existing output is moved to a distinct same-filesystem transaction backup
so restoring it preserves the original identity; an originally absent path is
recorded as absent. If backup preparation fails, already moved paths are restored
before the operation returns and no staged output is published.

Publication then replaces outputs only through that record. RPM does not delete
or unlink any backup until every root/member tree, manifest, lockfile, and managed
output has been published, all final postconditions pass, and a committed marker
has been durably written and fsynced. A failure before that marker removes every
transaction-owned published path and restores the complete recorded set through
same-filesystem renames, including exact bytes, type, mode, and original native
identity. If full restoration cannot be verified, RPM reports recovery-required,
retains the journal and all remaining backups, and never reports install success.

On every later invocation, RPM acquires the cooperative per-workspace RPM lock and
processes an active recovery journal before discovery or new transaction state.
An uncommitted journal is rolled back from its recorded backups. A committed
journal is validated against published identities/digests before remaining
backup cleanup completes. Corrupt, incomplete, missing-backup, path-confinement,
or identity-ambiguous state fails closed, preserves every journal and backup
artifact, and blocks a new install for that workspace. The active journal is
removed only after recovery or committed cleanup is durably complete and its
control directory has been fsynced; releasing the lock is the last transaction
action.

The workspace `scripts` phase remains between `link` and `write`. Its source,
root/member/external visit order, staged member execution root, PATH, and
supported hook inventory are owned by
`docs/specs/core/install/scripts/SPEC.md`. This SPEC owns the transaction result
when any of those hooks fails:

- no staged root or member install output is published;
- no staged source-overlay output is copied to a live source directory;
- every previously published root/member `node_modules` tree remains unchanged;
- `rpm.lock` and every participating root/member `package.json` remain at their
  pre-transaction bytes and permissions; and
- the error retains the `scripts` phase label and the child exit status when one
  exists.

After each member hook exits zero, the staged member `package.json` is checked
against the transaction-start staged identity plus the immutable discovery
bytes and permissions and must remain a regular non-symlink with one link. A
change is a post-hook validation failure. RPM
does not reload or re-resolve from that staged change and does not write it to
the source member manifest. A later hook failure or this validation failure
discards every staged execution view, while the previously published root and
member `node_modules` trees remain byte-identical.

After a workspace root hook exits zero, the staged root manifest must preserve
the frozen parsed `workspaces` declaration: field presence, supported shape,
pattern strings, and pattern order are identical to discovery input. A change
fails before any member or external hook. RPM performs no second discovery or
resolution and publishes neither the changed manifest nor any staged output.
Every staged member manifest is also checked against its immutable discovery
snapshot at that boundary. The root declaration and all member manifests are
revalidated after each later hook that can write the shared view and once more
immediately before `write`; no lifecycle hook runs after the final check.

That post-root boundary also freezes root `name`, `version`, `dependencies`, and
`devDependencies`, including field presence, map keys, and exact values from the
immutable discovery snapshot. Any graph-field change, including a root/member
name collision, fails before later hooks or publication. Only non-graph root
manifest changes may enter the scripts SPEC's reconciliation path.

Before the first hook, RPM opens staged `rpm.lock` descriptor-relative without
following links and pins its regular single-link type, native identity, exact
bytes, and permissions. Immediately before and after every root, member, and
external hook and immediately before publication, the descriptor and path entry
must still match all pinned values. Any mutation or replacement fails without
reading a new target. Publication copies the pinned bytes through the retained
descriptor into a newly materialized, fsynced, single-link regular file with a
distinct identity; it never publishes the staged inode or a link to that inode.

Discovery's immutable root snapshot is the only root-manifest input to resolver,
staging, and hook selection. While the cooperative per-workspace RPM lock is held
and immediately before backup preparation, RPM revalidates the live root manifest
through the retained descriptor and descriptor-relative no-follow lookup. Its
native identity, exact bytes, and permissions must still equal discovery input.
The staged root manifest must remain on its transaction-start regular-file
identity with one link; allowed staged byte changes follow the scripts contract.
Any live or staged replacement fails before the transaction overwrites or backs
up a live path.

The transaction retains a descriptor, pinned native identity, and the exact
descriptor-relative native parent/name chain for every staged member directory.
Immediately before and after every root, member, and external hook and
immediately before publication, it walks every chain from the retained
staging-root descriptor without following links. Every parent identity and entry
name, final directory identity and type, root containment check, and serialized
`member_path_key` mapping must still match. A same-inode rename to another
parent/name entry fails alongside replacement, mount or reparse substitution, or
an unavailable equivalent identity primitive.

After `link`, RPM pins the allowed managed-tree link/identity inventory. Before
and after every root, member, and external hook and immediately before
publication, it scans the complete staged managed tree from the retained root
descriptor without following links. A new symlink or hard link, changed pinned
link/target, duplicate inode/device or platform file identity, cross-device or
reparse alias, or identity shared with live source/published state fails the
transaction. New regular hook output is eligible only with one link and a unique
identity on the staging volume. Platforms without equivalent descriptor-rooted
tree and identity checks fail closed before workspace hooks run.

This managed-tree inventory covers only publishable root/member `node_modules`
trees and linker-created entries. Manifests and `rpm.lock` use their dedicated
snapshot validation. Temporary source-overlay entries are excluded because they
are never published. Their link safety is enforced by the hook-process
confinement boundary for every lookup and mutation, including later-hook access;
no source-overlay symlink, hard link, or reparse entry may resolve or alias to
live source or published state. Platforms unable to enforce that boundary fail
before workspace hooks.

Before any workspace root, member, or external hook starts, staged symlinks and
link targets are canonicalized and must be non-dangling, acyclic, and confined to
the staging root. A target resolving to any live root/member source or
previously published tree fails the `scripts` phase before execution. Link
construction remains owned by #147; links created during a hook are checked by
staging-root write confinement and post-hook validation. The member manifest
snapshot uses no-follow `lstat`/`fstat`-equivalent checks for regular
non-symlink type, identity, bytes, and permissions. Symlink, directory,
special-file, identity, mode, or byte changes fail without reading the
replacement target.

The staged execution view also must not share hard-link inode/device identity
with any live root/member source or previously published install tree. The view
uses materialized or copy-up regular files, and a shared alias fails the phase
before hook execution.

The active root-only hook retains its existing arbitrary-write limitation. The
planned workspace path has the stricter isolation and publication boundary
above, so live source and published install trees are unavailable as hook
targets. Workspace root/member hooks and workspace-mode confinement for external
hooks remain disabled until #222 implements this boundary and its fixtures.

## M3 Side-Effect Audit

The 2026-06-22 M3 audit classifies current installer side effects against this
recovery contract and the related cache, lockfile, manifest, linker, resolver,
and performance SPECs.

| Phase | Code path | State touched | Current tests | SPEC status | Follow-up |
| --- | --- | --- | --- | --- | --- |
| read manifest | `install_in` calls `PackageManifest::read_from_path` before later phases | `package.json` read only | manifest parser tests and install fixture copy tests | conforms | none |
| resolve graph | `add_with_cache_dir` populates metadata and calls `resolve_dependency_graph` before output writes | in-memory graph, lockfile, and manifest state | resolver and install fixture tests | conforms | none |
| fetch/cache | `Registry::download_tarball*_to_dir` writes tarballs through staged cache publication | `.rpm/.cache` | registry cache write tests and install cache fixture assertions | conforms | none after #82 |
| extract | `NodeModules::init_from_lockfile` builds a staged `node_modules` tree with `NodeResolver::resolve_deps` | temporary sibling staging directory | linker extract-failure recovery tests | conforms | #81 may add broader phase-boundary fixtures |
| link | `NodeModules::linking` creates package-local dependency links inside staging | temporary sibling staging directory | linker missing-target recovery tests | conforms | #81 may add broader phase-boundary fixtures |
| write lockfile | `install_in` backs up install state, writes `rpm.lock`, and restores on later failure | `rpm.lock` and sibling backup | lockfile save tests and output-failure install fixture | conforms | none after #80 |
| write manifest | `install_in` backs up install state, writes `package.json`, and restores on later failure | `package.json` and sibling backup | manifest save tests, read-only manifest test, and output-failure install fixture | conforms | none after #80 |
| replace output | `replace_node_modules` renames staged output into place and restores a backup on write failure | `node_modules` and sibling backup | staged replacement success plus extract/link failure recovery tests | conforms | #81 may add a direct replacement-failure fixture |
| integrity gate | installer records `dist.integrity` or `dist.shasum` and verifies supported metadata before extraction | lockfile metadata and cached tarball bytes | lockfile, registry metadata, and integrity failure fixture tests | conforms | none after #89 |

## M4 Side-Effect Audit

The 2026-08-07 M4 audit re-checks installer phase side effects after the M4
measurement and deduplication work (#92 contract and gap audit, #94 graph dedup
proof, #103 tarball download counter, #93 metadata-read counter landed via
#106). M4 adds no
production install behavior: all measurement instrumentation is `#[cfg(test)]`-only
recording inside the fake registry API, and the deduplication proofs exercise
behavior the resolver already had. The audit confirms M3 recovery guarantees are
not weakened and classifies each phase against its owning SPEC.

| Phase | Owning SPEC(s) | M4 change | Side-effect status | Current tests | Verdict |
| --- | --- | --- | --- | --- | --- |
| read manifest | manifest | none | `package.json` read only | manifest parser tests and install fixture copy tests | conforms |
| resolve graph | resolver, lockfile | none (dedup proven, not added) | in-memory graph; no output writes before resolution | resolver tests; #94 graph proof (`graph.packages().len() == 3`); #103 download proof | conforms |
| fetch/cache | cache, performance | measurement only (`#[cfg(test)]` counters) | `.rpm/.cache` staged write plus rename; metadata reads side-effect free | registry cache tests; #103 tarball download counter; #93 metadata-read counter (landed via #106) | conforms |
| verify (integrity) | performance | none | lockfile metadata and cached tarball bytes; failure blocks extraction | lockfile, registry metadata, and integrity failure fixture tests | conforms |
| extract | recovery, linker | none | temporary sibling staging directory | linker extract-failure recovery tests | conforms |
| link | recovery, linker | none | temporary sibling staging directory | linker missing-target recovery tests | conforms |
| write lockfile | lockfile, recovery | none | `rpm.lock` and sibling backup; restore on later failure | lockfile save tests and output-failure install fixture | conforms |
| write manifest | manifest, recovery | none | `package.json` and sibling backup; restore on later failure | manifest save tests, read-only manifest test, output-failure install fixture | conforms |
| replace output | recovery | none | rename staged output into place; backup restore on write failure | staged replacement success and extract/link failure recovery tests | conforms |

Findings:

- M4 introduces no production side effects. The tarball download counter (#103) is
  `#[cfg(test)]`-only and records inside the `RPM_REGISTRY_FIXTURE_ROOT`-gated
  branch of `get_tarball`; production downloads never reach it. The metadata-read
  counter (#93, landed via #106) records inside the corresponding branch of
  `get_registry` and is likewise test-only.
- Failed graph resolution stays side-effect free: `populate_metadata` writes only
  to in-memory `InstallMetadata`, and `resolve_dependency_graph` runs before
  `apply_resolved_graph` touches the lockfile, manifest, cache, or `node_modules`.
- Failed fetch, verify, extract, link, or write phases are not reported as
  successful installs; each maps to a labeled phase error returned to the caller,
  matching the recovery contract above.
- Graph node uniqueness is to be stated in `resolver/SPEC.md` (with an M4 gap-audit
  section in `docs/specs/core/README.md`) by #105; the dedup proofs (#94, #103)
  already confirm the resolved graph and cache represent a selected package/version
  once, consistent with the cache SPEC's version-keyed filename.
- No phase is stale, no contract is changed by M4, and no phase lacks SPEC
  ownership. No new follow-up issue is required from this audit.

## M6 Lifecycle Phase Audit

The 2026-08-11 M6 audit adds the `scripts` phase to the recovery pipeline
between `link` and `write`, so lifecycle hook execution has a contracted home.
The phase label and its position are part of this recovery contract; the
active execution is owned by `docs/specs/core/install/scripts/SPEC.md` (#141),
and the `preinstall` hook landed via #142.

| Phase | Owning SPEC(s) | M6 change | Side-effect status | Current tests | Verdict |
| --- | --- | --- | --- | --- | --- |
| scripts (lifecycle hooks) | recovery, install/scripts | phase label and position contracted (#141); `preinstall` execution landed via #142 | `preinstall` runs between `link` and `write`; a failed `scripts` phase discards the staged tree and leaves `node_modules`, `rpm.lock`, and `package.json` unchanged | #142 added success, failure, missing-command, wrong-type, and root `preinstall` fixtures under `tests/fixtures/install-projects/` | conforms |

Findings:

- The `scripts` phase is the only M6 addition to the recovery pipeline. It
  inherits the existing staged-replacement guarantee: a hook failure occurs
  while the staged replacement is linked but not yet published, so the previous
  `node_modules` stays in place and no lockfile or manifest write has run.
- The within-package lifecycle ordering (`preinstall`, `install`,
  `postinstall`, `prepare`) and the failure invariant (a failed `scripts` phase
  cannot publish partial successful install state) are owned by
  `docs/specs/core/install/scripts/SPEC.md`. This recovery SPEC owns only the
  phase label, its position, and the staged-tree discard guarantee.
- No existing M3 or M4 phase is changed by adding the `scripts` phase. The
  `resolve`, `fetch`, `extract`, `link`, and `write` labels and their
  side-effect classifications stand unchanged.

### Planned workspace lifecycle audit

The workspace contract adds no active side effects in its discovery/resolver
phase. Workspace lifecycle execution is deferred to #222. Activation requires
the scripts contract's deterministic order/cwd
fixture and a recovery fixture that injects a failing member hook after linking,
then proves all previously published root/member install trees, `rpm.lock`, and
participating manifests retain their exact bytes and permissions. The fixture
must copy immutable inputs to a temporary directory and run without a live
registry, ambient cache, uncontrolled clock, or host-absolute expected path.

## Test Fixtures

Recovery verification should cover staged replacement success plus resolve,
fetch, extract, link, scripts, and write failures that leave the previous
`node_modules` contents intact. Scripts-phase fixtures are owned by
`docs/specs/core/install/scripts/SPEC.md` (#141) and landed with #142; they
prove that a failed lifecycle hook leaves `node_modules`, `rpm.lock`, and
`package.json` unchanged.

Workspace lifecycle recovery additionally requires the planned
`workspace-lifecycle-failure` fixture owned jointly with
`docs/specs/core/install/scripts/SPEC.md`. It must cover a member `preinstall`
failure inside a copied two-member workspace and assert the full workspace
transaction boundary above before production member-hook execution is enabled.
The paired `workspace-lifecycle-member-manifest-mutation` fixture must cover a
zero-exit member hook that changes its staged `package.json`, proving the
post-hook validation failure, source-manifest immutability, and staged-view
discard guarantee with the same byte and permission checks.
The paired `workspace-lifecycle-root-workspaces-mutation` fixture freezes the
original declaration/member table and proves a zero-exit root mutation fails
before later hooks or publication. The paired
`workspace-lifecycle-root-manifest-replacement` fixture replaces the live root
manifest after discovery and the staged copy during hook execution, proving
snapshot-only inputs and final live/staged identity checks. The paired
`workspace-lifecycle-member-manifest-prebaseline-drift` fixture replaces or
mutates each live member manifest after discovery but before expected-state
capture, proving retained identity/exact-byte validation fails without adopting
the changed file as the baseline. The paired
`workspace-lifecycle-root-member-manifest-mutation` fixture proves a root hook
cannot replace a staged member manifest before its hook runs. The successful
`workspace-lifecycle-member-output-publication` fixture proves ordinary source
overlay is discarded while managed member install output publishes atomically.
The recovery fixture matrix also includes staged member-directory replacement;
same-inode staged member-directory rename across a different parent/name entry;
root/member/external hook-created symlink, hard-link, inode/device, and
published-tree aliases; root/member published-tree absolute-write; staged
escaping/dangling/cyclic-link; staged manifest symlink/directory/mode
replacement; staged hard-link alias; source-overlay link confinement; external
hook confinement; root graph-field mutation; staged lockfile integrity; and
lockfile materialization cases owned by the scripts SPEC.

`workspace-publication-cooperative-lock` uses two conforming RPM processes and
phase barriers. The second process must be unable to enter recovery, hooks,
backup, or publication while the first process holds the workspace lock. Lock
contention, a linked or malformed lock path, and an unsupported lock primitive
all fail with zero target mutation.

The paired `workspace-publication-observed-external-drift` fixture injects a
non-cooperating mutation before the locked initial revalidation and before each
per-target revalidation. Every observed drift fails before the corresponding
backup or publication and is never adopted as the baseline. The barrier matrix
rotates the target across root and member manifests, present and absent
root/member install trees, `rpm.lock`, and every additional managed output class.
The fixture and implementation documentation must also state the unsupported
race window: an unrelated writer that changes a path after its final check and
before the following filesystem operation is outside the cooperative concurrency
guarantee and cannot be claimed as atomically excluded.

Workspace publication recovery additionally requires deterministic injected
failures after publishing (1) the root install tree, (2) each member install
tree position, (3) the root manifest, (4) the lockfile, (5) every additional
managed output position, and (6) during final postcondition verification. Each
case starts with distinct prior bytes, types, modes, and native identities at
every path and proves the single transaction record restores the entire set,
removes paths that were originally absent, retains backups until full success,
and never reports a partially published install as successful.

`workspace-publication-crash-journal` records fake-filesystem durability events
and injects failure during the initial journal write, file fsync, active-name
rename, and parent-directory fsync, proving no backup or publication starts
without a durable journal. It then terminates the first invocation after the
journal fsync, after each backup intent/rename/completion fsync, after each
publication intent/rename/completion fsync, after final verification before the
committed marker, after the committed-marker fsync, and during backup cleanup. A
second invocation must process the journal before discovery, restore every
uncommitted state or finish validated committed cleanup, and preserve exact
bytes, types, modes, identities, and original absence. Corrupt journals, missing
backups, path escape, identity drift, and injected recovery failure must block
the new install while preserving all remaining journal and backup artifacts.
