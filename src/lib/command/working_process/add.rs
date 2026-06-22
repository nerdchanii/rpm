use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::Future,
    io::{Error, ErrorKind, Write},
    path::Path,
};

use tokio::time::sleep;

use crate::{
    api,
    core::resolver::{
        resolve_dependency_graph, DependencyDeclaration, DependencyRequest, DependencyRequestKind,
        PackageMetadataProvider, ResolutionError, ResolvedPackage,
    },
    lockfile::{LockFile, Relationship},
    package_manifest::PackageManifest,
    registry::Registry,
};

#[derive(Clone)]
struct LockedInstallPackage {
    key: String,
    package_name: String,
    requested: String,
    version: String,
    relationship: Relationship,
    tarball: Option<String>,
    integrity: Option<String>,
    shasum: Option<String>,
    dependencies: Vec<String>,
}

pub async fn add(
    pkg: &mut PackageManifest,
    lockfile: &mut LockFile,
    libs: Vec<String>,
    dev: bool,
    write_manifest: bool,
) -> std::io::Result<()> {
    add_with_cache_dir(
        pkg,
        lockfile,
        libs,
        dev,
        write_manifest,
        Path::new("./.rpm/.cache"),
    )
    .await
}

pub(crate) async fn add_with_cache_dir(
    pkg: &mut PackageManifest,
    lockfile: &mut LockFile,
    libs: Vec<String>,
    dev: bool,
    write_manifest: bool,
    cache_dir: &Path,
) -> std::io::Result<()> {
    let request_kind = direct_request_kind(dev);
    let requests = libs
        .into_iter()
        .map(|dependency| DependencyRequest::from_spec(dependency, request_kind))
        .collect::<Result<Vec<_>, _>>()
        .map_err(resolution_error_to_io)?;
    let mut metadata = InstallMetadata::from_lockfile(lockfile);

    populate_metadata(&mut metadata, &requests, |package_name| async move {
        api::get_registry(&package_name, "").await
    })
    .await?;
    let graph = resolve_dependency_graph(requests, &metadata).map_err(resolution_error_to_io)?;

    lockfile.set_project_metadata(pkg.get_name(), pkg.get_version());
    apply_resolved_graph(
        pkg,
        lockfile,
        graph.packages(),
        &metadata,
        write_manifest,
        cache_dir,
    )
    .await
}

async fn populate_metadata<F, Fut>(
    metadata: &mut InstallMetadata,
    requests: &[DependencyRequest],
    mut fetch_registry: F,
) -> std::io::Result<()>
where
    F: FnMut(String) -> Fut,
    Fut: Future<Output = std::io::Result<Registry>>,
{
    let mut visited = HashSet::new();
    let mut worklist = requests.iter().cloned().collect::<VecDeque<_>>();

    while let Some(request) = worklist.pop_front() {
        let package_name = request.package_name.clone();
        if !metadata.has_locked_request(&package_name, &request.requested)
            && !metadata.has_registry(&package_name)
        {
            let registry = fetch_registry(package_name.clone())
                .await
                .map_err(|error| phase_error("fetch", error))?;
            metadata.insert_registry(package_name.clone(), registry);
        }

        let version = metadata
            .select_version(&package_name, &request.requested)
            .map_err(resolution_error_to_io)?;
        let package_key = format!("{package_name}@{version}");
        if !visited.insert(package_key) {
            continue;
        }

        let dependencies = metadata
            .dependencies_for_version(&package_name, &version)
            .map_err(resolution_error_to_io)?;
        for dependency in dependencies {
            worklist.push_back(DependencyRequest::new(
                dependency.package_name,
                dependency.requested,
                DependencyRequestKind::Transitive,
            ));
        }
    }

    Ok(())
}

