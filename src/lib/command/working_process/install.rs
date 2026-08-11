use crate::{
    command::working_process::add_with_cache_dir, lockfile::LockFile, node_linker::NodeModules,
    package_manifest::PackageManifest,
};
use std::{
    fs,
    io::{self, Error, ErrorKind},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub async fn install() -> std::io::Result<()> {
    install_in(Path::new(".")).await
}

async fn install_in(project_root: &Path) -> std::io::Result<()> {
    let package_path = project_root.join("package.json");
    let lockfile_path = project_root.join("rpm.lock");
    let cache_dir = project_root.join(".rpm").join(".cache");
    let node_modules_path = project_root.join("node_modules");

    let mut package_manifest = PackageManifest::read_from_path(&package_path)?;
    let dependencies = package_manifest.get_dependencies();
    let mut lockfile = LockFile::load_from_path(&lockfile_path)?;
    let libs = dependencies
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    add_with_cache_dir(
        &mut package_manifest,
        &mut lockfile,
        libs,
        false,
        false,
        &cache_dir,
    )
    .await?;

    let dev_deps = package_manifest.get_dev_dependencies();
    let dev_libs = dev_deps
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    add_with_cache_dir(
        &mut package_manifest,
        &mut lockfile,
        dev_libs,
        true,
        false,
        &cache_dir,
    )
    .await?;

    let state_paths: [&Path; 2] = [&lockfile_path, &package_path];
    let snapshots = capture_install_state(&state_paths)?;
    let mut prepared = match NodeModules::prepare_from_lockfile(
        &node_modules_path,
        &lockfile,
        &cache_dir,
        &package_manifest,
    ) {
        Ok(prepared) => prepared,
        Err(error) => return Err(restore_snapshot_after(&state_paths, &snapshots, error)),
    };
    let package_changed = state_changed(&package_path, &snapshots[1])
        .map_err(|error| restore_snapshot_after(&state_paths, &snapshots, error))?;
    let package_manifest_after_hook = if package_changed {
        Some(
            PackageManifest::read_from_path(&package_path)
                .map_err(|error| restore_snapshot_after(&state_paths, &snapshots, error))?,
        )
    } else {
        None
    };
    let lockfile_changed = state_changed(&lockfile_path, &snapshots[0])
        .map_err(|error| restore_snapshot_after(&state_paths, &snapshots, error))?;
    let lockfile_after_hook = if lockfile_changed {
        Some(
            LockFile::load_from_path(&lockfile_path)
                .map_err(|error| restore_snapshot_after(&state_paths, &snapshots, error))?,
        )
    } else {
        None
    };
    if let Some(package_manifest_after_hook) = package_manifest_after_hook {
        package_manifest = package_manifest_after_hook;
    }
    if let Some(mut lockfile_after_hook) = lockfile_after_hook {
        merge_generated_packages(&mut lockfile_after_hook, &lockfile);
        lockfile = lockfile_after_hook;
    }
    if package_changed || lockfile_changed {
        prepared = NodeModules::prepare_from_lockfile_without_root_lifecycle(
            &node_modules_path,
            &lockfile,
            &cache_dir,
            &package_manifest,
        )
        .map_err(|error| restore_snapshot_after(&state_paths, &snapshots, error))?;
    }
    let mut backups = match backup_install_state(&state_paths) {
        Ok(backups) => backups,
        Err(error) => return Err(restore_snapshot_after(&state_paths, &snapshots, error)),
    };
    if let Err(error) = lockfile.save_to_path(&lockfile_path) {
        return Err(restore_after(&mut backups, error));
    }
    if let Err(error) = package_manifest.save_to_path(&package_path) {
        return Err(restore_after(&mut backups, error));
    }
    if let Err(error) = restore_state_permissions(&backups) {
        return Err(restore_after(&mut backups, error));
    }
    let output_result = prepared.publish().map(|_| ());

    if let Err(error) = output_result {
        return Err(restore_after(&mut backups, error));
    }
    commit_install_state(backups)?;
    Ok(())
}

struct StateBackup {
    final_path: PathBuf,
    backup_path: Option<PathBuf>,
    permissions: Option<fs::Permissions>,
}

struct StateSnapshot {
    contents: Option<Vec<u8>>,
    permissions: Option<fs::Permissions>,
}

fn capture_install_state(paths: &[&Path]) -> io::Result<Vec<StateSnapshot>> {
    paths
        .iter()
        .map(|path| {
            let metadata = match fs::symlink_metadata(path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == ErrorKind::NotFound => {
                    return Ok(StateSnapshot {
                        contents: None,
                        permissions: None,
                    });
                }
                Err(error) => return Err(error),
            };
            if !metadata.file_type().is_file() {
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!(
                        "install state path {} is not a regular file",
                        path.display()
                    ),
                ));
            }
            if metadata.permissions().readonly() {
                return Err(Error::new(
                    ErrorKind::PermissionDenied,
                    format!("{} is read-only", path.display()),
                ));
            }
            Ok(StateSnapshot {
                contents: Some(fs::read(path)?),
                permissions: Some(metadata.permissions()),
            })
        })
        .collect()
}

