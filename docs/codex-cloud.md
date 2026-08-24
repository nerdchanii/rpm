# Codex Cloud environment

RPM runs in the Codex universal container with a repository-specific setup
script. The setup script prepares tools and warms the Rust dependency/build
cache; task prompts do not need to repeat those installation steps.

## Configure the environment

1. Open [Codex environment settings](https://chatgpt.com/codex/settings/environments).
2. Create or edit the environment for `nerdchanii/rpm`.
3. Use the following setup script:

   ```bash
   ./scripts/codex-cloud-setup.sh
   ```

   Run the file directly as an executable. This preserves the `/bin/bash -p`
   startup boundary; invoking it through an ambient shell can change that
   boundary.

4. Keep agent internet access disabled after setup. Enable only the minimum
   domains required by a task that must access a live registry or GitHub.
5. Save the environment and use its `Reset cache` action after changing
   toolchain or setup settings. Confirm whether setup reran and which caches
   were cleared in the Cloud UI logs; those effects are platform behavior.

The Cloud setup is intentionally independent from the shared desktop
`scripts/worktree-setup.sh` entrypoint. It uses this trusted PATH by default:

```text
${HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`RPM_CODEX_CLOUD_TRUSTED_PATH` is an explicit trust assertion by the
environment owner for a trusted Cloud environment setting. Every entry must be
an absolute, non-empty path. Ambient PATH entries are ignored and the override
must not be supplied by task input. The default `${HOME}/.cargo/bin` entry
trusts the platform-managed fresh/reset environment cache. If a task writes
and then reuses `${HOME}`, repository code cannot guarantee binary integrity;
that is a platform/cache residual.
The public setup assumes direct access to public package sources; it does not
forward proxy, registry-authentication, compiler-wrapper, or task-secret
variables.

The setup performs these steps in order:

1. Reject Cargo config and credentials files in the Cargo home and in every
   `.cargo/` directory from the repository root through its filesystem-root
   ancestors. Public locked setup does not accept source replacement or
   private credentials.
2. Require `rustup`, inspect stable `rustfmt` and `clippy` components, and
   install missing components.
3. Install `just` with `cargo install just --locked` when it is missing, then
   verify `rustfmt`, `cargo-clippy`, and `just` are discoverable.
4. Verify that `jq`, `node`, and `python3` are available.
5. Fetch the lockfile-resolved dependencies with `cargo fetch --quiet --locked`.
6. Warm the compiler cache with
   `cargo check --quiet --offline --locked --all-targets`.

Tool installation and locked dependency fetch are the setup operations that
may require network access. The warm-up check is explicitly offline and uses
the dependencies fetched in the preceding step. `--offline` constrains Cargo's
network behavior; build scripts and procedural macros remain executable code,
so their socket and file access is governed by the platform sandbox, network,
and secret policies. Setup never runs the full test suite or `just validate`.

The checked-in environment also exposes a manual `Clean worktree artifacts`
action. It runs `scripts/worktree-cleanup.sh`, which requires a clean worktree,
and removes only the repository-local Cargo `target/` directory contents. It
does not remove a worktree or modify shared Git worktree metadata. Use
`--check` to validate its preconditions without changing anything.

## Validate a cloud task

With agent internet access disabled, use the repository recipes documented in
`AGENTS.md`:

```bash
just check
just test
just validate
```

`just validate` is the full repository gate and includes the test suite. The
repository's deterministic fixture checks are designed to run offline. A task
that contacts a live package registry or GitHub must request internet access
for only the required domains, then disable it again for ordinary validation.

The setup phase may need network access for tool installation and
`cargo fetch --locked`; this is separate from task-time agent internet access.
The setup runs external tools with a minimal environment containing only the
temporary setup `HOME`, the trusted PATH, the actual Cargo/Rustup homes, the
stable toolchain, and disabled Git global/system config. It is therefore
unsuitable for environments whose setup requires a proxy or private registry
credentials.

The checked-in `.codex/environments/environment.toml` configures Codex desktop
worktrees. Codex Cloud environment setup is stored in Codex environment
settings. The `Clean worktree artifacts` action only removes this worktree's
Cargo `target/` contents after its clean-worktree check; it does not clear the
Cargo registry cache or shared Git worktree metadata. Use the environment's
`Reset cache` action when those setup caches need to be rebuilt, then confirm
the result in the Cloud UI logs. The exact Cloud allowlist, secret isolation,
and Reset cache behavior are platform boundaries and cannot be verified from
this repository.
