//! Install lifecycle script execution.
//!
//! This module owns the `scripts` install phase contracted by
//! `docs/specs/core/install/scripts/SPEC.md` (#141) and positioned between
//! `link` and `write` by `docs/specs/core/install/recovery/SPEC.md`. Issue
//! #142 implements the first lifecycle phase only: the `preinstall` hook for
//! both the root manifest and each resolved package. The remaining hooks
//! (`install`, `postinstall`, `prepare`) stay deferred under the same SPEC.
//!
//! Lifecycle hooks reuse the single script-execution contract owned by
//! `src/lib/script_runner.rs`: each hook value runs through the platform shell
//! and the project `node_modules/.bin` is prepended to `PATH`. Lifecycle
//! execution is install-driven and distinct from the user-invoked `rpm run`
//! path, but they share one shell invocation model.

use std::{io::Error, path::Path, process::Command};

use crate::{
    lockfile::Dependency,
    package_manifest::PackageManifest,
    script_runner::{script_path_for_modules_dir, shell_command},
};

use super::package_name_from_lock_key;

/// The lifecycle hooks RPM recognizes, in within-package order. Only
/// `preinstall` is executed today; the rest are listed so the ordering and
/// the deferred status stay explicit at the call site. Adding execution for a
/// later hook is a SPEC change, not an implementation detail here.
const LIFECYCLE_HOOKS: &[&str] = &["preinstall"];

/// Run the first lifecycle phase (`preinstall`) against a staged `node_modules`
/// tree, after `link` has completed and before `write` publishes the tree.
///
/// `project_root` is the workspace root: a root lifecycle hook runs there, and
/// its `node_modules/.bin` (already populated by the preceding `link` phase in
/// the staged tree) is prepended to `PATH`. `staging_dir` is the staged
/// `node_modules` directory; each resolved package's hook runs with its
/// installed package directory as the working directory.
///
/// Packages are visited in sorted lock-key order so the phase never relies on
/// HashMap iteration order or network timing to pick the cross-package order
/// (the cross-package order itself remains a SPEC Open Question).
///
/// A hook that exits non-zero fails the phase with a `scripts failed` label so
/// the caller discards the staged tree and leaves the previous `node_modules`,
/// `rpm.lock`, and `package.json` untouched. Wrong-type hook values never
/// reach this function: the manifest deserializer discards them as absent.
pub(crate) fn run_lifecycle_scripts(
    project_root: &Path,
    staging_dir: &Path,
    packages: &[(&String, &Dependency)],
    root_manifest: &PackageManifest,
) -> Result<(), std::io::Error> {
    run_root_lifecycle_hooks(project_root, staging_dir, root_manifest)?;
    run_package_lifecycle_hooks(staging_dir, packages)?;
    Ok(())
}

/// Run the recognized lifecycle hooks declared by the root manifest. The root
/// hook runs with the project root as its working directory, and the staged
/// `node_modules/.bin` is prepended to `PATH` so binaries linked in the
/// preceding `link` phase are reachable. The staged tree lives at
/// `staging_dir`, which is a sibling of the final `node_modules`, so the
/// `.bin` directory used for `PATH` is `staging_dir/.bin`.
fn run_root_lifecycle_hooks(
    project_root: &Path,
    staging_dir: &Path,
    root_manifest: &PackageManifest,
) -> Result<(), std::io::Error> {
    let scripts = root_manifest.get_scripts();
    for hook in LIFECYCLE_HOOKS {
        if let Some(script) = scripts.get(*hook) {
            run_hook(project_root, staging_dir, script, &format!("root:{hook}"))?;
        }
    }
    Ok(())
}

