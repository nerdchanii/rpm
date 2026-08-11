---
spec_id: install_lifecycle_scripts
title: Install Lifecycle Scripts
status: draft
owner: core/install/scripts
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
  - 138
  - 141
  - 142
---

# Spec: Install Lifecycle Scripts

Status: Draft
Owner: core/install/scripts
Last reviewed: 2026-08-11

## Purpose

Install-time lifecycle scripts can mutate the filesystem, so their execution
must be a contracted install phase rather than an ad-hoc side effect. This
contract defines which lifecycle hooks RPM recognizes, when they run during
install, the environment they execute in, how their failure is reported, and the
invariant that a failed script phase cannot publish partial successful install
state.

This contract is the M6 lifecycle policy named by issue #141. It owns the whole
lifecycle cluster before any execution lands in #142. It is intentionally a
policy contract only: #142 implements the first phase selected here, and the
remaining phases stay deferred under this contract until a later issue claims
them.

## Contract

### Lifecycle hook inventory

RPM recognizes the following install lifecycle hooks, read from the
`scripts` map of the root package manifest and of each resolved package's
per-version registry metadata:

| Hook | Phase owner | Scope | Status |
| --- | --- | --- | --- |
| `preinstall` | `install/scripts` | root and resolved packages | the first phase to implement (#142) |
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

The ordering **across packages** is deliberately left as an Open Question
(death-by-dependency-ordering, root-first vs leaves-first, parallel vs
sequential). This contract only fixes the within-package order today. Until that
cross-package ordering is owned by a follow-up issue, the `scripts` phase must
execute hooks in a single deterministic order within each package and must not
rely on HashMap iteration order or network timing to pick that order.

### Hook environment and PATH

Lifecycle hooks execute with an environment contract that is narrower than
npm's. This contract defines only what RPM guarantees today:

- **Working directory.** A root lifecycle hook runs with the project root as its
  working directory. A resolved-package lifecycle hook runs with that package's
  installed directory under `node_modules/` as its working directory. This
  matches the install phase that owns the hook: root hooks are owned by the
  project install, package hooks by the installed package directory.
- **PATH.** Lifecycle hooks receive the same PATH prepend policy as `rpm run`:
  the project `node_modules/.bin` is prepended to the inherited `PATH`. For
  resolved-package hooks, `.bin` generation
  (`docs/specs/core/linker/SPEC.md`) has already run in the preceding `link`
  phase, so the project `node_modules/.bin` is populated before any hook runs.
  `.bin` generation and lifecycle execution remain independent phases; this
  contract only fixes the PATH ordering, not a dependency between them.
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

A hook that mutates files inside or outside the workspace is still subject to
the user-controlled filesystem safety rules: RPM confines its own writes to
approved roots and validates inputs before mutation. Lifecycle hooks execute
arbitrary user/registry-controlled commands, so RPM does not guarantee a hook's
internal effects are reversible. What RPM guarantees is narrower: the install
transaction either reaches `write` (and publishes a complete, consistent
install) or it does not publish any install state. A hook that has already run
and mutated the staged tree before a later hook fails does not get its effects
rolled back inside the staged tree, but the staged tree itself is discarded, so
the published install never reflects a partial lifecycle run.

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

No lifecycle fixtures exist yet. This is a policy-only contract; implementation
lands in #142. The following fixture scenarios are planned for #142 and any
later lifecycle phase, and must follow `docs/conventions/install_fixture_outputs.md`
and stay offline and deterministic:

- a successful lifecycle hook that runs during install and observes the
  contracted working directory and PATH;
- a failing lifecycle hook that exits non-zero and fails the `scripts` phase
  with the `scripts` label, while the previous `node_modules` and the
  `rpm.lock`/`package.json` remain unchanged;
- a hook whose command is missing, surfacing a readable run error and non-zero
  status without publishing install state;
- a wrong-type hook value (array or object) that is discarded as absent so the
  install proceeds;
- environment and PATH behavior verification (project `node_modules/.bin`
  prepended; no `npm_*` variables set).

Each scenario must be a single deterministic fixture under
`tests/fixtures/install-projects/`, scaffolded by `scripts/new-install-fixture.sh`
or `just fixture <name>`, and must not assert behavior outside this contract.

## Open Questions

Each open question is a deferred decision that does not block the first phase
(#142). They are listed here so #142 does not silently resolve them in code.

- Cross-package hook ordering during the `scripts` phase (root-first vs
  leaves-first, sequential vs parallel, dependency order). This contract fixes
  only the within-package order. A follow-up issue must own the cross-package
  order before more than the first phase lands.
- Which, if any, npm-specific environment variables (`npm_lifecycle_event`,
  `npm_lifecycle_script`, `npm_config_*`, `npm_package_*`, `INIT_CWD`) RPM sets
  for lifecycle hooks. None are set today.
- Whether RPM supports an opt-in skip-on-failure or force-continue policy for
  lifecycle hooks. None exists today; any hook failure is fatal to the install.
- Whether `prepare` (which npm also runs at git-dep install and at local
  `npm install` without arguments) gains additional trigger points beyond the
  install ordering fixed here. Today `prepare` is only an install-phase hook
  with the same trigger as the other three.
