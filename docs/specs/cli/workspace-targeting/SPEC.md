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
  - 223
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
root is the sole target and the script is read from the root manifest. This
root-only path bypasses workspace discovery and does not validate the root
manifest's `workspaces` declaration. A malformed or unsupported workspace
declaration therefore cannot block a root-only run. Workspace discovery is
required for `--all` and `--workspace`, and discovery errors block those modes
before any script executes.

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
never selector identities. Selectors never support globs, regular expressions,
prefixes, substrings, or external-package names. A selector is never
interpreted as a filesystem path: path-shaped package names such as `/pkg` or
`C:/pkg` are literal package-name identities and remain eligible for exact name
matching. A path-shaped string that is not an exact package-name or
`member_path_key` identity remains invalid; it is never resolved against the
host filesystem. The root identity and external-package identities are never
selector candidates. A selector matching neither member identity is invalid.
If the same selector matches a package-name row and a different path row, it is
ambiguous and invalid. A selector matching both identities of one row resolves
to that one member. Each `--workspace` occurrence consumes exactly one selector
value. The separated form must preserve the following `<script>` positional
argument instead of greedily consuming it as another selector. When selector
text begins with `-`, it must use the attached `--workspace=<selector>` form so
the parser cannot reinterpret it as another option.

`--all` and `--workspace` cannot be used together. Repeated selectors and
repeated resolved members are deduplicated. Selector argument order does not
control resolved target-list order: selected members are emitted in the #145
table's deduplicated `member_path_key` order, sorted lexicographically by
unsigned UTF-8 bytes. Whether that resolved list is spawned sequentially or in
parallel, and how its output is ordered, remain owned by #151 and the adopting
command.

Targeting modes use the invocation's current working directory as the supplied
workspace root. The CLI does not search ancestor directories for a workspace
root. An `--all` or `--workspace` invocation from a member directory or any
nested descendant is rejected with a root-location error, even when an
ancestor contains a valid workspace declaration. The caller must invoke the
targeting mode from the workspace root that is supplied to #145 discovery.

Targeting consumes only the validated #145 member table from the
[`core/resolver` workspace boundary](../../core/resolver/SPEC.md). For
`--all` and `--workspace`, #145 manifest discovery has already rejected
duplicate member package names before publishing the table. Targeting itself
compares the root package name from the validated root snapshot with every
member row and rejects a root/member collision before selector matching or
execution. This preflight comparison is local to targeting and does not
require dependency resolution.

The target list is fully resolved and validated before any target executes.
This includes option conflicts, selector identity errors, and the zero-member
all-workspace case. The same preflight checks that the requested `<script>`
exists in every selected target's immutable manifest snapshot, using the root
manifest snapshot for root-only mode. If any selected snapshot lacks the
script, the entire invocation fails before any child starts, including targets
that precede the missing script in table order. A failed validation executes no
script.

For a selected member, `rpm run <script>` reads the script text only from that
row's immutable #145 manifest snapshot. It binds the child working directory
to the row's retained descriptor-validated native member identity and prepends
`node_modules/.bin` relative to that same identity according to the run-script
contract. Dispatch must not reopen `package.json`, reconstruct a native path
from `member_path_key`, or let a manifest-path or member-directory replacement
substitute script text, the working directory, or a local `.bin`. If the child
process interface cannot preserve that retained identity through a descriptor-
bound launch, dispatch fails before the child starts. Immediately before
launching each selected member, the consumer validates the retained #145
parent/name mapping and descriptor identity once as its final pathname-based
check. A missing, renamed, replaced, or identity-mismatched entry fails before
launch. After that check succeeds, the launch may use the exact retained member
descriptor even if its pathname is displaced; the displacement cannot redirect
execution because the launch performs no second pathname lookup. Retaining an
old descriptor without this immediate validation is insufficient, while
revalidating and then reopening by path is forbidden.

The #223 launch adapter must use a descriptor-bound child setup (a fork/exec-
style setup or a platform equivalent) that carries the retained member
directory descriptor into the child and establishes its working directory from
that descriptor (`fchdir` or an equivalent). `current_dir` path lookup,
reopening the member, or recomputing a native path from `member_path_key` does
not establish this boundary and fails closed. This is a per-target
execution-time safety failure: it prevents that child from starting but does
not claim that an earlier target did not run.

