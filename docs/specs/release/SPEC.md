---
spec_id: release_packaging
title: Release Packaging and Validation
status: draft
owner: release
last_reviewed: 2026-08-13
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
related_issues:
  - 162
  - 163
---

# Spec: Release Packaging and Validation

Status: Draft
Owner: release
Last reviewed: 2026-08-13

## Purpose

Users need to know which platforms RPM release artifacts support, and
maintainers need a repeatable checklist that says whether a release is valid.
This contract defines the supported platform matrix, the platforms that are
explicitly unsupported, the ordered validation commands, and the artifact
verification expectations that apply to RPM's current release surface.

RPM does not publish pre-built binaries today. There is no release workflow
under `.github/workflows/`, and no checksum or signature generation anywhere in
the repository. The only release surface that exists is build-from-source:
`cargo build --release` followed by the install scripts
`scripts/installation.bash.sh` and `scripts/installation.zsh.sh`. A third
script, `scripts/withoutclone/installation.sh`, also exists but is not part of
this contract; see Uncovered Install Path below. This SPEC therefore describes
the contract for that surface, and names the gaps that must be closed before RPM
can claim binary-artifact support.

This SPEC covers the platforms RPM's own binary is validated on. It does not
cover the `engines`, `os`, and `cpu` fields that RPM reads from an installed
package's `package.json`. Those fields are owned by
`docs/specs/core/manifest/SPEC.md`, which records that RPM preserves them but
performs no platform filtering or gating today. The two concepts are separate:
nothing in this SPEC introduces package-level platform enforcement, and nothing
here changes package-manager semantics.

## Contract

### Supported Platform Matrix

A platform is supported only when the repository has automated evidence that
RPM builds and passes its test suite there. The current evidence is the `verify`
job in `.github/workflows/ci-test.yml`, which runs on a single runner label.

| Platform | Install method | CI evidence | Status |
| --- | --- | --- | --- |
| macOS (`macos-latest` GitHub-hosted runner) | Build from source | `verify` job in `.github/workflows/ci-test.yml` | Supported |
| Linux | Build from source | None | Unsupported / untested |
| Windows | Not available (see below) | None | Unsupported |

macOS is the only supported platform. Support is defined against the
GitHub-hosted `macos-latest` runner label as GitHub currently provisions it. RPM
does not pin a macOS version or a CPU architecture, and it declares no minimum
supported Rust version in `Cargo.toml`. Support therefore floats with the
runner image and the installed toolchain rather than resting on a pinned target
triple.

Building from source requires a working Rust toolchain with `cargo` on `PATH`.
The install scripts do not check for one and do not install one.

### Unsupported Platforms

Linux is unsupported. No CI runner builds or tests RPM on Linux, so the
repository has no evidence that it works there. RPM's dependency set is
cross-platform-capable Rust, so a Linux build may well succeed, but an
unverified build is not a support claim. Linux must be reported as untested
until a Linux CI runner exists.

Windows is unsupported, for two independent reasons:

1. No CI runner builds or tests RPM on Windows.
2. The install scripts `scripts/installation.bash.sh` and
   `scripts/installation.zsh.sh` are POSIX shell scripts using `bash` and `zsh`
   shebangs, `$HOME`, and appends to `.bashrc` / `.zshrc`. They do not run under
   Windows without a POSIX compatibility layer such as WSL or Git Bash, and RPM
   ships no native Windows installer.

No platform has pre-built binary artifacts, because no release workflow produces
any.

Release notes, README text, and install documentation must not describe Linux or
Windows as supported while this table says otherwise. Adding a platform to the
supported column requires adding CI coverage for it in the same change.

### Uncovered Install Path

`scripts/withoutclone/installation.sh` also exists. It creates a temporary
directory, clones `https://github.com/nerdchanii/rpm.git` into it, runs
`cargo build --release`, and copies the result to `~/.rpm/rpm`. It installs the
default branch HEAD as of clone time, not a pinned release commit or tag, so the
binary it produces can be a different commit than the one being released, and it
does not build with `--locked`.

