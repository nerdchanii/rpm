# Install Fixture Expected-Output Convention

Install fixtures under `tests/fixtures/install-projects/<kebab-name>/` exercise the
installer against deterministic, offline registry data. This convention defines
the expected-output files a fixture uses so reviewers can distinguish real
behavior changes from fixture churn. It is a support artifact; the owning SPECs
remain the contract source of truth (see `docs/specs/core/install/**`,
`docs/specs/core/resolver/SPEC.md`, and `docs/specs/core/lockfile/SPEC.md`).

Fixture layout and required files are enforced by `scripts/audit-fixtures.sh`; new
fixtures are scaffolded by `scripts/new-install-fixture.sh` (or `just fixture <name>`).

## Invariants

- **Offline and deterministic.** Fixtures never access the network. Registry
  metadata lives in `registry/<@scope__name>.json`; tarballs are synthesized by the
  fake registry when `RPM_REGISTRY_FIXTURE_ROOT` is set. Expected output is never
  derived from a live registry response.
- **Copied before mutation.** Every mutating install fixture is copied to a
  temporary directory before the installer runs (`TempProject` + `FixtureInstallEnv`),
  so repository-root install state is never mutated by a test.
- **One fixture, one scenario.** A fixture represents one graph or error scenario.
  Split unrelated package or script behavior into separate fixtures.
- **Comments are allowed.** In line-list files, blank lines and lines starting with
  `#` are ignored by `read_expected_lines`, so a fixture can annotate why an entry
  is or is not present without changing what is asserted.

## Expected-output files

All checked-in expected outputs live under `<fixture>/expected/`.

### `resolved-packages.txt` — resolved graph snapshot

One line per resolved lockfile entry to assert:

```text
<package-name>@<selected-version> requested <range>
```

Compared (sorted) against a derivation of `LockFile::get_packages()`. Use it to
assert the resolved graph shape, including that a shared transitive package is
represented once (see the resolver SPEC node-uniqueness invariant). Omit entries
whose `requested` range is not deterministic across runs (for example a transitive
package reached through several parents records only one parent's range) and guard
their input shape against the `registry/` fixture instead.

### `error-substrings.txt` — install error snapshot

One substring per line; each must appear in the install error string. Use it for
phase-labeled failures (fetch, integrity, extract, link, write). Older fixtures
use `errors.txt` (a full-line match variant); prefer `error-substrings.txt` for
new fixtures.

## Measurement counts (asserted in-test)

Download and metadata-read counts are not checked into `expected/`; they are
asserted in the test through the fake-registry harness in `api::test_support`:

- tarball downloads per selected `package@version` — `recorded_tarball_downloads()`
- metadata reads per package name — `recorded_metadata_reads()`

Express expected counts as sorted `[(key, count)]` assertions with a failure
message that prints the full recorded snapshot, so a count drift names the
offending package/version. See
`apply_resolved_graph_downloads_shared_transitive_package_once` and
`install_counts_metadata_reads_once_per_package`.

## Optional snapshots (when a scenario needs them)

- **Lockfile snapshot.** A checked-in `*.lock` variant (for example
  `lockfile-reproducible` ships `rpm-without-tarballs.lock`) compared against the
  post-install lockfile to prove reproducibility.
- **Filesystem tree.** When a test must assert a `node_modules` layout, snapshot
  the expected tree as a separate reviewed artifact. Do not derive it from a real
  install run on the repository root.

## Canonical example

`tests/fixtures/install-projects/shared-transitive-divergent-ranges/` follows this
convention end to end: an offline `registry/` of metadata, a `package.json` input,
an `expected/resolved-packages.txt` graph snapshot (with comments explaining the
deliberately-absent shared entry), and in-test download and metadata count
assertions.
