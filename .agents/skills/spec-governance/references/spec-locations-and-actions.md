# SPEC Locations And Actions

## Where Specs Live

Use the narrowest authoritative SPEC for the contract.

Current repository stage:

```text
docs/specs/cli/<command>/SPEC.md
docs/specs/core/<topic>/SPEC.md
```

After the Cargo workspace is split, prefer crate-local specs for crate-owned contracts:

```text
crates/<crate-name>/docs/SPEC.md
```

Use root-level specs only for cross-crate contracts:

```text
docs/specs/<area>/.../SPEC.md
```

Repository structure and ownership rules that are not package-manager contracts live under:

```text
docs/conventions/
```

Do not treat design notes, roadmap notes, or issue text as SPEC authority. They may explain intent, but they do not override SPEC.

Do not duplicate the same contract in multiple places. If a root document summarizes a crate SPEC, link to the crate SPEC and mark the crate SPEC as authoritative.

## Classification Actions

### Conforms To SPEC

Proceed with implementation or review. Still update tests or fixtures if the behavior is contract-critical.

### Violates SPEC

Stop the implementation path. Report:

- SPEC path
- relevant section
- code path
- exact mismatch
- recommended correction

Do not fix the SPEC to match accidental code drift.

### SPEC Is Stale

Update SPEC deliberately. Include:

- why the current SPEC no longer represents intended behavior
- what code or existing behavior proves the stale state
- whether this is a correction or a contract change
- what tests or fixtures verify the updated contract

### No SPEC Exists

Create a minimal SPEC before accepting the implementation.

Use this structure:

```markdown
# Spec: <Contract Name>

Status: Draft
Owner: <crate-or-area>
Last reviewed: YYYY-MM-DD

## Purpose

## Contract

## Error Cases

## Test Fixtures

## Open Questions (Optional)
```

## Reporting Format

```text
SPEC status: conforms | violates | stale | missing
SPEC path:
Code path:
Mismatch:
Required action:
Verification:
```
