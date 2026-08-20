# Codex Cloud environment

RPM can run in the Codex universal container with a repository-specific setup
script.

## Configure the environment

1. Open [Codex environment settings](https://chatgpt.com/codex/settings/environments).
2. Create or edit the environment for `nerdchanii/rpm`.
3. Use the following setup script:

   ```bash
   ./scripts/codex-cloud-setup.sh
   ```

4. Keep agent internet access disabled for repository validation. Enable only
   the domains required by a task that must access a live registry or GitHub.
5. Save the environment and reset its cache after changing toolchain settings.

The setup installs the Rust formatting and lint components, installs `just`
when the universal image does not provide it, verifies the auxiliary tools used
by repository checks, fetches locked Cargo dependencies, and checks all Rust
targets. The Cloud compatibility wrapper delegates to the shared
`scripts/worktree-setup.sh` entrypoint.

The checked-in environment also exposes a manual `Clean worktree artifacts`
action. It runs `scripts/worktree-cleanup.sh`, which requires a clean worktree,
and removes only the repository-local Cargo `target/` directory contents. It
does not remove a worktree or modify shared Git worktree metadata. Use
`--check` to validate its preconditions without changing anything.

## Validate a cloud task

Use the repository recipes documented in `AGENTS.md`:

```bash
just check
just test
just validate
```

`just validate` is the full repository gate. Package operations that contact a
live registry require agent internet access; deterministic fixture tests run
offline.

The checked-in `.codex/environments/environment.toml` configures Codex desktop
worktrees. Codex Cloud environment setup is stored in Codex environment
settings.