fn state_changed(path: &Path, snapshot: &StateSnapshot) -> io::Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Ok(snapshot.contents.is_some());
        }
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_file() {
        return Err(Error::new(
            ErrorKind::InvalidData,
            format!(
                "install state path {} is not a regular file",
                path.display()
            ),
        ));
    }
    Ok(match &snapshot.contents {
        Some(before) => before != &fs::read(path)?,
        None => true,
    })
}

fn backup_install_state(paths: &[&Path]) -> io::Result<Vec<StateBackup>> {
    let mut backups = Vec::new();
    for final_path in paths {
        let backup_path = sibling_state_path(final_path, "backup");
        if backup_path.exists() {
            remove_path(&backup_path)?;
        }
        if final_path.exists() {
            let permissions = fs::metadata(final_path)?.permissions();
            if permissions.readonly() {
                return Err(restore_after(
                    &mut backups,
                    Error::new(
                        ErrorKind::PermissionDenied,
                        format!("install state file {} is read-only", final_path.display()),
                    ),
                ));
            }
            if let Err(error) = fs::rename(final_path, &backup_path) {
                return Err(restore_after(&mut backups, error));
            }
            backups.push(StateBackup {
                final_path: final_path.to_path_buf(),
                backup_path: Some(backup_path),
                permissions: Some(permissions),
            });
        } else {
            backups.push(StateBackup {
                final_path: final_path.to_path_buf(),
                backup_path: None,
                permissions: None,
            });
        }
    }
    Ok(backups)
}

fn restore_state_permissions(backups: &[StateBackup]) -> io::Result<()> {
    for backup in backups {
        if let Some(permissions) = backup.permissions.clone() {
            fs::set_permissions(&backup.final_path, permissions).map_err(|error| {
                Error::new(
                    error.kind(),
                    format!(
                        "failed to restore install state permissions for {}: {error}",
                        backup.final_path.display()
                    ),
                )
            })?;
        }
    }
    Ok(())
}

fn restore_after(backups: &mut [StateBackup], error: io::Error) -> io::Error {
    match restore_install_state(backups) {
        Ok(()) => error,
        Err(restore_error) => Error::new(
            error.kind(),
            format!("{error}; additionally failed to restore install state: {restore_error}"),
        ),
    }
}

fn restore_install_state(backups: &mut [StateBackup]) -> io::Result<()> {
    for backup in backups.iter_mut().rev() {
        if backup.final_path.exists() {
            remove_path(&backup.final_path)?;
        }
        if let Some(backup_path) = backup.backup_path.take() {
            fs::rename(&backup_path, &backup.final_path).map_err(|error| {
                Error::new(
                    error.kind(),
                    format!(
                        "failed to restore install state file {}: {error}",
                        backup.final_path.display()
                    ),
                )
            })?;
        }
    }
    Ok(())
}

