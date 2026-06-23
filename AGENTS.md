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

## Source of Truth

- Contract behavior belongs in the owning `SPEC.md` under `docs/specs/`.
- Durable architectural decisions belong in `docs/adrs/`.
- GitHub Project #7 is the public roadmap/backlog, especially for M4-M10 execution planning.
- Draft issues can explain implementation intent, ordering, dependencies, and acceptance context, but they do not override SPECs or ADRs.
- If code, SPEC, ADR, and issue text disagree, classify the mismatch before editing behavior.

## GitHub Project and Roadmap Work

For GitHub Project, milestone, roadmap, backlog, or issue-group requests:

1. Inventory the relevant Project items first.
2. Group by milestone, status, and content type when those fields matter.
3. Treat `mX.0` milestone-contract issues as anchors, not as the only execution targets.
4. Update milestone-contract issues and execution DraftIssues according to the requested scope.
5. Verify against the intended target set, not only the first subset edited.

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

## Where Rules Belong

- Short agent behavior guidance: `AGENTS.md`
- Human contribution process: `CONTRIBUTING.md`
- Public contracts: `docs/specs/**/SPEC.md`
- Durable decisions: `docs/adrs/`
- Deterministic checks and hooks: `scripts/`, `justfile`, `.githooks/`, CI
- Issue and PR structure: `.github/`
- Agent workflow details: `.agents/`