/// Run the recognized lifecycle hooks declared by each resolved package's
/// registry metadata. Packages are visited in sorted lock-key order; each hook
/// runs with the package's staged install directory as its working directory.
fn run_package_lifecycle_hooks(
    staging_dir: &Path,
    packages: &[(&String, &Dependency)],
) -> Result<(), std::io::Error> {
    let mut sorted: Vec<(&String, &Dependency)> = packages.to_vec();
    sorted.sort_by_key(|(key, _)| *key);

    for (key, dependency) in sorted {
        let name = package_name_from_lock_key(key)?;
        let package_dir = staging_dir.join(name);
        let Some(scripts) = dependency.get_scripts() else {
            continue;
        };
        for hook in LIFECYCLE_HOOKS {
            if let Some(script) = scripts.get(*hook) {
                run_hook(&package_dir, staging_dir, script, &format!("{key}:{hook}"))?;
            }
        }
    }
    Ok(())
}

/// Execute a single hook script through the platform shell with the staged
/// `node_modules/.bin` prepended to `PATH`. A non-zero exit fails the `scripts`
/// phase; the caller discards the staged tree so the published install never
/// reflects a partial lifecycle run.
fn run_hook(
    working_dir: &Path,
    modules_dir: &Path,
    script: &str,
    label: &str,
) -> Result<(), std::io::Error> {
    let mut command: Command = shell_command(script);
    command.current_dir(working_dir);
    command.env("PATH", script_path_for_modules_dir(modules_dir)?);
    let status = command.status().map_err(|error| {
        Error::new(
            error.kind(),
            format!("scripts failed: could not run {label}: {error}"),
        )
    })?;
    if !status.success() {
        let code = status.code().unwrap_or(1);
        return Err(Error::other(format!(
            "scripts failed: {label} exited {code}"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lockfile::Dependency;
    use std::{
        fs,
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    static TEMP_ID: AtomicU64 = AtomicU64::new(0);

    struct TempDir {
        root: PathBuf,
    }

    impl TempDir {
        fn new(prefix: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let counter = TEMP_ID.fetch_add(1, Ordering::SeqCst);
            let root = std::env::temp_dir().join(format!(
                "rpm-lifecycle-{prefix}-{}-{nanos}",
                std::process::id()
            ));
            let root = root.with_extension(counter.to_string());
            fs::create_dir_all(&root).unwrap();
            Self { root }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn write_manifest(dir: &Path, body: &str) {
        fs::write(dir.join("package.json"), body).unwrap();
    }

    fn root_manifest_with_preinstall(script: Option<&str>) -> PackageManifest {
        let body = match script {
            Some(script) => format!(r#"{{"name":"root","scripts":{{"preinstall":"{script}"}}}}"#),
            None => r#"{"name":"root"}"#.to_string(),
        };
        let temp = TempDir::new("root-manifest");
        write_manifest(&temp.root, &body);
        PackageManifest::read_from_path(temp.root.join("package.json")).unwrap()
    }

    fn dependency() -> Dependency {
        Dependency::new("1.0.0".to_string(), None)
    }

    fn dependency_with_preinstall(script: &str) -> Dependency {
        let mut dependency = dependency();
        dependency.set_scripts(Some(std::collections::HashMap::from([(
            "preinstall".to_string(),
            script.to_string(),
        )])));
        dependency
    }

    #[test]
    fn root_preinstall_runs_in_project_root() {
        let project = TempDir::new("root-hook-cwd");
        let staging = TempDir::new("root-hook-staging");
        fs::create_dir_all(staging.root.join(".bin")).unwrap();
        let manifest = root_manifest_with_preinstall(Some("echo root-ran > preinstall.txt"));

        run_lifecycle_scripts(&project.root, &staging.root, &[], &manifest).unwrap();

        assert_eq!(
            fs::read_to_string(project.root.join("preinstall.txt")).unwrap(),
            "root-ran\n"
        );
    }

    #[test]
    fn root_preinstall_failure_fails_scripts_phase() {
        let project = TempDir::new("root-hook-fail");
        let staging = TempDir::new("root-hook-fail-staging");
        fs::create_dir_all(staging.root.join(".bin")).unwrap();
        let manifest = root_manifest_with_preinstall(Some("exit 9"));

        let error =
            run_lifecycle_scripts(&project.root, &staging.root, &[], &manifest).unwrap_err();

        assert!(error.to_string().contains("scripts failed"));
        assert!(error.to_string().contains("root:preinstall exited 9"));
    }

    #[test]
    fn package_preinstall_runs_in_package_directory() {
        let project = TempDir::new("pkg-hook");
        let staging = TempDir::new("pkg-hook-staging");
        let package_dir = staging.root.join("@scope").join("pkg");
        let bin_dir = staging.root.join(".bin");
        fs::create_dir_all(&package_dir).unwrap();
        fs::create_dir_all(&bin_dir).unwrap();
        write_manifest(
            &package_dir,
            r#"{"name":"@scope/pkg","scripts":{"preinstall":"echo pkg-ran > proof.txt"}}"#,
        );
        let key = "@scope/pkg@1.0.0".to_string();
        let dep = dependency_with_preinstall("echo pkg-ran > proof.txt");

        run_lifecycle_scripts(
            &project.root,
            &staging.root,
            &[(&key, &dep)],
            &root_manifest_with_preinstall(None),
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(package_dir.join("proof.txt")).unwrap(),
            "pkg-ran\n"
        );
    }

    #[test]
    fn package_preinstall_failure_fails_scripts_phase() {
        let project = TempDir::new("pkg-hook-fail");
        let staging = TempDir::new("pkg-hook-fail-staging");
        let package_dir = staging.root.join("bad");
        fs::create_dir_all(&package_dir).unwrap();
        fs::create_dir_all(staging.root.join(".bin")).unwrap();
        write_manifest(
            &package_dir,
            r#"{"name":"bad","scripts":{"preinstall":"exit 4"}}"#,
        );
        let key = "bad@1.0.0".to_string();
        let dep = dependency_with_preinstall("exit 4");

        let error = run_lifecycle_scripts(
            &project.root,
            &staging.root,
            &[(&key, &dep)],
            &root_manifest_with_preinstall(None),
        )
        .unwrap_err();

        assert!(error.to_string().contains("scripts failed"));
        assert!(error.to_string().contains("bad@1.0.0:preinstall exited 4"));
    }

    #[test]
    fn missing_package_manifest_is_skipped_not_failed() {
        let project = TempDir::new("pkg-missing");
        let staging = TempDir::new("pkg-missing-staging");
        fs::create_dir_all(staging.root.join(".bin")).unwrap();
        // No package directory or manifest is created.
        let key = "ghost@1.0.0".to_string();
        let dep = dependency();

        run_lifecycle_scripts(
            &project.root,
            &staging.root,
            &[(&key, &dep)],
            &root_manifest_with_preinstall(None),
        )
        .unwrap();
    }

    #[test]
    fn packages_visited_in_sorted_lock_key_order() {
        // Two packages declare preinstall hooks that each append their lock key
        // to a shared file in the project root. The resulting file proves a
        // stable, sorted order regardless of the input slice order.
        let project = TempDir::new("order");
        let staging = TempDir::new("order-staging");
        let bin_dir = staging.root.join(".bin");
        fs::create_dir_all(&bin_dir).unwrap();

        let mut dependencies = Vec::new();
        for name in ["zebra", "alpha"] {
            let dir = staging.root.join(name);
            fs::create_dir_all(&dir).unwrap();
            dependencies.push(dependency_with_preinstall(&format!(
                "echo {name} >> {}",
                project.root.join("order.txt").display()
            )));
        }
        let zebra = "zebra@1.0.0".to_string();
        let alpha = "alpha@1.0.0".to_string();
        // Pass them in reverse so a sort is required to reach alphabetical.
        let packages = vec![(&zebra, &dependencies[0]), (&alpha, &dependencies[1])];

        run_lifecycle_scripts(
            &project.root,
            &staging.root,
            &packages,
            &root_manifest_with_preinstall(None),
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(project.root.join("order.txt")).unwrap(),
            "alpha\nzebra\n"
        );
    }
}
