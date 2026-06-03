# Semver Documentation

This directory owns the semver behavior contract and supporting documentation.

- `SPEC.md` is the authoritative behavior contract for npm-compatible semver
  resolution.
- `BENCHMARKS.md` records semver benchmark context and results.
- `docs/adrs/0003-own-npm-compatible-semver.md` records the decision to own
  npm-compatible semver behavior.
- `docs/adrs/0004-semver-standalone-ready-boundary.md` records the facade and
  standalone-readiness boundary decision.

Rust API documentation belongs in rustdoc comments on the public API in
`src/core/resolver/semver/`. Generate it with:

```sh
cargo doc --no-deps
```

Do not put Rust API documentation checklists in `SPEC.md`; SPECs define
observable behavior contracts.
