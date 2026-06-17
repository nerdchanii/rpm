---
name: spec-governance
description: Keep SPEC.md authoritative for RPM contract-affecting changes. Use when code, reviews, or tickets may affect CLI behavior, lockfiles, manifests, semver, registry/cache/install/linking behavior, scripts, or diagnostics.
---

# SPEC Governance

## Core Rule

Treat `SPEC.md` as the source of truth for observable package-manager contracts.

If code and SPEC disagree, classify the mismatch before editing further:

- code violates active SPEC
- SPEC is stale
- desired behavior changes the contract
- no SPEC exists

## Contract Triggers

Use this skill for changes affecting:

- CLI commands, flags, output, exit codes, or error display
- lockfile format, parsing, writing, or compatibility
- package manifest interpretation
- npm registry metadata interpretation
- semver range behavior
- install transaction behavior
- cache/store layout
- `node_modules` linker layout
- script execution behavior
- public diagnostics or machine-readable output

## Core Workflow

1. Identify the changed behavior.
2. Find the narrowest owning SPEC.
3. Compare code behavior against the documented contract.
4. Classify the result.
5. Act based on classification before editing contract-affecting code further.

## When To Read References

Read [references/spec-locations-and-actions.md](references/spec-locations-and-actions.md) when you need SPEC path conventions, classification actions, minimal SPEC template, or reporting format.

## Finish Check

Before finishing contract-affecting work, verify:

- the owning SPEC exists
- code behavior matches the SPEC
- tests or fixtures cover the contract
- any SPEC change explains why it is stale or intentionally changing
- other docs link to the authoritative SPEC instead of redefining it
