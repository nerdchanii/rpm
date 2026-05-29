---
spec_id: run_scripts
title: Run Scripts
status: draft
owner: cli/run
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

# Spec: Run Scripts

Status: Draft
Owner: cli/run
Last reviewed: 2026-05-29

## Purpose

`rpm run` executes scripts from the root package manifest. Running a script must
not reinstall dependencies or mutate install output as a side effect.

## Contract

`rpm run <script>` reads `package.json`, checks that `<script>` exists, and
returns a clean missing-script error before touching install output.

Scripts execute through the platform shell so command chaining, quoting, and
environment assignment follow normal package-script semantics. RPM prepends the
project's `node_modules/.bin` directory to `PATH` for the child process.

The CLI returns the child process exit code when the script starts and exits
normally. If the script process cannot be spawned, RPM returns a readable run
error.

## Error Cases

Missing scripts fail without modifying `node_modules`. Missing binaries reached
through shell execution should produce the shell's readable error and non-zero
status. Script failures must preserve the child process status.

## Test Fixtures

Run-script verification should cover missing-script errors, child exit-code
preservation, and PATH setup for project-local binaries.

## Open Questions

None currently.
