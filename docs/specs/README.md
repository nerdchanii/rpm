# SPECs

This directory stores the repository's authoritative contract documents.

For contract behavior, SPEC is the SSOT.

Code is not the source of truth for package-manager contracts. Code is the
implementation of the active SPEC set.

RPM is currently developed in a spec-driven way for contract-affecting work.
When behavior changes affect the package-manager contract, the owning SPEC
should be identified and updated before or with code changes.

## What A SPEC Is In This Repository

In the current codebase, a SPEC is the source of truth for active contract
behavior.

That includes contracts for:

- manifest interpretation
- semver range behavior
- resolver behavior
- lockfile format and compatibility
- install staging and recovery
- `node_modules` linker behavior
- script execution behavior
- repository ownership boundaries when they affect behavior

Current SPEC documents are not yet perfectly uniform or fully reduced to pure
executable-style specifications. Some still mix:

- active behavior contracts
- boundary rules
- staged implementation constraints
- open questions

Even so, they remain authoritative. Code must not silently drift past an active
SPEC.

## SPEC-Driven Rule

For contract-affecting work:

1. Find the owning SPEC first.
2. Classify the current state:
   - code conforms to SPEC
   - code violates SPEC
   - SPEC is stale
   - no SPEC exists yet
3. Update the SPEC before or with implementation when the intended contract is
   changing.
4. Keep tests and fixtures aligned with the stated contract.

In normal flow, SPEC changes come before implementation changes or in the same
PR. A contract-changing code change should not land first and hope the SPEC
will catch up later.

## Relationship To ADRs

ADRs justify architectural and long-lived boundary decisions.

SPECs define concrete repository contracts.

Milestone contract issues coordinate the scope and ordering of milestone work,
but they do not replace SPEC authority. If a milestone issue, issue comment, or
milestone description conflicts with an owning SPEC, the SPEC still wins until
the SPEC is deliberately updated.

Use an ADR when deciding:

- product boundary
- repository or module ownership boundary
- split direction such as `cli/core`
- long-lived architectural constraints future SPECs should inherit

Use a SPEC when defining:

- what the system must do
- what inputs are supported
- what outputs or side effects are allowed
- what errors are contractually required

If a SPEC change depends on an architectural decision, the ADR should land
before or with the SPEC update.

## SSOT Rule And Stale-SPEC Exception

SPEC is the single source of truth for repository contracts.

That means:

- reviewers should not treat current code behavior as automatically correct just
  because it already exists
- implementation and code review should start by checking the owning SPEC
- a PR that changes contract behavior should update the owning SPEC first or in
  the same change

There is one explicit exception: a stale SPEC.

A stale SPEC means the intended or already-established repository behavior is no
longer reflected in the written SPEC because prior human or AI changes were
merged without the required SPEC update, and the drift accumulated.

In that case, the SPEC may be updated to match the code, but only as an
exception path. That exception should be treated as a repair of repository
governance, not as the default workflow.

When using the stale-SPEC exception, the PR should say so explicitly and
classify the change as:

- `SPEC is stale`
- the current code path that demonstrates the drift
- why the update is a correction of established behavior rather than a new
  contract decision

## Deferred Implementation Rule

Some SPEC changes will intentionally lead implementation.

That is allowed in this repository, but only if the follow-up is explicit.

When a SPEC change is not fully implemented in the same PR, the same PR must
also do at least one of these:

- link the follow-up issue
- create the follow-up issue
- explain why the change is only a clarification of existing behavior

SPEC-only changes must not leave required implementation work implicit.

## Directory Layout

The current SPEC set is organized by ownership boundary:

```text
docs/specs/
  README.md
  TEMPLATE.md
  cli/
    README.md
    run/
      SPEC.md
  core/
    README.md
    manifest/
      SPEC.md
    semver/
      SPEC.md
    resolver/
      SPEC.md
    lockfile/
      SPEC.md
    install/
      cache/
        SPEC.md
      recovery/
        SPEC.md
      performance/
        SPEC.md
    linker/
      SPEC.md
```

Repository structure and ownership conventions that are not themselves package
manager contracts live under `docs/conventions/`.

## Suggested Structure

Use this structure for new or rewritten SPECs:

```markdown
---
spec_id: contract_name
title: Contract Name
status: draft
owner: core/area
last_reviewed: YYYY-MM-DD
authors:
  - github-handle
deciders:
  - github-handle
consulted: []
informed: []
related_adrs: []
related_issues: []
---

# Spec: Contract Name

Status: Draft
Owner: core/area
Last reviewed: YYYY-MM-DD

## Purpose

## Contract

## Error Cases

## Test Fixtures

## Open Questions (Optional)
```

Documents may temporarily contain extra sections while the current SPEC set is
being cleaned up, but new work should move toward this shape.

New or rewritten SPECs should also include frontmatter. Existing SPECs may be
converted incrementally as they are touched.

## Open Questions

SPECs may include an `Open Questions` section.

That section is allowed for questions that are still outside the active
contract and are not currently blocking implementation or review.

`Open Questions` is optional. Omit the section when there are no real
unresolved follow-up questions.

`Open Questions` should be used for:

- deferred decisions that do not change today's contract
- bounded uncertainty that readers should be aware of
- follow-up design questions owned by later work

`Open Questions` should not be used for:

- active contract gaps needed by the current implementation
- decisions that reviewers must guess in order to approve code
- behavior already established by code and tests
- vague brainstorming with no contract relevance

If an accepted SPEC keeps any open question, each item must have a linked issue
for follow-up tracking. Questions that need eventual resolution but do not yet
have an issue should not remain in an accepted SPEC.

If implementation work becomes blocked by an `Open Question`, that question is
no longer safe to leave open.

At that point, the team should resolve it through:

- an ADR, when the blocker is architectural or about ownership boundaries
- a SPEC update, when the blocker is concrete behavior contract
- both ADR and SPEC updates, when the behavior depends on a boundary decision

Implementation should not proceed past a real `Open Question` blocker by making
the decision only in code.

## M1 Baseline

Cleaning up the current SPEC set is part of M1.

M1 should start from:

- a clear Node/npm product boundary
- a clear `cli/core` ownership boundary
- a clear rule for when ADRs are required
- a clear rule that contract changes are SPEC-driven
- explicit follow-up tracking when implementation is deferred

## Current Index

- `docs/specs/cli/run/SPEC.md`: `rpm run` command contract
- `docs/specs/core/manifest/SPEC.md`: `package.json` interpretation
- `docs/specs/core/semver/SPEC.md`: npm-compatible semver selection baseline
- `docs/specs/core/resolver/SPEC.md`: dependency graph resolution boundary
- `docs/specs/core/lockfile/SPEC.md`: `rpm.lock` v1 contract
- `docs/specs/core/install/cache/SPEC.md`: install tarball cache filename and
  registry tarball write boundary
- `docs/specs/core/install/recovery/SPEC.md`: staged install replacement and
  recovery
- `docs/specs/core/install/performance/SPEC.md`: installer bottleneck and
  measurement baseline
- `docs/specs/core/linker/SPEC.md`: `node_modules` linking contract