fn restore_snapshot_after(
    paths: &[&Path],
    snapshots: &[StateSnapshot],
    error: io::Error,
) -> io::Error {
    match restore_snapshots(paths, snapshots) {
        Ok(()) => error,
        Err(restore_error) => Error::new(
            error.kind(),
            format!("{error}; additionally failed to restore install state: {restore_error}"),
        ),
    }
}

fn restore_snapshots(paths: &[&Path], snapshots: &[StateSnapshot]) -> io::Result<()> {
    for (path, snapshot) in paths.iter().zip(snapshots) {
        if let Ok(metadata) = fs::symlink_metadata(path) {
            if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!(
                        "cannot restore install state over directory {}",
                        path.display()
                    ),
                ));
            }
            remove_path(path)?;
        }
        if let Some(contents) = &snapshot.contents {
            fs::write(path, contents)?;
            if let Some(permissions) = &snapshot.permissions {
                fs::set_permissions(path, permissions.clone())?;
            }
        }
    }
    Ok(())
}

fn merge_generated_packages(hooked: &mut LockFile, generated: &LockFile) {
    for (key, dependency) in generated.get_packages() {
        if hooked.get_dependency(key).is_some() {
            continue;
        }
        let package_name = key
            .rsplit_once('@')
            .map(|(name, _)| name)
            .unwrap_or(key)
            .to_owned();
        hooked.add_dependency_entry(
            key,
            package_name,
            dependency.get_requested(),
            dependency.get_version(),
            dependency.get_relationship(),
            dependency.get_tarball(),
            dependency.get_integrity(),
            dependency.get_shasum(),
            dependency.get_scripts(),
            &dependency.get_dependencies(),
        );
    }
}

fn commit_install_state(backups: Vec<StateBackup>) -> io::Result<()> {
    for mut backup in backups {
        if let Some(backup_path) = backup.backup_path.take() {
            remove_path(&backup_path)?;
        }
    }
    Ok(())
}

fn sibling_state_path(path: &Path, kind: &str) -> PathBuf {
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("install-state");
    parent.join(format!(".{file_name}.rpm-{kind}-{}", unique_suffix()))
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{nanos}", std::process::id())
}