async fn apply_resolved_graph(
    pkg: &mut PackageManifest,
    lockfile: &mut LockFile,
    packages: &[ResolvedPackage],
    metadata: &InstallMetadata,
    write_manifest: bool,
    cache_dir: &Path,
) -> std::io::Result<()> {
    for package in packages {
        print!("installing {}@{}...", package.package_name, package.version);
        std::io::stdout().flush()?;
        sleep(std::time::Duration::from_millis(1)).await;
        print!("\r\x1b[K");

        let requested = requested_for_lockfile(package, metadata);
        let relationship = relationship_for_package(package);
        if let Some(locked_package) = metadata.locked_package_for_resolved(package) {
            if let Some(tarball) = &locked_package.tarball {
                Registry::download_tarball_url_to_dir(&locked_package.key, tarball, cache_dir)
                    .await
                    .map_err(|error| phase_error("fetch", error))?;
            }
            lockfile.add_dependency_entry(
                &locked_package.key,
                locked_package.package_name.clone(),
                requested.clone(),
                locked_package.version.clone(),
                relationship,
                locked_package.tarball.clone(),
                locked_package.integrity.clone(),
                locked_package.shasum.clone(),
                &locked_package.dependencies,
            );
        } else {
            let key = format!("{}@{}", package.package_name, package.version);
            let registry = metadata.registry_io(&package.package_name)?;
            registry
                .download_tarball_to_dir(&key, &package.version, cache_dir)
                .await
                .map_err(|error| phase_error("fetch", error))?;

            let dependencies = package
                .dependencies
                .iter()
                .map(|dependency| format!("{}@{}", dependency.package_name, dependency.requested))
                .collect::<Vec<_>>();
            let dist = registry.get_dist_for_version(&package.version);

            lockfile.add_dependency_entry(
                &key,
                package.package_name.clone(),
                requested.clone(),
                package.version.clone(),
                relationship,
                dist.map(|dist| dist.tarball.clone()),
                dist.and_then(|dist| dist.integrity.clone()),
                dist.map(|dist| dist.shasum.clone()),
                &dependencies,
            );
        }

        if write_manifest {
            maybe_update_manifest(pkg, package, &requested);
        }
    }

    Ok(())
}

fn maybe_update_manifest(pkg: &mut PackageManifest, package: &ResolvedPackage, requested: &str) {
    let manifest_version = manifest_version_from_requested(requested, &package.version);
    match direct_request_kind_for_package(package) {
        Some(DependencyRequestKind::DirectProduction) => {
            pkg.add_dependency(package.package_name.clone(), manifest_version)
        }
        Some(DependencyRequestKind::DirectDevelopment) => {
            pkg.add_dev_dependency(package.package_name.clone(), manifest_version)
        }
        _ => {}
    }
}

fn direct_request_kind(dev: bool) -> DependencyRequestKind {
    if dev {
        DependencyRequestKind::DirectDevelopment
    } else {
        DependencyRequestKind::DirectProduction
    }
}

fn direct_request_kind_for_package(package: &ResolvedPackage) -> Option<DependencyRequestKind> {
    direct_request_for_package(package).map(|request| request.kind)
}

fn direct_request_for_package(
    package: &ResolvedPackage,
) -> Option<&crate::core::resolver::ResolvedRequest> {
    package
        .requests
        .iter()
        .find(|request| matches!(request.kind, DependencyRequestKind::DirectProduction))
        .or_else(|| {
            package
                .requests
                .iter()
                .find(|request| matches!(request.kind, DependencyRequestKind::DirectDevelopment))
        })
}

fn requested_for_lockfile(package: &ResolvedPackage, metadata: &InstallMetadata) -> String {
    if let Some(request) = direct_request_for_package(package) {
        if matches!(request.kind, DependencyRequestKind::DirectDevelopment) {
            if let Some(locked_requested) = locked_direct_request(package, metadata) {
                return locked_requested;
            }
        }

        return request.requested.clone();
    }

    package
        .requests
        .first()
        .map(|request| request.requested.clone())
        .unwrap_or_else(|| package.version.clone())
}

fn locked_direct_request(package: &ResolvedPackage, metadata: &InstallMetadata) -> Option<String> {
    metadata
        .locked_package_for_resolved(package)
        .filter(|locked| matches!(locked.relationship, Relationship::Direct))
        .map(|locked| locked.requested.clone())
}

