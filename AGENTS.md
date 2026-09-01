# Repository Agent Guide

RPM is a package manager prototype. Small correctness mistakes can affect user files, lockfiles, dependency resolution, caches, tarballs, and script execution.

This file is a navigation and judgment guide, not the enforcement layer. Deterministic rules should live in `just` recipes, scripts, hooks, Clippy/rustfmt config, CI, SPECs, ADRs, or issue templates.

## Operating Model

- Be broad in discovery and surgical in edits.
- Read enough related code, docs, SPECs, issues, and Project items to understand the request before narrowing the edit set.
- Keep actual edits small, reversible, and tied to the user's requested outcome.
- If scope must be narrowed, say what is included, what is excluded, and why.
- Do not treat a representative file, planning issue, milestone anchor, or draft issue as the whole target set unless the user explicitly asks for only that item.
- If a guardrail can be checked mechanically, prefer adding or using a check over adding more prompt text.
- Codex is the current primary and default repository operating path. Codex Cloud execution and repository-configured Codex Automatic review are current mechanisms; provider-specific details belong in adapters, environments, or role instructions.
- Shared lifecycle, state, validation, and mutation contracts apply provider-neutrally. They describe required outcomes and evidence while preserving the existing provider-specific execution records.

## Source of Truth

- Contract behavior belongs in the owning `SPEC.md` under `docs/specs/`.
- Durable architectural decisions belong in `docs/adrs/`.
- GitHub Project #7 is the local roadmap and backlog-preparation inventory, especially for M4-M10 execution planning.
- Open issue lifecycle labels are the Cloud scheduled execution queue.
- Draft issues can explain implementation intent, ordering, dependencies, and acceptance context, but they do not override SPECs or ADRs.
- If code, SPEC, ADR, and issue text disagree, classify the mismatch before editing behavior.
- A GitHub issue is the durable handoff for fresh workers. Its current body preserves the goal, scope, non-goals, acceptance criteria, dependencies, validation plan, and necessary context.
- Issue #207 remains the open implementation that will persist and validate the executable-issue contract and its schema/mutations; current manual guidance does not claim automatic template enforcement. Issue #208 owns discovered-work disposition.

## GitHub Project and Roadmap Work

For GitHub Project, milestone, roadmap, backlog, or issue-group requests:

1. Inventory the relevant Project items first.
2. Group by milestone, status, and content type when those fields matter.
3. Treat `mX.0` milestone-contract issues as anchors, not as the only execution targets.
4. Update milestone-contract issues and execution DraftIssues according to the requested scope.
5. Verify against the intended target set, not only the first subset edited.

The agent-backed backlog policy lives in
`.agents/workflows/backlog-policy.json`. Raw ideas enter Project #7 locally with
the research state. Only open issues carrying the ready lifecycle label are
eligible for Cloud scheduled ticket execution, and every scheduled execution
must claim one item before starting work. Project membership is not an
execution eligibility condition. Respect the policy batch limits and allowed
state transitions.

Repository agents consume review feedback after it appears on a pull request.
Issue #199 owns repository-external Codex Automatic review creation. Lifecycle
ticket execution does not create or request an Automatic review or post `@codex review`;
its arrival is asynchronous evidence, not a synchronous
completion dependency or blocking condition. Review reconciliation returns
`no-work` without mutation when feedback is absent and rechecks on a later
scheduled run. Explicit review-only workflows retain their documented
non-blocking COMMENT review-posting scope. Issue #195 owns the planned
deterministic blocking CI aggregate contract; current `merge_gate.required_checks`
consumes policy `metadata` and `verify` conclusions as individual evidence.

The scheduled `merge-gatekeeper` is the actual merge owner, with issue #202
preserving and organizing that lifecycle ownership. It is defined in
`.agents/skills/merge-gatekeeper/`, merges at most one awaiting-merge pull
request per run, and only when the deterministic policy `merge_gate` passes:
required checks concluded, the PR is mergeable, and no unresolved P0/P1 finding
remains. Subagents never merge; the tool policy hook enforces this.

## Change Discipline

- Do not move or rename files unless the user asks for it or the move/rename is the core purpose of the patch.
- Do not mix behavior changes with cleanup, formatting-only changes, file moves, or renames.
- When a change crosses major boundaries such as CLI, resolver, lockfile, registry, linker, or scripts, split it or write a short plan before editing.
- Behavior changes should normally include a relevant test, fixture, SPEC update, or explicit reason why none applies.
- Preserve unrelated worktree changes. Stage only intended files.

## Validation

Use the narrowest relevant check while iterating, then a broader gate when the change warrants it.

Common commands:

```sh
just format-check
just check
just lint
just test
just validate
```

Report exactly which checks ran and which did not. Do not claim completion without real evidence.

## Code Review Rules

- **Public contract integrity:** Flag changes to CLI, resolver, manifest, lockfile, registry, cache, install, linker, or script behavior that conflict with the owning SPEC or lack an explicit contract decision and regression coverage. The safe path identifies the owning SPEC, classifies the change, updates the narrowest contract when authorized, and adds focused regression evidence.
- **User-controlled filesystem safety:** Flag package metadata, tarball entries, symlinks, dependency names, or lifecycle scripts that can escape workspace, cache, store, or `node_modules` boundaries, overwrite user files, or leave a partial transaction. The safe path validates and normalizes inputs before mutation, confines writes to approved roots, rejects traversal and unsafe links, and verifies rollback or atomic completion.
- **Deterministic package state:** Flag resolution, lockfile, registry, or fixture results that depend on iteration order, network timing, ambient machine state, or an uncontrolled clock. The safe path defines stable ordering, uses explicit deterministic inputs and clocks, isolates network evidence, and proves repeatability with deterministic fixtures.

## Where Rules Belong

- Short agent behavior guidance: `AGENTS.md`
- Human contribution process: `CONTRIBUTING.md`
- Public contracts: `docs/specs/**/SPEC.md`
- Durable decisions: `docs/adrs/`
- Deterministic checks and hooks: `scripts/`, `justfile`, `.githooks/`, CI
- Issue and PR structure: `.github/`
- Agent workflow details: `.agents/`
