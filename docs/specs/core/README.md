# Core SPECs

This directory holds core package-manager contract documents.

Core SPECs define behavior that must remain callable without CLI parsing or
terminal presentation. That includes manifest handling, semver policy,
dependency resolution, lockfile behavior, install staging, and linking.

Current core contracts:

- `manifest/SPEC.md`
- `semver/SPEC.md`
- `resolver/SPEC.md`
- `lockfile/SPEC.md`
- `install/recovery/SPEC.md`
- `install/performance/SPEC.md`
- `linker/SPEC.md`