fn relationship_for_package(package: &ResolvedPackage) -> Relationship {
    match direct_request_kind_for_package(package) {
        Some(DependencyRequestKind::DirectProduction) => Relationship::Direct,
        Some(DependencyRequestKind::DirectDevelopment) => Relationship::Dev,
        _ => Relationship::Transitive,
    }
}

fn resolution_error_to_io(error: ResolutionError) -> std::io::Error {
    phase_error(
        "resolve",
        Error::new(ErrorKind::InvalidData, error.to_string()),
    )
}

fn phase_error(phase: &str, error: std::io::Error) -> std::io::Error {
    Error::new(error.kind(), format!("{phase} failed: {error}"))
}

fn manifest_version_from_requested(requested: &str, resolved: &str) -> String {
    if requested == "latest" {
        resolved.to_string()
    } else {
        requested.to_string()
    }
}

#[derive(Default)]
struct InstallMetadata {
    registries: HashMap<String, Registry>,
    locked_by_request: HashMap<(String, String), LockedInstallPackage>,
    locked_by_version: HashMap<(String, String), LockedInstallPackage>,
}

impl InstallMetadata {
    fn from_lockfile(lockfile: &LockFile) -> Self {
        let mut metadata = Self::default();

        for (key, dependency) in lockfile.get_packages() {
            let package_name = package_name_from_lock_key(key);
            let locked_package = LockedInstallPackage {
                key: key.clone(),
                package_name: package_name.clone(),
                requested: dependency.get_requested(),
                version: dependency.get_version(),
                relationship: dependency.get_relationship(),
                tarball: dependency.get_tarball(),
                integrity: dependency.get_integrity(),
                shasum: dependency.get_shasum(),
                dependencies: dependency.get_dependencies(),
            };
            metadata.locked_by_request.insert(
                (package_name.clone(), locked_package.requested.clone()),
                locked_package.clone(),
            );
            metadata.locked_by_version.insert(
                (package_name, locked_package.version.clone()),
                locked_package,
            );
        }

        metadata
    }

    fn insert_registry(&mut self, package_name: String, registry: Registry) {
        self.registries.insert(package_name, registry);
    }

    fn has_registry(&self, package_name: &str) -> bool {
        self.registries.contains_key(package_name)
    }

    fn has_locked_request(&self, package_name: &str, requested: &str) -> bool {
        self.locked_by_request
            .contains_key(&(package_name.to_string(), requested.to_string()))
    }

    fn locked_package_for_request(
        &self,
        package_name: &str,
        requested: &str,
    ) -> Option<&LockedInstallPackage> {
        self.locked_by_request
            .get(&(package_name.to_string(), requested.to_string()))
    }

    fn locked_package_for_version(
        &self,
        package_name: &str,
        version: &str,
    ) -> Option<&LockedInstallPackage> {
        self.locked_by_version
            .get(&(package_name.to_string(), version.to_string()))
    }

    fn locked_package_for_resolved(
        &self,
        package: &ResolvedPackage,
    ) -> Option<&LockedInstallPackage> {
        package
            .requests
            .iter()
            .find_map(|request| {
                self.locked_package_for_request(&package.package_name, &request.requested)
            })
            .or_else(|| self.locked_package_for_version(&package.package_name, &package.version))
    }

    fn registry(&self, package_name: &str) -> Result<&Registry, ResolutionError> {
        self.registries
            .get(package_name)
            .ok_or_else(|| ResolutionError::MissingMetadata {
                package_name: package_name.to_string(),
            })
    }

    fn registry_io(&self, package_name: &str) -> std::io::Result<&Registry> {
        self.registry(package_name).map_err(resolution_error_to_io)
    }
}