The target-local `.bin` needs a separate shell-lookup guarantee. A directory
descriptor alone does not protect a shell lookup that occurs after process
creation. Before the final parent/name validation, the adapter must create or
retain the view from the retained member descriptor and bind its entries to
the validated binary identities. It must carry that process-private immutable
`.bin` execution view through the shell `exec` and prepend an fd-backed view of
it to `PATH` for every shell lookup. A platform-specific
fd-backed path such as `/proc/self/fd/<fd>` or `/dev/fd/<fd>` is acceptable only
after the adapter verifies that the selected shell resolves it to the same open
view; an ordinary pathname, mutable temporary directory, symlink, or plain
`PATH` entry is not an immutable view. If the host and shell cannot provide a
verified descriptor-bound or immutable view for PATH lookup, #223 must gate
member dispatch and fail closed before the child starts rather than fall back to
path-based lookup. The adapter must record that platform capability boundary.

Whether later targets run or failures aggregate remains owned by #151 and the
adopting command. This command contract does not redefine #145 member identity
or ordering and does not define how linker output or workspace links are
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
those behaviors are implemented. It must also decide whether selected targets
spawn sequentially or in parallel and what ordering applies to their output.
Until that contract exists, #223 may implement and fixture the target-set
resolver and its deterministic ordering only; it must not expose multi-target
parser or dispatch behavior that chooses continuation, aggregation, spawn
scheduling, or output ordering. This SPEC deliberately introduces none of
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

Issue #148 delivers this contract only. Issue #223 owns runtime implementation
and deterministic fixtures and must keep target-set resolution separate from
command execution:

- add a target-resolution layer that consumes the validated #145 member table;
- cover that layer with the deterministic offline target-set fixtures listed
  below without exposing incomplete CLI options;
- after M8 #151 and the adopting `run` decision define failure continuation,
  aggregation, exit status, output channels, sequential-versus-parallel spawn,
  and target output ordering, add parser support for run-only `--all` and
  repeatable `--workspace <selector>`, enforcing exactly one selector value per
  `--workspace` occurrence (for StructOpt/Clap, an equivalent of
  `number_of_values(1)` rather than a greedy variadic argument), and dispatch
  each target using its manifest, descriptor-bound working directory, and the
  process-private immutable or descriptor-bound target-local `.bin` PATH view;
  member dispatch must be gated on a verified platform/shell capability and
  fail closed when that view cannot be provided;
- update `rpm run --help` in that same exposed CLI change to state the default
  root target and its workspace-discovery bypass, that `--all` excludes the
  root, exact package-name and portable root-relative `member_path_key`
  matching with `/` separators, mutual exclusion, stable member-table
  ordering, the attached `--workspace=<selector>` syntax for leading-hyphen
  selectors, the requirement to invoke targeting modes from the supplied
  workspace root without ancestor search, and unsupported filters; and
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
- the requested `<script>` is absent from any selected target's immutable
  manifest snapshot;
- a selector that is not an exact package-name or portable root-relative
  `member_path_key` match;
- a selector whose package-name and path matches resolve to different rows;
- duplicate member package names rejected by #145 before table publication;
- a root package name equal to a validated member row, rejected by target-set
  preflight before selector matching or execution;
- a leading-hyphen selector supplied without the attached
  `--workspace=<selector>` syntax;
- an `--all` or `--workspace` invocation whose current working directory is a
  member or nested descendant instead of the supplied workspace root;
- any target or filter option other than `--all` and `--workspace`, including
  `--filter`;
- targeting options supplied to a command that has not opted in.

Errors identify the command and invalid option or selector sufficiently for a
caller to correct the invocation. Stable diagnostic categories, numeric exit
codes, and output channels are owned by M8 #151.

## Test Fixtures

The implementation must add deterministic, offline fixtures before claiming
this contract is active. Planned coverage includes:

- a root-only project, including a malformed `workspaces` declaration, proving
  the default target is exactly the root and bypasses workspace discovery;