That script is explicitly not covered by the validation checklist below, and it
is not a supported release path today. This SPEC neither validates it nor
specifies how it should behave. Making it a supported path would require pinning
it to a release ref and adding it to the checklist in the same change.

### Release Validation Checklist

Run these commands in order from a clean checkout of the commit being released,
on a supported platform. The release is valid only when every step passes.

```sh
# 1. Clean checkout state: no uncommitted or untracked changes. Assert the
#    porcelain output is empty; printing it is not a check.
test -z "$(git status --porcelain)"

# 2. Full repository gate. Runs format-check, audit-fixtures, fixture-smoke,
#    agent-assets, check, lint, test, and docs.
just validate

# 3. Coverage floor enforced by CI (90% lines).
just coverage

# 4. Release build with the committed dependency versions, into a known path
#    regardless of ambient CARGO_TARGET_DIR or .cargo/config.toml overrides.
CARGO_TARGET_DIR=target cargo build --release --locked

# 5. Install via the shell-appropriate script from the repository root. The
#    scripts are not committed executable, so invoke the interpreter.
bash scripts/installation.bash.sh    # bash users
zsh scripts/installation.zsh.sh      # zsh users

# 6. Smoke run the installed binary directly, not via PATH, so the check does
#    not depend on shell restart or a stale binary earlier in PATH.
~/.rpm/rpm --version
~/.rpm/rpm --help

# 7. Version agreement. `--version` prints "rpm <version>" on stdout, so compare
#    its last field against the version field in Cargo.toml. Exits non-zero on
#    drift.
installed_version="$(~/.rpm/rpm --version | awk '{print $NF}')"
manifest_version="$(awk -F'"' '/^version = "/ { print $2; exit }' Cargo.toml)"
test "$installed_version" = "$manifest_version"
```

The narrower recipes `just format-check`, `just check`, `just lint`, and
`just test` are the triage path when step 2 fails. They are subsets of
`just validate` and do not replace it as the gate.

Step 1 must assert that `git status --porcelain` produced no output. Running the
command for its printed output alone is not a check, because it exits `0` on a
dirty tree as well as a clean one.

Step 4 pins `CARGO_TARGET_DIR` because the install scripts copy from the literal
path `target/release/rpm`. If an ambient `CARGO_TARGET_DIR` or a
`.cargo/config.toml` `build.target-dir` setting redirected the build elsewhere,
step 5 would copy whatever stale binary an earlier build left at
`target/release/rpm`, and the checkout would still look clean, because `target/`
is ignored by git.

The install scripts are committed with mode `100644`, without the executable
bit. They must therefore be invoked through their interpreter, as
`bash scripts/installation.bash.sh` or `zsh scripts/installation.zsh.sh`, rather
than executed directly as `./scripts/installation.bash.sh`, which fails with a
permission error on a fresh checkout.

Step 7 is the mechanical version-drift check. It reads the CLI version by field
position from the `--version` output and the manifest version by line pattern
from `Cargo.toml`. Both extractions use POSIX `awk` and are portable across `sh`
implementations, but the `Cargo.toml` read is a text match on the first
`version = "..."` line rather than a TOML parse. That is correct for the current
manifest, where the first such line is the `[package]` version, and it must be
revisited if the manifest layout changes.

Steps 1 through 4 must be run on every release. Steps 5 through 7 verify the
artifact and are required because the install scripts are the documented
installation path and are not exercised by CI.

### Artifact Verification Expectations

Today's release artifact is the locally built binary: `target/release/rpm`,
published by the install scripts to `~/.rpm/rpm`. Verification of that artifact
means all of the following hold:

- `target/release/rpm` exists after step 4 and was built with `--locked` into the
  pinned `CARGO_TARGET_DIR`, so the committed `Cargo.lock` governed the
  dependency set and the binary is the one step 5 installs.
