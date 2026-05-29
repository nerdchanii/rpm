---
spec_id: package_manifest
title: Package Manifest
status: draft
owner: core/manifest
last_reviewed: 2026-05-29
authors:
  - nerdchanii
deciders:
  - nerdchanii
consulted: []
informed: []
related_adrs:
  - 0002-single-crate-cli-core-boundary
related_issues:
  - 50
---

# Spec: Package Manifest

Status: Draft
Owner: core/manifest
Last reviewed: 2026-05-29

## Purpose

`package.json` is the project manifest contract for root dependencies, dev
dependencies, scripts, and project metadata used by install and add flows.

## Contract

An absent manifest is treated as an empty manifest so commands can initialize a
new project state.

A present manifest must be valid JSON matching RPM's supported manifest shape.
Package manifest parsing errors must be returned to callers with the manifest
path and parser context. Core package-manager code must not panic on invalid
manifest content.

Saving writes the complete current manifest and truncates old content. Save
errors must be returned to callers with the manifest path.

The full npm `package.json` schema is intentionally out of scope for this
contract today.

## Error Cases

Invalid JSON is an input error and must not be reported as a successful command.
File write, create, and serialization failures must not be hidden behind
panics.

## Test Fixtures

Manifest fixtures live under `tests/fixtures/package_manifest/`.