- a two-member project whose table order differs from selector argument order,
  proving `--all`, exact name selectors, exact path selectors, and duplicate
  selector deduplication;
- a two-member project where the first member contains the requested script and
  a later selected member does not, proving target-set preflight checks every
  immutable snapshot and starts no child when any selected script is missing;
- a parser invocation such as `rpm run --workspace member build`, proving one
  `--workspace` occurrence consumes exactly one selector and leaves `build` as
  the script positional;
- a selector list naming one member by both its package name and its
  `member_path_key`, plus repeated selectors, proving both identities resolve
  to one table row and execute once;
- a member whose package name is identical to its `member_path_key` (for
  example, both are `packages`), proving one selector that matches both
  identity fields is accepted and resolves to that row exactly once rather
  than being rejected as ambiguous;
- a member whose package name or `member_path_key` begins with `-`, proving the
  attached `--workspace=<selector>` syntax remains unambiguous to the parser;
- a leading-hyphen selector passed in separated form (`--workspace -pkg`),
  proving that form is rejected while the attached `--workspace=-pkg` form is
  accepted;
- `--all` and `--workspace` invoked from a workspace member directory and from
  a nested descendant, proving the CLI rejects those current directories
  instead of searching ancestors for a workspace root;
- exact-selector no-match and cross-kind ambiguity cases, including the rule
  that root and external identities cannot be selected;
- a member whose native path uses decomposed Unicode while its table key is NFC,
  with a package name distinct from both spellings, proving the exact NFC
  selector matches and the decomposed spelling is rejected without selector
  normalization or an accidental package-name alias match;
- the #145 discovery fixture with duplicate member package names, proving
  discovery rejects them before publishing the table, plus a targeting fixture
  with a root/member package-name collision, proving target-set preflight
  rejects it before selector matching or execution without dependency
  resolution;
- members with path-shaped package names such as `/pkg` and `C:/pkg`, proving
  those strings select literal package-name identities and are never resolved
  as filesystem paths;
- `--all` plus `--workspace` conflict and zero-member all-mode validation,
  proving no target script starts after validation failure;
- a member-local manifest, working-directory marker, and local `.bin` marker;
- an injected member-manifest and member-directory replacement after target
  resolution but before final parent/name and descriptor revalidation, proving
  final revalidation rejects the replacement and prevents displaced or
  replacement script text and local `.bin` files from executing;
- a retained-identity launch fixture that displaces the member pathname after
  the immediate parent/name and descriptor validation, proving a supported
  descriptor-bound launch still executes the retained member and cannot be
  redirected to the replacement, while a path-based adapter fails closed;
- a shell-lookup race fixture that replaces the member `.bin` directory or a
  binary entry after child creation but before a script resolves a command
  through `PATH`, proving the process-private immutable or descriptor-bound
  `.bin` view resolves the retained binary, or that dispatch is gated when the
  host and shell cannot provide that guarantee;
- a multi-target fixture where an earlier selected target has completed before
  a later target fails final identity revalidation, separating this late
  execution-time safety failure from the all-or-none missing-script preflight;
  whether later targets continue and how failures aggregate wait for #151 and
  the adopting command SPEC;
- a multi-target run with a failing script, pinning the resolved target set and
  table order. Before #151 settles execution policy, this fixture may assert
  only target-set resolution; whether later targets run, whether targets spawn
  sequentially or in parallel, how the outcome aggregates, how target output is
  ordered, and numeric exit or diagnostic golden text wait for M8 #151 and the
  adopting command SPEC;
- a non-opted command invoked with `--all` or `--workspace`, proving parser
  rejection occurs before command work and does not fall back to the root; and
- an offline `rpm run --help` assertion covering the required targeting facts
  without pinning exact whitespace or prose.

## Open Questions

- #151 and the adopting command SPEC own fail-fast versus continue, failure
  aggregation, stable exit-code, diagnostic-envelope, stdout/stderr, sequential-
  versus-parallel spawn, and target output-order decisions required before
  implementation.
- Other commands may opt into these selectors only through their owning CLI
  SPEC; no command adoption is implied by this document.
