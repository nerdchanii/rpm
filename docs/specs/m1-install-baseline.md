---
spec_id: m1-install-baseline
title: M1 Install Baseline
status: draft
owner: resolver/install
last_reviewed: 2026-05-29
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0001
  - 0002
related_issues:
  - 41
  - 42
  - 43
  - 44
  - 45
  - 49
---

# Spec: M1 Install Baseline

Status: Draft
Owner: resolver/install
Last reviewed: 2026-05-29

## Purpose

M1 needs a single document that states what RPM now guarantees as the active
Node/npm install baseline, what M1 still does not guarantee, and how the
current code/spec state should be interpreted while the repository moves from
governance setup into implementation.

## Contract

M1 is a semver-first, spec-driven install baseline for the Node/npm package
manager.

M1 currently guarantees these behaviors:

- resolver and installer tests may use deterministic offline registry metadata
  fixtures
- supported semver requests are selected with npm-compatible range evaluation
  against package metadata
- supported semver baseline includes exact, caret, zero-major caret, tilde,
  wildcard, and common comparator ranges
- resolution completes before tarball download, extraction, linking, or lockfile
  writes begin
- the resolver produces a graph of selected package records with requested
  range, selected version, request kind, dist metadata, and dependency edges
- registry metadata reads and dependency declarations do not write tarball cache
  files
- a small deterministic fixture install can download staged tarballs, build
  `node_modules`, and write `rpm.lock` without mutating repository-root fixture
  files
- failed graph resolution returns before installer side effects
- install recovery continues to preserve existing `node_modules` when staged
  replacement fails

M1 does not yet guarantee these behaviors:

- lockfile-driven reproducible install selection when registry metadata changes
- peer dependency resolution or diagnostics
- workspace dependency resolution
- optional dependency policy
- prerelease selection policy beyond current exclusion from the supported
  baseline
- dist-tag behavior beyond `latest`
- integrity verification before extraction
- concurrent or bounded-parallel tarball downloads
- global package store behavior

## Current Gap Classification

Current M1 implementation status is classified as follows:

- conforms:
  - offline registry fixtures for resolver/install tests
  - semver-backed version selection for the supported baseline
  - graph-before-side-effects resolver path
  - metadata-read / tarball-download separation
  - deterministic small fixture install coverage
- deferred to M2 or later:
  - install reproducibility from `rpm.lock`
  - integrity verification
  - bounded parallel download scheduling
  - broader npm compatibility work outside the stated baseline

No open M1 behavior should depend on silent code drift beyond these contracts.

## Error Cases

- invalid semver requests fail before installer side effects
- unsatisfied ranges fail before installer side effects
- missing package metadata fails before installer side effects
- missing dist metadata for a selected version fails before tarball download
- failed tarball download, extraction, link, or staged replacement must not be
  reported as a successful install

## Test Fixtures

M1 relies on these fixture roots:

- `tests/fixtures/install-projects/semver-baseline/`
- `tests/fixtures/install-projects/semver-invalid-range/`
- `tests/fixtures/install-projects/semver-unsatisfied/`
- `tests/fixtures/install-projects/performance-small/`

The deterministic install path should remain verifiable with targeted cargo
tests and without mutating repository-root install state.

## Open Questions

- when bounded parallel tarball download is added, which abstraction should own
  concurrency limits and result collection
- whether later M1 follow-up needs an explicit spec for dist-tag policy beyond
  `latest`
