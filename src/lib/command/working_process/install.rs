use crate::{
    command::working_process::add_with_cache_dir, lockfile::LockFile, node_linker::NodeModules,
    package_manifest::PackageManifest,
};
use std::path::Path;

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

    lockfile.save_to_path(&lockfile_path)?;
    package_manifest.save_to_path(&package_path)?;
    if !lockfile.get_packages().is_empty() {
        NodeModules::init_from_paths(&node_modules_path, &lockfile_path, &cache_dir)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::install_in;
    use crate::{
        lockfile::{LockFile, Relationship},
        package_manifest::PackageManifest,
        util::test_support::{fixture_path, TempProject},
    };
    use std::{
        collections::BTreeMap,
        ffi::OsString,
        fs, io,
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
    async fn install_failure_preserves_existing_node_modules() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "performance-small"]);
        let project = TempProject::new("install-failure-preserves-node-modules").unwrap();
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

        assert!(error
            .to_string()
            .contains("failed to open package manifest"));
        assert_eq!(
            fs::read_to_string(&existing_file).unwrap(),
            "existing node_modules content"
        );
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