- `~/.rpm/rpm` exists and is executable after step 5.
- `~/.rpm/rpm --version` exits `0` and prints `rpm <version>` on stdout.
- `~/.rpm/rpm --help` exits `0` and lists the available commands.
- Step 7 passes: the version printed by `--version` equals the `version` field in
  `Cargo.toml`. These are two independent literals: the CLI version comes from
  `VERSION` in `src/cli/opt/constants.rs`, not from `CARGO_PKG_VERSION`. They can
  drift silently, so step 7 compares them mechanically and exits non-zero on
  mismatch rather than leaving the agreement to inspection.

Checksum verification, signature verification, and provenance attestation are
not part of this contract, because RPM publishes no binary artifact to verify.
The install scripts perform no integrity check, and none is expected of them
while the artifact is built locally by the user from source they already have.
These expectations must be defined when a release workflow that publishes
binaries is introduced; designing that workflow is out of scope here and belongs
to later M10 delivery items.

## Error Cases

If any checklist step fails on a supported platform, the release is not valid.
The failure must be fixed and the checklist re-run from step 1. Partial re-runs
are not sufficient, because steps 4 through 7 depend on the tree state validated
in steps 1 through 3.

If step 7 fails because `~/.rpm/rpm --version` and `Cargo.toml` disagree, the
release is not valid.
This is a real defect in the artifact's self-identification, not a documentation
nit, and it must be corrected before release rather than noted in release notes.

If a build or test failure occurs on an unsupported platform, it does not block
the release, because RPM makes no claim there. Such a failure must not be
reported as a regression against this contract, and it must not be silently
worked around in a way that implies support. The correct response is either to
add CI coverage for that platform and move it into the supported column, or to
leave it unsupported.

If a release is prepared on an unsupported platform, the checklist result does
not establish validity. Steps 1 through 4 may still be useful locally, but the
release evidence must come from a supported platform.

## Test Fixtures

There is no automated fixture for this SPEC today. The checklist is manual.

The only automated evidence backing the supported-platform claim is the `verify`
job in `.github/workflows/ci-test.yml` (workflow name `Rust`), which runs on
`macos-latest` and executes `cargo fmt --check`, `cargo check`,
`cargo clippy --all-targets --all-features -- -D warnings`, `cargo test`, and a
`cargo llvm-cov` run with a 90% line-coverage floor. That job establishes that
RPM builds and tests cleanly on macOS. It does not cover the rest of this
contract.

Specifically, no automated check currently verifies:

- that `scripts/installation.bash.sh` and `scripts/installation.zsh.sh` succeed
- that the installed `~/.rpm/rpm` runs after installation
- that `--version` agrees with `Cargo.toml`
- that RPM builds on any platform other than macOS

Closing these gaps means adding a CI job that runs the install script and the
smoke commands on a supported runner, and a check comparing the two version
literals. Until such a job exists, this SPEC is validated by a maintainer
running the checklist by hand and recording the result on the release.

## Open Questions

Each item below is a deferred gap, not an active contract. None blocks the
current build-from-source release surface. All are tracked as follow-up delivery
items under milestone #162 (M10: distribution and adoption readiness) alongside
issue #163, rather than under new issue numbers created by this SPEC.

- Should the CI matrix expand to Linux and Windows runners so those platforms
  can move into the supported column? This SPEC recommends it but does not
  specify it, and the matrix above must not be read as if that expansion exists.
- Should RPM publish pre-built binary artifacts, and if so, what checksum,
  signature, and provenance expectations apply to them? The artifact
  verification section above must be extended when that decision lands.
- Should `Cargo.toml` declare an MSRV, and should the supported matrix pin a
  macOS version and target triple instead of floating with `macos-latest`?
- Should the CLI version literal in `src/cli/opt/constants.rs` be derived from
  `CARGO_PKG_VERSION` so the two cannot drift, replacing the manual comparison
  required by the checklist above?
