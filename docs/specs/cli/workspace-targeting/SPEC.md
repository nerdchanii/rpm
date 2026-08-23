---
spec_id: workspace_targeting
title: Workspace Command Targeting
status: draft
owner: cli/workspace-targeting
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
  - 145
  - 148
  - 151
---

# Spec: Workspace Command Targeting

Status: Draft
Owner: cli/workspace-targeting
Last reviewed: 2026-08-24

## Purpose

This SPEC defines how a workspace-aware CLI command chooses its root or
workspace-member targets. It currently opts in only `rpm run`; other commands
retain their existing behavior and do not accept these options until their
owning SPEC opts in.

Workspace discovery is owned by
[`docs/specs/core/manifest/SPEC.md`](../../core/manifest/SPEC.md) (#145). This
SPEC consumes that result and does not redefine workspace declarations,
canonical-root confinement, member identity, or member ordering.

## Contract

### Targeting modes

With no targeting option, `rpm run <script>` targets the project root only. The
root is the sole target and the script is read from the root manifest.

`--all` targets every discovered workspace member in the #145 member table. It
excludes the project root. An all-workspace invocation with zero discovered
members is invalid.

`--workspace <selector>` is repeatable and targets workspace members only. Each
selector is an exact, case-sensitive string match against either a member
package name or that member's #145 `member_path_key`: the NFC-normalized,
valid-UTF-8, root-relative identity that uses `/` separators. Matching compares
the selector bytes directly with `member_path_key`; the CLI does not normalize
Unicode, `./`, trailing separators, platform separators, or symlinks while
matching. Native canonical paths and pre-normalization discovery strings are
never selector identities. Selectors never support globs, regular
expressions, prefixes, substrings, absolute paths, or external-package names.
The root identity and external-package identities are never selector
candidates. A selector matching neither member identity is invalid. If the
same selector matches a package-name row and a different path row, it is
ambiguous and invalid. A selector matching both identities of one row resolves
to that one member.

`--all` and `--workspace` cannot be used together. Repeated selectors and
repeated resolved members are deduplicated. Selector argument order does not
control execution order: selected members are emitted in the #145 table's
deduplicated `member_path_key` order, sorted lexicographically by unsigned
UTF-8 bytes.

The target list is fully resolved and validated before any target executes.
This includes option conflicts, selector identity errors, and the zero-member
all-workspace case. A failed validation executes no script.

For a selected member, `rpm run <script>` reads that member's manifest, uses
the member directory as the child process working directory, and prepends that
member's `node_modules/.bin` to `PATH` according to the run-script contract.
This command contract does not define how linker output or workspace links are
created; those behaviors remain owned by the linker and workspace install
contracts.

### Execution and failure ownership

The target list is resolved and validated atomically before execution. The
adopting command owns execution policy after that point. This SPEC does not
decide whether a multi-target command fails fast or continues after a target
failure, how failures are aggregated, or how a child status contributes to the
command result. A single-root invocation keeps the existing child-status
behavior from [`run/SPEC.md`](../run/SPEC.md).

M8 issue #151, together with the adopting command's SPEC and implementation
follow-up, must define the stable numeric exit code, diagnostic envelope,
wording policy, and stdout/stderr ownership for multi-target outcomes before
those behaviors are implemented. This SPEC deliberately introduces none of
those decisions.

### Command adoption and unsupported filters

This SPEC and `run/SPEC.md` opt in only `rpm run` to `--all` and
`--workspace`. A command whose owning SPEC has not opted in does not accept
these targeting options. Such use fails clearly as an unsupported command
filter before command execution; it does not silently fall back to the root.

No target or filter option other than `--all` and `--workspace <selector>` is
defined by this contract. This includes `--filter`; it is unsupported and is
rejected before command work begins. Unsupported options are not reinterpreted
as selectors or as a request for the root target.

## Implementation and help follow-ups

Issue #148 delivers this contract only. Later implementation follow-ups must
keep target-set resolution separate from command execution:

- add a target-resolution layer that consumes the validated #145 member table;
- cover that layer with the deterministic offline target-set fixtures listed
  below without exposing incomplete CLI options;
- after M8 #151 and the adopting `run` decision define failure continuation,
  aggregation, exit status, and output channels, add parser support for
  run-only `--all` and repeatable `--workspace <selector>` and dispatch each
  target using its manifest, working directory, and target-local `.bin` PATH
  rule;
- update `rpm run --help` in that same exposed CLI change to state the default
  root target, that `--all` excludes the root, exact package-name and canonical
  path selector matching, mutual exclusion, stable member-table ordering, and
  unsupported filters; and
- add an offline help regression check for those required facts without
  freezing incidental formatting or exact prose.

Help text should communicate these rules without freezing exact wording in this
SPEC. Parser flags, help, and workspace dispatch must become user-visible
together; RPM must not accept a targeting option that it cannot execute under
the settled command policy.

## Error Cases

The following are input errors and must occur before any selected target runs:

- `--all` combined with one or more `--workspace` selectors;
- `--all` when the discovery table has no members;
- a selector that is not an exact package-name or canonical root-relative path
  match;
- a selector whose package-name and path matches resolve to different rows;
- any target or filter option other than `--all` and `--workspace`, including
  `--filter`;
- targeting options supplied to a command that has not opted in.

Errors identify the command and invalid option or selector sufficiently for a
caller to correct the invocation. Stable diagnostic categories, numeric exit
codes, and output channels are owned by M8 #151.

## Test Fixtures

The implementation must add deterministic, offline fixtures before claiming
this contract is active. Planned coverage includes:

- a root-only project proving the default target is exactly the root;
- a two-member project whose table order differs from selector argument order,
  proving `--all`, exact name selectors, exact path selectors, and duplicate
  selector deduplication;
- exact-selector no-match and cross-kind ambiguity cases, including the rule
  that root and external identities cannot be selected;
- `--all` plus `--workspace` conflict and zero-member all-mode validation,
  proving no target script starts after validation failure;
- a member-local manifest, working-directory marker, and local `.bin` marker;
- a multi-target run with a failing script, pinning the resolved target set and
  table order. Whether later targets run, how the outcome aggregates, and
  numeric exit or diagnostic golden text wait for M8 #151 and the adopting
  command SPEC; and
- an offline `rpm run --help` assertion covering the required targeting facts
  without pinning exact whitespace or prose.

## Open Questions

- #151 and the adopting command SPEC own fail-fast versus continue, failure
  aggregation, stable exit-code, diagnostic-envelope, and stdout/stderr
  decisions required before implementation.
- Other commands may opt into these selectors only through their owning CLI
  SPEC; no command adoption is implied by this document.
