# Contributing

RPM is a package manager prototype. Keep changes small, reviewable, and easy to verify.

## Issues

Use the closest issue template and include:

- context
- contract or expected behavior
- initial scope
- done criteria
- related work, if any

Issue text explains intent, but it does not override an owning SPEC.

## Pull Requests

Open PRs with a clear summary, validation notes, and a focused checklist. Keep implementation and cleanup separate.

Before marking a PR ready:

- run the narrowest relevant validation
- update the PR checklist
- push the branch
- list follow-up work instead of expanding scope

## Local Checks

Run the narrowest relevant check first. Before marking a PR ready, make sure the
same baseline Cargo checks that run in CI pass locally:

```sh
cargo fmt --check
cargo check
cargo clippy --all-targets --all-features
cargo test
```

Use local scripts when they match the change you are making. CI remains the shared verification point for pull requests.

## Commits

Use atomic commits:

- one behavior, bug, or mechanical change per commit
- no cleanup bundled with behavior changes
- no file moves bundled with behavior changes
- explicit staging when the worktree contains unrelated files
