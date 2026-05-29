---
name: spec-governance
description: Keep SPEC.md authoritative for contract-affecting code changes, reviews, and stale-spec updates.
---

# SPEC Governance

## Core Rule

Treat `SPEC.md` as the source of truth for contracts.

If code and SPEC disagree, do not silently prefer code. Classify the mismatch before editing further:

- **Code violates active SPEC**: block or revise the code change.
- **SPEC is stale**: update SPEC deliberately, with evidence.
- **Desired behavior changes the contract**: update SPEC before or with implementation.
- **No SPEC exists**: create a minimal SPEC before accepting the contract change.

## What Counts As A Contract

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

Repository structure and ownership rules that are not package-manager contracts
live under:

```text
docs/conventions/
```

Do not treat design notes, roadmap notes, or issue text as SPEC authority. They may explain intent, but they do not override SPEC.

Do not duplicate the same contract in multiple places. If a root document summarizes a crate SPEC, link to the crate SPEC and mark the crate SPEC as authoritative.

## Workflow

1. Identify the changed behavior.
2. Find the owning SPEC.
3. Compare the code change against the documented contract.
4. Classify the result:
   - conforms to SPEC
   - violates SPEC
   - SPEC is stale
   - no SPEC exists for this contract
5. Act based on classification.

## Classification Actions

### Conforms To SPEC

Proceed with implementation or review.

Still update tests or fixtures if the behavior is contract-critical.

### Violates SPEC

Stop the implementation path.

Report:

- SPEC path
- relevant section
- code path
- exact mismatch
- recommended correction

Do not “fix” the SPEC to match accidental code drift.

### SPEC Is Stale

Update SPEC deliberately.

The update must include:

- why the current SPEC no longer represents intended behavior
- what code or existing behavior proves the stale state
- whether this is a correction or a contract change
- what tests/fixtures verify the updated contract

### No SPEC Exists

Create a minimal SPEC before accepting the implementation.

Use this minimal structure:

```markdown
# Spec: <Contract Name>

Status: Draft  
Owner: <crate-or-area>  
Last reviewed: YYYY-MM-DD

## Purpose

## Contract

## Error Cases

## Test Fixtures

## Open Questions
```

## Review Checklist

Before finishing any contract-affecting change, verify:

- The owning SPEC exists.
- The code behavior matches the SPEC.
- The SPEC defines observable contract, not incidental implementation detail.
- Tests or fixtures cover the contract.
- If the SPEC changed, the change explains why.
- Any `Open Questions` left in an accepted SPEC have linked tracking issues.
- Other docs link to the authoritative SPEC instead of redefining it.

## Reporting Format

When reporting a SPEC conflict, use:

```text
SPEC status: conforms | violates | stale | missing
SPEC path:
Code path:
Mismatch:
Required action:
Verification:
```
