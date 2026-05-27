# Contributing

RPM is a package manager prototype. Keep changes small, reviewable, and easy to verify.

## Issues

Use the closest issue template and include:

- context
- contract or expected behavior
- initial scope
- done criteria
- related work, if any

Issue text explains intent, but it does not override `AGENTS.md` or an owning SPEC.

## Pull Requests

Open PRs with a clear contract and checklist. Keep implementation and cleanup separate.

Before marking a PR ready:

- run the narrowest relevant validation
- update the PR checklist
- push the branch
- confirm the worktree is clean
- list follow-up work instead of expanding scope

## Automation Boundaries

Use `scripts/` for deterministic checks that agents, hooks, or CI can call.

Current workflow checks are local scripts. Hook and CI integration should be added in focused follow-up work, not bundled with documentation-only workflow changes.

## Commits

Use atomic commits:

- one behavior, bug, or mechanical change per commit
- no cleanup bundled with behavior changes
- no file moves bundled with behavior changes
- explicit staging when the worktree contains unrelated files