fn remove_path(path: &Path) -> io::Result<()> {
    let file_type = fs::symlink_metadata(path)?.file_type();
    if file_type.is_dir() && !file_type.is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

#[cfg(test)]
mod tests {
    use super::{capture_install_state, install_in, restore_snapshot_after};
    use crate::{
        command::working_process::run::run_script,
        lockfile::{LockFile, Relationship},
        package_manifest::PackageManifest,
        util::test_support::{fixture_path, TempProject},
    };
    use std::{
        collections::BTreeMap,
        ffi::OsString,
        fs, io,
        os::unix::fs::symlink,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
        thread,
        time::Duration,
    };

    #[tokio::test]
    async fn installs_performance_small_fixture_from_deterministic_inputs() {
        let _guard = TestEnvLock::acquire().unwrap();
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let root_before = root_fingerprints(&repo_root).unwrap();
        let fixture_root = fixture_path(&["install-projects", "performance-small"]);
        let project = TempProject::new("performance-small-install").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        let lock_path = project_root.join("rpm.lock");
        let lock = LockFile::load_from_path(&lock_path).unwrap();
        let expected = fs::read_to_string(fixture_root.join("expected/resolved-packages.txt"))
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        assert_eq!(resolved_packages(&lock), expected);
        assert_eq!(
            lock.get_dependency("@rpm-fixture/alpha@1.0.0")
                .map(|dependency| dependency.get_relationship()),
            Some(Relationship::Direct)
        );
        assert_eq!(
            lock.get_dependency("@rpm-fixture/beta@1.0.0")
                .map(|dependency| dependency.get_relationship()),
            Some(Relationship::Direct)
        );
        assert_eq!(
            lock.get_dependency("@rpm-fixture/shared@1.0.0")
                .map(|dependency| dependency.get_relationship()),
            Some(Relationship::Transitive)
        );

        let package = PackageManifest::read_from_path(&package_path).unwrap();
        assert_eq!(package.get_name(), "performance-small");
        assert_eq!(
            sorted_dependencies(package.get_dependencies()),
            vec![
                ("@rpm-fixture/alpha".to_string(), "^1.0.0".to_string()),
                ("@rpm-fixture/beta".to_string(), "^1.0.0".to_string()),
            ]
        );

        let node_modules = project_root.join("node_modules");
        assert!(node_modules
            .join("@rpm-fixture")
            .join("alpha")
            .join("package.json")
            .is_file());
        assert!(node_modules
            .join("@rpm-fixture")
            .join("beta")
            .join("package.json")
            .is_file());
        assert!(node_modules
            .join("@rpm-fixture")
            .join("shared")
            .join("package.json")
            .is_file());
        assert_eq!(
            fs::read_link(
                node_modules
                    .join("@rpm-fixture")
                    .join("alpha")
                    .join("node_modules")
                    .join("@rpm-fixture")
                    .join("shared")
            )
            .unwrap(),
            PathBuf::from("../../../../@rpm-fixture/shared")
        );
        assert_eq!(
            fs::read_link(
                node_modules
                    .join("@rpm-fixture")
                    .join("beta")
                    .join("node_modules")
                    .join("@rpm-fixture")
                    .join("shared")
            )
            .unwrap(),
            PathBuf::from("../../../../@rpm-fixture/shared")
        );

        assert_eq!(
            sorted_cache_entries(&project_root.join(".rpm/.cache")).unwrap(),
            vec![
                "@rpm-fixture-alpha@1.0.0.tgz".to_string(),
                "@rpm-fixture-beta@1.0.0.tgz".to_string(),
                "@rpm-fixture-shared@1.0.0.tgz".to_string(),
            ]
        );
        assert_eq!(root_fingerprints(&repo_root).unwrap(), root_before);
    }

    #[tokio::test]
    async fn read_only_manifest_failure_preserves_existing_node_modules() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "performance-small"]);
        let project = TempProject::new("install-read-only-manifest").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_permissions = fs::metadata(&package_path).unwrap().permissions();
        let mut read_only_permissions = original_permissions.clone();
        read_only_permissions.set_mode(0o444);
        fs::set_permissions(&package_path, read_only_permissions).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();
        fs::set_permissions(&package_path, original_permissions).unwrap();

        assert!(error.to_string().contains("package.json is read-only"));
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    #[tokio::test]
    async fn output_failure_preserves_existing_manifest_lockfile_and_node_modules() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "output-failure-after-resolution"]);
        let project = TempProject::new("output-failure-preserves-state").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let lockfile_path = project
            .copy_fixture(fixture_root.join("rpm.lock"), "rpm.lock")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_package = fs::read(&package_path).unwrap();
        let original_lockfile = fs::read(&lockfile_path).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();

        assert_expected_error(&fixture_root, &error);
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(fs::read(&lockfile_path).unwrap(), original_lockfile);
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    #[tokio::test]
    async fn registry_integrity_failure_preserves_existing_install_state() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "integrity-mismatch"]);
        let project = TempProject::new("registry-integrity-failure").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let lockfile_path = project_root.join("rpm.lock");
        fs::write(
            &lockfile_path,
            "lockfile_version = 1\nname = \"integrity-mismatch\"\nversion = \"0.1.0\"\n",
        )
        .unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_package = fs::read(&package_path).unwrap();
        let original_lockfile = fs::read(&lockfile_path).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();

        assert_expected_error(&fixture_root, &error);
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(fs::read(&lockfile_path).unwrap(), original_lockfile);
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    #[tokio::test]
    async fn lockfile_integrity_failure_preserves_existing_install_state() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "integrity-mismatch"]);
        let project = TempProject::new("lockfile-integrity-failure").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let lockfile_path = project
            .copy_fixture(fixture_root.join("rpm.lock"), "rpm.lock")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_package = fs::read(&package_path).unwrap();
        let original_lockfile = fs::read(&lockfile_path).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();

        assert_expected_error(&fixture_root, &error);
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(fs::read(&lockfile_path).unwrap(), original_lockfile);
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    // Issue #143: prove the install pipeline produces a `node_modules/.bin`
    // link for a resolved package binary and that `rpm run` reaches it through
    // the PATH prepend owned by the run contract. The fixture declares a single
    // dependency whose synthetic tarball carries a string-form `bin` field and
    // the executable target; without the tarball spec, no `.bin` link is
    // produced and `run_script` cannot find the binary.

    #[tokio::test]
    async fn install_creates_bin_link_and_run_script_reaches_it() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "run-project-binary"]);
        let project = TempProject::new("run-project-binary-install").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        // Fingerprint the install output (the project's `node_modules`, lockfile,
        // and cache) instead of the repository root so the non-mutation contract
        // has actual regression coverage: a regression that reinstalled or
        // mutated `project_root` would be caught here, while the repo root is
        // never touched by `run_script` and would mask such a regression.
        let project_before = project_fingerprints(project_root);

        let lock_path = project_root.join("rpm.lock");
        let lock = LockFile::load_from_path(&lock_path).unwrap();
        let expected = fs::read_to_string(fixture_root.join("expected/resolved-packages.txt"))
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        assert_eq!(resolved_packages(&lock), expected);

        let node_modules = project_root.join("node_modules");
        // The resolved package is installed and carries the declared target.
        assert!(node_modules
            .join("@rpm-fixture")
            .join("cli-tool")
            .join("cli.sh")
            .is_file());
        // install generated a `.bin` symlink pointing at the target file.
        // The package is scoped (`@rpm-fixture/cli-tool`) with string-form
        // `bin`, so the binary name drops the scope prefix (linker SPEC).
        let bin_link = node_modules.join(".bin").join("cli-tool");
        assert!(
            bin_link.is_symlink(),
            "expected .bin link for the resolved binary, got {}",
            bin_link.display()
        );
        assert_eq!(
            fs::read_link(&bin_link).unwrap(),
            PathBuf::from("../@rpm-fixture/cli-tool/cli.sh")
        );

        // `rpm run` reaches the installed binary through the PATH prepend
        // without reinstalling or mutating install output.
        let package = PackageManifest::read_from_path(&package_path).unwrap();
        let status = run_script("greet", &package, project_root).unwrap();
        assert_eq!(status, 0);

        // Running the script must not change the install output.
        assert_eq!(project_fingerprints(project_root), project_before);
    }

    #[tokio::test]
    async fn run_script_reports_missing_binary_after_install() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "run-project-binary"]);
        let project = TempProject::new("run-project-binary-missing").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        // A binary the installed packages do not expose must remain a readable
        // non-zero status, not a reinstall or a silent success.
        let script = r#"{"scripts": {"missing": "definitely-not-an-rpm-fixture-binary"}}"#;
        fs::write(&package_path, script).unwrap();
        let package = PackageManifest::read_from_path(&package_path).unwrap();
        let status = run_script("missing", &package, project_root).unwrap();
        assert_ne!(status, 0);
    }

    // Issue #142: lifecycle `scripts` phase. The install pipeline runs the
    // `preinstall` hook between `link` and `write`. A successful hook runs in
    // the resolved package directory; a failing hook fails the `scripts` phase
    // with a labeled error, discards the staged tree, and leaves the previous
    // `node_modules`, `rpm.lock`, and `package.json` unchanged.

    #[tokio::test]
    async fn lifecycle_preinstall_runs_for_resolved_package() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-success"]);
        let project = TempProject::new("lifecycle-preinstall-success").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        // The resolved package's `preinstall` hook wrote a proof file inside
        // its installed package directory during the `scripts` phase.
        let proof = project_root
            .join("node_modules")
            .join("@rpm-fixture")
            .join("lifecycle-preinstall-success")
            .join("preinstall-proof.txt");
        assert_eq!(
            fs::read_to_string(&proof)
                .unwrap_or_else(|error| panic!("preinstall proof should exist: {error}")),
            "preinstall-ran\n"
        );
    }

    #[tokio::test]
    async fn lifecycle_preinstall_runs_for_root_without_dependencies() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-root"]);
        let project = TempProject::new("lifecycle-preinstall-root-only").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        fs::write(
            &package_path,
            r#"{"name":"root-only","version":"0.0.0","scripts":{"preinstall":"echo root-only-ran > root-only-proof.txt"}}"#,
        )
        .unwrap();

        install_in(project_root).await.unwrap();

        assert_eq!(
            fs::read_to_string(project_root.join("root-only-proof.txt")).unwrap(),
            "root-only-ran\n"
        );
    }

    #[tokio::test]
    async fn lifecycle_preinstall_failure_preserves_existing_install_state() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-failure"]);
        let project = TempProject::new("lifecycle-preinstall-failure").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_package = fs::read(&package_path).unwrap();
        let lock_path = project_root.join("rpm.lock");
        fs::write(
            &lock_path,
            "lockfile_version = 1\nname = \"previous\"\nversion = \"0.1.0\"\n",
        )
        .unwrap();
        let original_lock = fs::read(&lock_path).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();

        assert_expected_error(&fixture_root, &error);
        // A failed `scripts` phase must not publish partial install state: the
        // previous `node_modules` and the root manifest stay unchanged.
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(fs::read(&lock_path).unwrap(), original_lock);
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    #[test]
    fn rollback_does_not_follow_hook_created_state_symlinks() {
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-root"]);
        let project = TempProject::new("install-state-symlink-rollback").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let target_path = package_path.with_file_name("outside-target");
        let original_package = fs::read(&package_path).unwrap();
        fs::write(&target_path, "outside-target").unwrap();
        let paths: [&Path; 1] = [&package_path];
        let snapshots = capture_install_state(&paths).unwrap();

        fs::remove_file(&package_path).unwrap();
        symlink(&target_path, &package_path).unwrap();
        let error = io::Error::other("hook failed");
        let restored = restore_snapshot_after(&paths, &snapshots, error);

        assert_eq!(restored.to_string(), "hook failed");
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(fs::read_to_string(&target_path).unwrap(), "outside-target");
    }

    #[tokio::test]
    async fn lifecycle_preinstall_missing_command_fails_scripts_phase() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root =
            fixture_path(&["install-projects", "lifecycle-preinstall-missing-command"]);
        let project = TempProject::new("lifecycle-preinstall-missing-command").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let existing_file = project_root.join("node_modules").join("keep.txt");
        fs::create_dir_all(existing_file.parent().unwrap()).unwrap();
        fs::write(&existing_file, "existing node_modules content").unwrap();
        let original_package = fs::read(&package_path).unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = install_in(project_root).await.unwrap_err();

        assert_expected_error(&fixture_root, &error);
        assert_eq!(fs::read(&package_path).unwrap(), original_package);
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
    }

    #[tokio::test]
    async fn lifecycle_preinstall_wrong_type_does_not_fail_install() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-wrong-type"]);
        let project = TempProject::new("lifecycle-preinstall-wrong-type").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        // A wrong-type `scripts` value is discarded as absent by the manifest
        // deserializer, so the install completes normally.
        install_in(project_root).await.unwrap();

        let node_modules = project_root.join("node_modules");
        assert!(node_modules
            .join("@rpm-fixture")
            .join("lifecycle-preinstall-wrong-type")
            .join("package.json")
            .is_file());
    }

    #[tokio::test]
    async fn lifecycle_preinstall_runs_for_root_manifest() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-root"]);
        let project = TempProject::new("lifecycle-preinstall-root").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        // The root manifest's `preinstall` hook ran with the project root as
        // its working directory.
        assert_eq!(
            fs::read_to_string(project_root.join("root-preinstall-proof.txt")).unwrap(),
            "root-preinstall-ran\n"
        );
    }

    #[tokio::test]
    async fn lifecycle_preinstall_preserves_root_state_mutations() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lifecycle-preinstall-root"]);
        let project = TempProject::new("lifecycle-preinstall-state-mutation").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        fs::write(
            &package_path,
            r##"{"name":"lifecycle-preinstall-root","version":"0.0.0","scripts":{"preinstall":"printf '%s' '{\"name\":\"hook-mutated\",\"version\":\"9.9.9\"}' > package.json && printf '%s\\n' 'lockfile_version = 1' 'name = \"hook-lock\"' 'version = \"9.9.9\"' > rpm.lock"},"dependencies":{"@rpm-fixture/lifecycle-preinstall-root":"1.0.0"}}"##,
        )
        .unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        let package = PackageManifest::read_from_path(&package_path).unwrap();
        assert_eq!(package.get_name(), "hook-mutated");
        let lockfile = fs::read_to_string(project_root.join("rpm.lock")).unwrap();
        assert!(lockfile.contains("name = \"hook-lock\""));
        assert!(lockfile.contains("@rpm-fixture/lifecycle-preinstall-root@1.0.0"));
    }

    #[tokio::test]
    async fn lifecycle_preinstall_failure_restores_permissions_changed_by_hook() {
        let project = TempProject::new("install-state-permissions").unwrap();
        let package_path = project
            .copy_fixture(
                fixture_path(&["install-projects", "lifecycle-preinstall-root"])
                    .join("package.json"),
                "package.json",
            )
            .unwrap();
        fs::write(
            &package_path,
            r#"{"name":"permission-rollback","version":"0.0.0","scripts":{"preinstall":"chmod 0444 package.json"}}"#,
        )
        .unwrap();
        let original = fs::read(&package_path).unwrap();
        let original_permissions = fs::metadata(&package_path).unwrap().permissions();

        let error = install_in(package_path.parent().unwrap())
            .await
            .unwrap_err();

        assert!(error.to_string().contains("read-only"));
        assert_eq!(fs::read(&package_path).unwrap(), original);
        assert_eq!(
            fs::metadata(&package_path).unwrap().permissions(),
            original_permissions
        );
    }

    #[tokio::test]
    async fn install_rebuilds_staging_after_root_lockfile_mutation() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lockfile-reproducible"]);
        let project = TempProject::new("install-root-lockfile-mutation").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        project
            .copy_fixture(fixture_root.join("rpm.lock"), "rpm.lock")
            .unwrap();
        fs::write(
            &package_path,
            r##"{"name":"lockfile-rewrite","version":"0.0.0","scripts":{"preinstall":"printf '%s\\n' 'lockfile_version = 1' 'name = \"lockfile-rewrite\"' 'version = \"0.0.0\"' '' '[\"@rpm-fixture/locked-parent@1.0.0\"]' 'name = \"@rpm-fixture/locked-parent\"' 'requested = \"^1.0.0\"' 'version = \"1.0.0\"' 'relationship = \"direct\"' 'dependencies = []' '' '[\"@rpm-fixture/locked-child@1.0.0\"]' 'name = \"@rpm-fixture/locked-child\"' 'requested = \"^1.0.0\"' 'version = \"1.0.0\"' 'relationship = \"transitive\"' 'dependencies = []' > rpm.lock"},"dependencies":{"@rpm-fixture/locked-parent":"^1.0.0"}}"##,
        )
        .unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        assert!(!project_root
            .join("node_modules/@rpm-fixture/locked-parent/node_modules/@rpm-fixture/locked-child")
            .exists());
    }

    #[tokio::test]
    async fn install_runs_preinstall_from_hydrated_legacy_lockfile_metadata() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "lockfile-reproducible"]);
        let project = TempProject::new("install-legacy-lifecycle").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        project
            .copy_fixture(fixture_root.join("rpm.lock"), "rpm.lock")
            .unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        install_in(project_root).await.unwrap();

        assert_eq!(
            fs::read_to_string(
                project_root
                    .join("node_modules/@rpm-fixture/locked-parent/legacy-preinstall-proof.txt")
            )
            .unwrap(),
            "legacy-preinstall-ran\n"
        );
    }

    fn assert_expected_error(fixture_root: &Path, error: &io::Error) {
        let expected =
            fs::read_to_string(fixture_root.join("expected/error-substrings.txt")).unwrap();
        let actual = error.to_string();

        for substring in expected.lines().filter(|line| !line.is_empty()) {
            assert!(
                actual.contains(substring),
                "expected error to contain {substring:?}, got {actual:?}"
            );
        }
    }

    fn resolved_packages(lock: &LockFile) -> Vec<String> {
        let mut packages = lock
            .get_packages()
            .into_iter()
            .map(|(key, dependency)| format!("{key} requested {}", dependency.get_requested()))
            .collect::<Vec<_>>();
        packages.sort();
        packages
    }

    fn sorted_dependencies(mut dependencies: Vec<(String, String)>) -> Vec<(String, String)> {
        dependencies.sort();
        dependencies
    }

    fn sorted_cache_entries(cache_dir: &Path) -> io::Result<Vec<String>> {
        let mut entries = fs::read_dir(cache_dir)?
            .map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned()))
            .collect::<io::Result<Vec<_>>>()?;
        entries.sort();
        Ok(entries)
    }

    struct TestEnvLock {
        path: PathBuf,
    }

    impl TestEnvLock {
        fn acquire() -> io::Result<Self> {
            let path = std::env::temp_dir().join("rpm-install-test-env-lock");
            loop {
                match fs::create_dir(&path) {
                    Ok(()) => return Ok(Self { path }),
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }

    impl Drop for TestEnvLock {
        fn drop(&mut self) {
            let _ = fs::remove_dir(&self.path);
        }
    }

    struct FixtureInstallEnv {
        previous_fixture_root: Option<OsString>,
    }

    impl FixtureInstallEnv {
        fn new(registry_root: &Path) -> Self {
            let previous_fixture_root = std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT");
            std::env::set_var("RPM_REGISTRY_FIXTURE_ROOT", registry_root);
            Self {
                previous_fixture_root,
            }
        }
    }

    impl Drop for FixtureInstallEnv {
        fn drop(&mut self) {
            match &self.previous_fixture_root {
                Some(value) => std::env::set_var("RPM_REGISTRY_FIXTURE_ROOT", value),
                None => std::env::remove_var("RPM_REGISTRY_FIXTURE_ROOT"),
            }
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    enum PathFingerprint {
        Missing,
        File(Vec<u8>),
        Dir(BTreeMap<String, PathFingerprint>),
    }

    fn root_fingerprints(repo_root: &Path) -> io::Result<BTreeMap<String, PathFingerprint>> {
        let mut fingerprints = BTreeMap::new();
        for path in ["package.json", "rpm.lock", ".rpm", "node_modules"] {
            fingerprints.insert(path.to_string(), fingerprint_path(&repo_root.join(path))?);
        }
        Ok(fingerprints)
    }

    /// Fingerprint the install output of a project: its `rpm.lock`, `.rpm`
    /// cache, and `node_modules` tree. Used to prove a step (such as
    /// `run_script`) does not reinstall or mutate install output. Unlike
    /// `root_fingerprints`, this scopes the snapshot to the project whose
    /// install output is under test, so a regression that mutated the project
    /// would be caught rather than masked by an unrelated root.
    fn project_fingerprints(project_root: &Path) -> BTreeMap<String, PathFingerprint> {
        let mut fingerprints = BTreeMap::new();
        for path in ["rpm.lock", ".rpm", "node_modules"] {
            fingerprints.insert(
                path.to_string(),
                fingerprint_path(&project_root.join(path)).unwrap(),
            );
        }
        fingerprints
    }

    fn fingerprint_path(path: &Path) -> io::Result<PathFingerprint> {
        if !path.exists() {
            return Ok(PathFingerprint::Missing);
        }
        if path.is_file() {
            return fs::read(path).map(PathFingerprint::File);
        }

        let mut entries = BTreeMap::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            entries.insert(
                entry.file_name().to_string_lossy().into_owned(),
                fingerprint_path(&entry.path())?,
            );
        }
        Ok(PathFingerprint::Dir(entries))
    }
}
