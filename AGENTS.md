# Repository Agent Guide

This repository should be changed conservatively.

RPM is a package manager prototype. Small correctness mistakes can affect user files, lockfiles, dependency resolution, caches, tarballs, and script execution.

## Change Discipline

Use these limits unless the user explicitly asks for a larger refactor:

- One patch should target one behavior, one bug, or one mechanical move.
- Do not combine behavior changes with file moves or renames.
- Do not combine cleanup with behavior changes.
- Avoid editing more than 3 production modules in one change.
- Avoid patches above roughly 200 changed lines, excluding fixtures and generated snapshots.
- If a change needs more than 3 production modules or more than 200 changed lines, stop and write a short plan before editing.
- If a change crosses CLI, resolver, lockfile, registry, and linker boundaries at once, stop and split it.
- When changing behavior, add or update a fixture or test in the same change.

## Workflow Guidance

Keep long-lived guidance in the right place:

- Repository safety rules belong in `AGENTS.md`.
- Human contribution process belongs in `CONTRIBUTING.md`.
- Issue and PR structure belongs in `.github/` templates.
- Active task procedure belongs in repository skills under `.agents/skills/`.
- Deterministic checks belong in `scripts/` so hooks, CI, or agents can call them.

Do not make `AGENTS.md` depend on a specific skill. Skills may depend on this guide.

## Commit Discipline

- Use one commit for one reason.
- Do not combine behavior changes with cleanup, formatting, file moves, or renames.
- A mechanical rename may be one commit even when it touches many import sites, if it has one purpose and no behavior change.
- Stage only intended files. Do not use broad staging when unrelated worktree changes exist.
- Before finishing PR work, verify the worktree is clean, the branch is pushed, validation is reported, and completed work is ready for review.

## SPEC Discipline

Treat `SPEC.md` as the authority for contracts.

A change is contract-affecting if it changes any of these:

- CLI command name, argument, flag, stdout, stderr, or exit code
- `package.json` field interpretation
- semver range interpretation
- selected package version
- lockfile field, format, or compatibility
- tarball URL, cache key, integrity, or extraction behavior
- `node_modules` layout or symlink target
- lifecycle/script execution behavior
- machine-readable diagnostic format

For a contract-affecting change:

- Find the owning SPEC before editing code.
- If no SPEC exists, create a minimal SPEC first.
- If code and SPEC disagree, classify the mismatch before editing further:
  - code violates SPEC
  - SPEC is stale
  - desired behavior changes the contract
  - no SPEC exists yet
- Do not let issue text, roadmap notes, or design notes override SPEC.

## Fixture Discipline

Tests must not mutate:

- root `package.json`
- root `rpm.lock`
- `.rpm`
- `node_modules`

Use fixtures for:

- package manifests
- lockfiles
- registry metadata
- install projects

Fixture rules:

- Copy fixtures into a temporary directory before mutation.
- Resolver tests must use offline registry fixtures unless the test is explicitly marked as networked.
- Integration fixtures should include expected output when possible: lockfile snapshot, resolved version list, or filesystem tree.
- A fixture should represent one scenario. If it needs unrelated packages or scripts, split it.

## Rust Coding Rules

Do not add new `unwrap`, `expect`, or `panic!` in these paths:

- command execution
- package manifest parsing
- registry metadata parsing
- semver/range resolution
- tarball download or extraction
- lockfile load/save
- `node_modules` linking
- script execution

Allowed exceptions:

- tests
- compile-time constants
- impossible branches that include a comment explaining the invariant

Do not ignore `Result` from:

- file create/write/rename/remove
- symlink/hardlink
- tar extraction
- network requests
- child process execution
- lockfile or package manifest save

Structured data rules:

- Use `serde_json` for JSON and `toml` for TOML.
- Use a semver/range library or dedicated domain type for version behavior.
- Do not add new parsing rules based only on `replace`, `split`, or regex for npm semver ranges.
- `parse_library_name` may split package name from requested range; it must not decide the resolved version.

Path rules:

- Pass project root/path arguments through APIs when adding new code.
- Do not hide new reads/writes behind hardcoded `./package.json`, `./rpm.lock`, `.rpm`, or `node_modules` paths.
- If old code still uses hardcoded paths, do not expand that pattern.

## Installer Safety Rules

Do not do these in installer code:

- delete existing `node_modules` before replacement install succeeds
- write `package.json` before lockfile/install state is ready
- write `rpm.lock` after a partial graph resolution as if install succeeded
- save a downloaded tarball without checking write errors
- extract a tarball without checking extraction errors
- create a symlink without checking the result
- resolve semver by stripping `^`, `~`, `*`, or comparator text manually

When touching installer flow, keep these phases separate in code or in the plan:

```text
read manifest
resolve dependency graph
download tarballs
verify integrity
extract packages
link node_modules
write lockfile/package.json
```

Lockfile-related work must preserve both:

- requested range, for example `^1.2.3`
- resolved version, for example `1.4.5`

## Validation

Run the narrowest relevant validation first:

```sh
cargo check
cargo test
cargo clippy --all-targets --all-features
```

Minimum expectations:

- Rust compile or type-level change: run `cargo check`.
- Parser, lockfile, resolver, or fixture change: run `cargo test` or the targeted test.
- Refactor touching shared code: run `cargo clippy --all-targets --all-features` when feasible.
- If validation cannot be run, report exactly what was not verified.