impl PackageMetadataProvider for InstallMetadata {
    fn select_version(
        &self,
        package_name: &str,
        requested: &str,
    ) -> Result<String, ResolutionError> {
        if let Some(locked_package) = self.locked_package_for_request(package_name, requested) {
            return Ok(locked_package.version.clone());
        }

        let registry = self.registry(package_name)?;
        registry
            .select_version(requested)
            .map_err(|source| ResolutionError::version_selection(package_name, requested, source))
    }

    fn dependencies_for_version(
        &self,
        package_name: &str,
        version: &str,
    ) -> Result<Vec<DependencyDeclaration>, ResolutionError> {
        if let Some(locked_package) = self.locked_package_for_version(package_name, version) {
            return locked_package
                .dependencies
                .iter()
                .cloned()
                .map(DependencyDeclaration::from_spec)
                .collect();
        }

        let registry = self.registry(package_name)?;
        registry
            .get_dependencies_for_version(version)
            .into_iter()
            .map(DependencyDeclaration::from_spec)
            .collect()
    }
}

fn package_name_from_lock_key(key: &str) -> String {
    match key.rsplit_once('@') {
        Some((name, _)) if !name.is_empty() => name.to_string(),
        _ => key.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        add_with_cache_dir, direct_request_kind, manifest_version_from_requested,
        populate_metadata, relationship_for_package, requested_for_lockfile,
        resolution_error_to_io, InstallMetadata,
    };
    use crate::{
        core::resolver::{
            resolve_dependency_graph, DependencyRequest, DependencyRequestKind, ResolutionError,
            ResolvedPackage, ResolvedRequest,
        },
        lockfile::{LockFile, Relationship},
        package_manifest::PackageManifest,
        registry::Registry,
        util::test_support::{fixture_path, TempProject},
    };
    use std::{
        cell::RefCell,
        collections::HashMap,
        ffi::OsString,
        fs, io,
        path::{Path, PathBuf},
        rc::Rc,
        thread,
        time::Duration,
    };

    fn registry_fixture_file_name(package_name: &str) -> String {
        format!("{}.json", package_name.replace('/', "__"))
    }

    fn load_registry_fixture(root: &Path, package_name: &str) -> Registry {
        let path = root.join(registry_fixture_file_name(package_name));
        let fixture = fs::read_to_string(&path).unwrap_or_else(|error| {
            panic!(
                "failed to read registry fixture {}: {error}",
                path.display()
            )
        });
        serde_json::from_str(&fixture)
            .unwrap_or_else(|error| panic!("{} did not deserialize: {error}", path.display()))
    }

    #[test]
    fn resolution_errors_are_labeled_with_resolve_phase() {
        let error = resolution_error_to_io(ResolutionError::MissingMetadata {
            package_name: "@rpm-fixture/missing".to_string(),
        });

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("resolve failed"));
        assert!(error
            .to_string()
            .contains("missing package metadata for @rpm-fixture/missing"));
    }

    #[tokio::test]
    async fn cache_download_errors_are_labeled_with_fetch_phase() {
        let _guard = TestEnvLock::acquire().unwrap();
        let fixture_root = fixture_path(&["install-projects", "performance-small"]);
        let project = TempProject::new("add-fetch-phase").unwrap();
        let package_path = project
            .copy_fixture(fixture_root.join("package.json"), "package.json")
            .unwrap();
        let project_root = package_path.parent().unwrap();
        let mut package_manifest = PackageManifest::read_from_path(&package_path).unwrap();
        let mut lockfile = LockFile::load_from_path(project_root.join("rpm.lock")).unwrap();
        let libs = package_manifest
            .get_dependencies()
            .into_iter()
            .map(|(library_name, version)| format!("{library_name}@{version}"))
            .collect::<Vec<_>>();
        let cache_path = project_root.join(".rpm").join(".cache");
        fs::create_dir_all(cache_path.parent().unwrap()).unwrap();
        fs::write(&cache_path, "not a directory").unwrap();

        let _env = FixtureInstallEnv::new(&fixture_root.join("registry"));
        let error = add_with_cache_dir(
            &mut package_manifest,
            &mut lockfile,
            libs,
            false,
            false,
            &cache_path,
        )
        .await
        .unwrap_err();

        assert!(error.to_string().contains("fetch failed"));
        assert!(error.to_string().contains("failed to open cached tarball"));
        assert!(error.to_string().contains(".rpm/.cache"));
    }

    #[tokio::test]
    async fn preload_discovers_shared_transitive_metadata_before_resolution() {
        let root = fixture_path(&["registry", "shared-transitive", "metadata"]);
        let requests = vec![
            DependencyRequest::new(
                "@rpm-fixture/alpha",
                "^1.0.0",
                DependencyRequestKind::DirectProduction,
            ),
            DependencyRequest::new(
                "@rpm-fixture/beta",
                "^1.0.0",
                DependencyRequestKind::DirectDevelopment,
            ),
        ];
        let fetches = Rc::new(RefCell::new(HashMap::<String, usize>::new()));
        let fetches_for_loader = Rc::clone(&fetches);
        let mut metadata = InstallMetadata::default();

        populate_metadata(&mut metadata, &requests, |package_name| {
            let root = root.clone();
            let package_name = package_name.to_string();
            let fetches = Rc::clone(&fetches_for_loader);
            async move {
                let count = fetches.borrow().get(&package_name).copied().unwrap_or(0) + 1;
                fetches.borrow_mut().insert(package_name.clone(), count);
                Ok(load_registry_fixture(&root, &package_name))
            }
        })
        .await
        .expect("metadata preload should succeed");

        let graph = resolve_dependency_graph(requests, &metadata).expect("graph should resolve");

        assert_eq!(graph.packages().len(), 3);
        assert_eq!(fetches.borrow().get("@rpm-fixture/alpha"), Some(&1));
        assert_eq!(fetches.borrow().get("@rpm-fixture/beta"), Some(&1));
        assert_eq!(fetches.borrow().get("@rpm-fixture/shared"), Some(&1));
    }

    #[tokio::test]
    async fn preload_prefers_locked_versions_and_dependencies_when_present() {
        let fixture_root = fixture_path(&["install-projects", "lockfile-reproducible"]);
        let registry_root = fixture_root.join("registry");
        let lockfile = LockFile::load_from_path(fixture_root.join("rpm.lock")).unwrap();
        let requests = vec![DependencyRequest::new(
            "@rpm-fixture/locked-parent",
            "^1.0.0",
            DependencyRequestKind::DirectProduction,
        )];
        let mut metadata = InstallMetadata::from_lockfile(&lockfile);

        populate_metadata(&mut metadata, &requests, |package_name| {
            let registry_root = registry_root.clone();
            let package_name = package_name.to_string();
            async move { Ok(load_registry_fixture(&registry_root, &package_name)) }
        })
        .await
        .expect("locked fixture metadata should preload");

        let graph = resolve_dependency_graph(requests, &metadata).expect("graph should resolve");
        let mut resolved = graph
            .packages()
            .iter()
            .map(|package| {
                format!(
                    "{}@{} requested {}",
                    package.package_name,
                    package.version,
                    requested_for_lockfile(package, &metadata)
                )
            })
            .collect::<Vec<_>>();
        resolved.sort();
        let mut expected = fs::read_to_string(fixture_root.join("expected/resolved-packages.txt"))
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect::<Vec<_>>();
        expected.sort();

        assert_eq!(resolved, expected);
    }

    #[test]
    fn relationship_prefers_direct_requests_over_transitive() {
        let package = ResolvedPackage {
            package_name: "shared".to_string(),
            version: "1.0.0".to_string(),
            requests: vec![
                ResolvedRequest {
                    requested: "1.0.0".to_string(),
                    kind: DependencyRequestKind::Transitive,
                },
                ResolvedRequest {
                    requested: "^1.0.0".to_string(),
                    kind: DependencyRequestKind::DirectDevelopment,
                },
            ],
            dependencies: Vec::new(),
        };

        assert_eq!(relationship_for_package(&package), Relationship::Dev);
        assert_eq!(
            requested_for_lockfile(&package, &InstallMetadata::default()),
            "^1.0.0".to_string()
        );
    }

    #[test]
    fn requested_for_lockfile_preserves_existing_prod_request_on_later_dev_pass() {
        let mut lockfile = LockFile::load_from_path(fixture_path(&[
            "install-projects",
            "lockfile-reproducible",
            "rpm.lock",
        ]))
        .unwrap();
        lockfile.add_dependency_entry(
            &"shared@1.0.0".to_string(),
            "shared".to_string(),
            "^1.0.0".to_string(),
            "1.0.0".to_string(),
            Relationship::Direct,
            None,
            None,
            None,
            &[],
        );
        let metadata = InstallMetadata::from_lockfile(&lockfile);
        let package = ResolvedPackage {
            package_name: "shared".to_string(),
            version: "1.0.0".to_string(),
            requests: vec![ResolvedRequest {
                requested: "~1.0.0".to_string(),
                kind: DependencyRequestKind::DirectDevelopment,
            }],
            dependencies: Vec::new(),
        };

        assert_eq!(relationship_for_package(&package), Relationship::Dev);
        let requested = requested_for_lockfile(&package, &metadata);
        assert_eq!(requested, "^1.0.0".to_string());

        lockfile.add_dependency_entry(
            &"shared@1.0.0".to_string(),
            "shared".to_string(),
            requested,
            "1.0.0".to_string(),
            relationship_for_package(&package),
            None,
            None,
            None,
            &[],
        );
        assert_eq!(
            lockfile
                .get_dependency_for_request("shared", "^1.0.0")
                .map(|(_, dependency)| dependency.get_relationship()),
            Some(Relationship::Direct)
        );
        assert_eq!(
            lockfile
                .get_dependency("shared@1.0.0")
                .map(|dependency| dependency.get_requested()),
            Some("^1.0.0".to_string())
        );
    }

    #[test]
    fn add_uses_existing_lockfile_records_before_registry_selection() {
        let fixture_root = fixture_path(&["install-projects", "lockfile-reproducible"]);
        let mut package_manifest =
            PackageManifest::read_from_path(fixture_root.join("package.json")).unwrap();
        let mut lockfile =
            LockFile::load_from_path(fixture_root.join("rpm-without-tarballs.lock")).unwrap();
        let libs = package_manifest
            .get_dependencies()
            .into_iter()
            .map(|(library_name, version)| format!("{library_name}@{version}"))
            .collect::<Vec<_>>();

        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(super::add(
                &mut package_manifest,
                &mut lockfile,
                libs,
                false,
                false,
            ))
            .unwrap();

        let parent = lockfile
            .get_dependency_for_request("@rpm-fixture/locked-parent", "^1.0.0")
            .expect("locked parent should remain available after add");
        assert_eq!(parent.0, "@rpm-fixture/locked-parent@1.0.0");
        assert_eq!(parent.1.get_version(), "1.0.0");
        assert_eq!(
            parent.1.get_dependencies(),
            vec!["@rpm-fixture/locked-child@^1.0.0"]
        );

        let child = lockfile
            .get_dependency_for_request("@rpm-fixture/locked-child", "^1.0.0")
            .expect("locked child should remain available after add");
        assert_eq!(child.0, "@rpm-fixture/locked-child@1.0.0");
        assert_eq!(child.1.get_version(), "1.0.0");
        assert!(child.1.get_dependencies().is_empty());
    }

    #[test]
    fn manifest_version_preserves_requested_range_for_direct_adds() {
        assert_eq!(
            direct_request_kind(false),
            DependencyRequestKind::DirectProduction
        );
        assert_eq!(
            direct_request_kind(true),
            DependencyRequestKind::DirectDevelopment
        );
        assert_eq!(manifest_version_from_requested("^1.2.0", "1.4.0"), "^1.2.0");
        assert_eq!(manifest_version_from_requested("latest", "1.4.0"), "1.4.0");
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
}
