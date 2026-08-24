---
spec_id: run_scripts
title: Run Scripts
status: draft
owner: cli/run
last_reviewed: 2026-08-24
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
  - 141
  - 148
  - 151
  - 223
---

# Spec: Run Scripts

Status: Draft
Owner: cli/run
Last reviewed: 2026-08-24

## Purpose

`rpm run` executes scripts from the root package manifest by default. Running a
script must not reinstall dependencies or mutate install output as a side
effect. Workspace targeting is an opt-in extension owned by
[`cli/workspace-targeting/SPEC.md`](../workspace-targeting/SPEC.md) (#148).

## Contract

`rpm run <script>` reads `package.json`, checks that `<script>` exists, and
returns a clean missing-script error before touching install output.

Scripts execute through the platform shell so command chaining, quoting, and
environment assignment follow normal package-script semantics. RPM prepends the
project's `node_modules/.bin` directory to `PATH` for the child process.

The CLI returns the child process exit code when the script starts and exits
normally. If the script process cannot be spawned, RPM returns a readable run
error.

`rpm run` is the **user-invoked** script execution path. It is distinct from
install lifecycle execution: lifecycle hooks (`preinstall`, `install`,
`postinstall`, `prepare`) run as an install phase and are owned by
`docs/specs/core/install/scripts/SPEC.md` (#141). The two paths share one shell
invocation model — both execute script text through the platform shell and
prepend the project `node_modules/.bin` to `PATH` — so there is a single
script-execution contract rather than two. `rpm run` reads only the targeted
manifest's `scripts` map; lifecycle execution reads recognized hooks from both
the root manifest and resolved-package registry metadata. Running a script
through `rpm run` must never trigger lifecycle execution, and lifecycle
execution must never trigger `rpm run`.

### Workspace targeting

`rpm run` opts in to the targeting modes defined by
[`cli/workspace-targeting/SPEC.md`](../workspace-targeting/SPEC.md): no option
targets the root, `--all` targets every discovered member, and repeatable
`--workspace <selector>` targets selected members. That SPEC owns exact
selector identity, validation-before-execution, and deterministic member
ordering. This run SPEC owns the target-local script
behavior: a member invocation consumes script text from the selected #145
member-table snapshot, binds the working directory to that row's retained
descriptor-validated native identity, and prepends `node_modules/.bin`
relative to the same identity. It does not reopen a member manifest or derive
filesystem identity from `member_path_key` during dispatch.
The existing child-status rule applies to each target process; it does not
settle how multiple target statuses are combined. Each `--workspace` occurrence
consumes exactly one selector value, so a separated occurrence leaves the
following script positional available to `rpm run`; a leading-hyphen selector
uses the attached `--workspace=<selector>` form. Immediately before spawning a
selected member, the consumer revalidates the retained #145 parent/name mapping
and descriptor identity. A missing, renamed, replaced, or identity-mismatched
entry fails before spawn; an old descriptor or `fchdir` alone cannot authorize
launch from a displaced directory.

A root-only invocation does not invoke workspace discovery or validate a
`workspaces` declaration. Malformed workspace metadata cannot block the
default root script; discovery is required only for the opted-in targeting
modes.

The workspace member table is consumed from the manifest and resolver
contracts for #145. This SPEC does not redefine discovery, lockfile records,
or linker output. Partial multi-target execution policy, aggregate exit codes,
and diagnostic channels remain owned by M8 #151 and the adopting command
follow-up and must be decided before implementation. #223 may implement the
target-set resolver and deterministic fixtures independently, while parser and
dispatch exposure waits for that #151 contract and the adopting `run` decision.

## Error Cases

Missing scripts fail without modifying `node_modules`. Missing binaries reached
through shell execution should produce the shell's readable error and non-zero
status. Script failures must preserve the child process status.

## Test Fixtures

Run-script verification should cover missing-script errors, child exit-code
preservation, and PATH setup for project-local binaries.

Workspace-targeting verification is planned in
[`cli/workspace-targeting/SPEC.md`](../workspace-targeting/SPEC.md). Runtime
implementation and its deterministic fixtures are owned by #223. Multi-target
execution and diagnostic policy remain gated on #151 as described above.

A package binary produced by the install transaction (the `.bin` link owned by
`docs/specs/core/linker/SPEC.md`) must be reachable through `rpm run` without
reinstalling or mutating install output. A missing binary must keep a readable
non-zero status (issue #143).
