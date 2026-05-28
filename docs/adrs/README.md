# ADRs

This directory stores Architecture Decision Records for repository-level
technical and product-boundary decisions.

Use an ADR when a change decides:

- product boundary
- repository or module ownership boundaries
- crate or package split direction
- long-lived architectural constraints
- decisions that future SPECs and implementations should inherit

Do not use an ADR for routine feature behavior. Feature and contract behavior
belongs in the owning SPEC under `docs/specs/`.

## ADR And SPEC Relationship

ADRs and SPECs serve different roles:

- ADRs justify architectural and long-lived boundary decisions.
- SPECs define the active package-manager contract.

In this repository, contract work is SPEC-driven.

That means:

- SPEC is the SSOT for repository contracts
- code is the implementation of the active SPEC set, not the contract source of
  truth
- code should not silently outrun an active SPEC
- SPEC changes should happen before or with contract-changing implementation
- if a SPEC change depends on a boundary decision, the ADR should land before
  or with that SPEC change
- if a SPEC change intentionally leads implementation, the required follow-up
  work must be recorded in the same PR or linked issues

The main exception is a stale SPEC: prior human or AI changes may have merged
without the required SPEC update, leaving the written contract behind the
already-established code behavior. In that case the PR should explicitly
classify the SPEC as stale and explain why the update is a correction rather
than a new contract decision.

## File Naming

- Copy [TEMPLATE.md](/Users/gim-yechan/opensource/rpm/docs/adrs/TEMPLATE.md)
- Replace `XXXX` with the next four-digit ADR id
- Use a short kebab-case filename after the id

Example:

```text
0003-some-decision.md
```

## Frontmatter

Every ADR should include this frontmatter:

- `adr_id`
- `title`
- `status`
- `date`
- `authors`
- `deciders`
- `consulted`
- `informed`

Optional fields:

- `supersedes`
- `superseded_by`
- `related_specs`
- `related_issues`

## Status Values

- `proposed`
- `accepted`
- `superseded`
- `rejected`

## Process

1. Write the decision context and the exact decision.
2. Record consequences and immediate follow-up.
3. Update any conflicting SPECs in the same change.
4. Keep implementation details out unless they are part of the actual
   architectural constraint.

## Repository Rule

When an ADR changes an active repository boundary, public product framing, or a
long-lived ownership rule, related SPECs must be aligned in the same change so
the repository does not publish conflicting guidance.
