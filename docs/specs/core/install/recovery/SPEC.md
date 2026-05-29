---
spec_id: install_recovery
title: Install Recovery
status: draft
owner: core/install/recovery
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

# Spec: Install Recovery

Status: Draft
Owner: core/install/recovery
Last reviewed: 2026-05-29

## Purpose

RPM must not destroy a working project while preparing replacement install
output. Recovery behavior defines when `node_modules` can be replaced and how
failures are reported to callers.

## Contract

Install output replacement is staged. RPM builds replacement `node_modules`
content in a temporary sibling directory first, while the existing
`node_modules` remains in place.

RPM replaces the existing directory only after extraction and linking both
complete successfully. If replacement itself fails, RPM attempts to restore the
previous directory before returning the write failure.

Failures must include the failed phase in the returned error message for cached
package installation. This contract currently enforces `resolve`, `extract`,
`link`, and `write` labels for cached package installation. Registry fetch and
cache-write failures must be returned to callers instead of being ignored or
reported as successful downloads.

## Error Cases

A failed resolve, fetch, extract, or link phase must leave the previous
`node_modules` directory untouched. A failed write phase must not be reported as
a successful install.

## Test Fixtures

Recovery verification should cover staged replacement success plus resolve,
extract, link, and write failures that leave the previous `node_modules`
contents intact.
