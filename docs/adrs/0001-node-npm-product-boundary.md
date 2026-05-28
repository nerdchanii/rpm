---
adr_id: 0001
title: Keep RPM Focused On The Node/npm Package Manager Boundary
status: accepted
date: 2026-05-29
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
---

# ADR 0001: Keep RPM Focused On The Node/npm Package Manager Boundary

Status: Accepted
Date: 2026-05-29

## Context

RPM previously carried broader language-agnostic and agent-toolchain framing in
private notes and planning discussions. That broader framing made it harder to
decide what M1 must guarantee and what current work should ignore.

The current repository already implements Node/npm-specific behavior:

- `package.json` manifest handling
- npm registry metadata reads
- npm-compatible semver work
- `node_modules` linking
- npm-style script execution

M1 also needs a trustworthy semver and install contract. Generalizing the
product boundary before that contract is stable would increase ambiguity without
improving current deliverables.

## Decision

RPM is a Node/npm package manager.

RPM does not pursue a language-agnostic package-manager boundary in the current
product direction.

M1 is defined as a small but real install pipeline for the Node/npm ecosystem.
Scope may stay narrow, but supported behavior must be correct within the stated
contract.

Semver correctness is part of the package-manager trust boundary. RPM should not
ship an intentionally weak semver model merely to keep M1 small. Supported
range behavior must be npm-compatible within the documented baseline.

## Consequences

- Public repository documents should describe RPM as a Node/npm package manager.
- Resolver, lockfile, install, linker, and script decisions should optimize for
  Node/npm correctness rather than future multi-ecosystem generality.
- Long-range ideas such as agent context surfaces, non-Node ecosystems, or
  broader toolchain orchestration are not part of the active public contract
  unless explicitly promoted later.
- Future public expansion beyond the Node/npm boundary requires a new ADR before
  contract work proceeds.

## Follow-Up

- Keep M1 planning and issues framed around the Node/npm install contract.
- Prefer SPEC updates for concrete behavior changes and ADRs for architectural
  boundary changes.
