# Spec: Install Recovery

Status: Draft
Owner: installer/recovery
Last reviewed: 2026-05-28

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

Failures must include the failed phase in the returned error message. This
contract currently enforces `resolve`, `extract`, `link`, and `write` labels for
cached package installation. Registry fetch errors will join this contract when
the fetch path returns cache write and download failures.

## Error Cases

A failed resolve, fetch, extract, or link phase must leave the previous
`node_modules` directory untouched. A failed write phase must not be reported as
a successful install.
