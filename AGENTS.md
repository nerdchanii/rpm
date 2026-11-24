# Repository Agent Guide

RPM is a Node.js package manager prototype written in Rust. The work here is
the product: CLI, resolver, manifest, lockfile, registry, cache, install,
linker, and script execution. Small correctness mistakes can affect user
files, lockfiles, dependency resolution, caches, tarballs, and script
execution.

Process tooling exists to support product work. Do not add agent workflow,
lifecycle, or automation machinery unless the user asks for it.

## Source of Truth

- Contract behavior: the owning `SPEC.md` under `docs/specs/`.
- Durable architectural decisions: `docs/adrs/`.
- Conventions (module layout, fixtures, workspace layout): `docs/conventions/`.
- Issues explain intent, scope, and done criteria. They do not override SPECs
  or ADRs.
- If code, SPEC, ADR, and issue text disagree, classify the mismatch before
  editing behavior.

## Change Discipline

- Read enough related code, SPECs, and issues to understand the request, then
  keep edits small, reversible, and tied to the requested outcome.
- If scope must be narrowed, say what is included, what is excluded, and why.
- Do not mix behavior changes with cleanup, formatting-only changes, file
  moves, or renames.
- When a change crosses major boundaries such as CLI, resolver, lockfile,
  registry, linker, or scripts, split it or write a short plan before editing.
- Behavior changes normally include a relevant test, fixture, SPEC update, or
  an explicit reason why none applies.
- Preserve unrelated worktree changes. Stage only intended files.

## Validation

Use the narrowest relevant check while iterating, then a broader gate when the
change warrants it.

```sh
just format-check
just check
just lint
just test
just validate
```

Report exactly which checks ran and which did not. Do not claim completion
without real evidence.

## Review Focus

A blocking finding identifies a reachable trigger and a concrete harm.

- **Public contract integrity:** changes to CLI, resolver, manifest, lockfile,
  registry, cache, install, linker, or script behavior that conflict with the
  owning SPEC or lack a contract decision and regression coverage.
- **User-controlled filesystem safety:** package metadata, tarball entries,
  symlinks, dependency names, or lifecycle scripts that can escape workspace,
  cache, store, or `node_modules` boundaries, overwrite user files, or leave a
  partial transaction. Validate and normalize inputs before mutation, confine
  writes to approved roots, and verify rollback or atomic completion.
- **Deterministic package state:** resolution, lockfile, registry, or fixture
  results that depend on iteration order, network timing, ambient machine
  state, or an uncontrolled clock.

Out of scope unless a separate product decision says otherwise: protection
against hostile concurrent writers who already have filesystem write access,
invisible `mmap` or mount replacement, global filesystem snapshots, or
process-private immutable execution environments.

## Skills

Repository skills live in `.agents/skills/`:

- `spec-governance`: keep SPECs authoritative for contract-affecting changes.
- `fixture-governance`: deterministic, non-mutating test fixtures.
- `rust-analyzer`: batch Rust diagnostics through `scripts/codex-rust-analyzer.sh`.
