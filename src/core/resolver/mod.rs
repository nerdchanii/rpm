use std::collections::{HashMap, VecDeque};

use thiserror::Error;

use crate::core::resolver::semver::SemverError;
use crate::util::parse_library_name;

pub mod semver;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DependencyRequestKind {
    DirectProduction,
    DirectDevelopment,
    Transitive,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DependencyRequest {
    pub package_name: String,
    pub requested: String,
    pub kind: DependencyRequestKind,
}

impl DependencyRequest {
    pub fn new(
        package_name: impl Into<String>,
        requested: impl Into<String>,
        kind: DependencyRequestKind,
    ) -> Self {
        Self {
            package_name: package_name.into(),
            requested: normalize_requested(requested.into()),
            kind,
        }
    }

    pub fn from_spec(
        dependency: impl Into<String>,
        kind: DependencyRequestKind,
    ) -> Result<Self, ResolutionError> {
        let dependency = dependency.into();
        let (package_name, requested) = parse_library_name(dependency.clone());
        if package_name.trim().is_empty() {
            return Err(ResolutionError::InvalidDependencyDeclaration {
                declaration: dependency,
            });
        }
        Ok(Self::new(package_name, requested, kind))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DependencyDeclaration {
    pub package_name: String,
    pub requested: String,
}

impl DependencyDeclaration {
    pub fn new(package_name: impl Into<String>, requested: impl Into<String>) -> Self {
        Self {
            package_name: package_name.into(),
            requested: normalize_requested(requested.into()),
        }
    }

    pub fn from_spec(dependency: impl Into<String>) -> Result<Self, ResolutionError> {
        let dependency = dependency.into();
        let (package_name, requested) = parse_library_name(dependency.clone());
        if package_name.trim().is_empty() {
            return Err(ResolutionError::InvalidDependencyDeclaration {
                declaration: dependency,
            });
        }
        Ok(Self::new(package_name, requested))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRequest {
    pub requested: String,
    pub kind: DependencyRequestKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DependencyEdge {
    pub package_name: String,
    pub requested: String,
    pub resolved_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPackage {
    pub package_name: String,
    pub version: String,
    pub requests: Vec<ResolvedRequest>,
    pub dependencies: Vec<DependencyEdge>,
}

impl ResolvedPackage {
    fn add_request(&mut self, request: ResolvedRequest) {
        if !self.requests.contains(&request) {
            self.requests.push(request);
        }
    }

    fn add_dependency(&mut self, edge: DependencyEdge) {
        if !self.dependencies.contains(&edge) {
            self.dependencies.push(edge);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedDependencyGraph {
    packages: Vec<ResolvedPackage>,
}

impl ResolvedDependencyGraph {
    pub fn packages(&self) -> &[ResolvedPackage] {
        &self.packages
    }

    pub fn package(&self, package_name: &str, version: &str) -> Option<&ResolvedPackage> {
        self.packages
            .iter()
            .find(|package| package.package_name == package_name && package.version == version)
    }
}

pub trait PackageMetadataProvider {
    fn select_version(
        &self,
        package_name: &str,
        requested: &str,
    ) -> Result<String, ResolutionError>;

    fn dependencies_for_version(
        &self,
        package_name: &str,
        version: &str,
    ) -> Result<Vec<DependencyDeclaration>, ResolutionError>;
}

pub trait ResolutionStrategy {
    fn resolve<M: PackageMetadataProvider>(
        &self,
        requests: Vec<DependencyRequest>,
        metadata: &M,
    ) -> Result<ResolvedDependencyGraph, ResolutionError>;
}

#[derive(Debug, Default)]
pub struct FifoResolutionStrategy;

impl FifoResolutionStrategy {
    pub fn new() -> Self {
        Self
    }
}

impl ResolutionStrategy for FifoResolutionStrategy {
    fn resolve<M: PackageMetadataProvider>(
        &self,
        requests: Vec<DependencyRequest>,
        metadata: &M,
    ) -> Result<ResolvedDependencyGraph, ResolutionError> {
        let mut worklist = requests
            .into_iter()
            .map(|request| PendingRequest {
                request,
                requested_by: None,
            })
            .collect::<VecDeque<_>>();
        let mut packages: Vec<ResolvedPackage> = Vec::new();
        let mut package_indexes: HashMap<String, usize> = HashMap::new();

        while let Some(pending) = worklist.pop_front() {
            let version = metadata
                .select_version(&pending.request.package_name, &pending.request.requested)?;
            let package_key = package_key(&pending.request.package_name, &version);

            if let Some(parent_key) = pending.requested_by.as_ref() {
                let parent_index = package_indexes.get(parent_key).copied().ok_or_else(|| {
                    ResolutionError::ParentPackageMissing {
                        package_key: parent_key.clone(),
                    }
                })?;
                packages[parent_index].add_dependency(DependencyEdge {
                    package_name: pending.request.package_name.clone(),
                    requested: pending.request.requested.clone(),
                    resolved_version: version.clone(),
                });
            }

            let request = ResolvedRequest {
                requested: pending.request.requested.clone(),
                kind: pending.request.kind,
            };

            if let Some(package_index) = package_indexes.get(&package_key).copied() {
                packages[package_index].add_request(request);
                continue;
            }

            let package_index = packages.len();
            package_indexes.insert(package_key.clone(), package_index);
            packages.push(ResolvedPackage {
                package_name: pending.request.package_name.clone(),
                version,
                requests: vec![request],
                dependencies: Vec::new(),
            });

            let package = &packages[package_index];
            let dependencies =
                metadata.dependencies_for_version(&package.package_name, &package.version)?;
            for dependency in dependencies {
                worklist.push_back(PendingRequest {
                    request: DependencyRequest::new(
                        dependency.package_name,
                        dependency.requested,
                        DependencyRequestKind::Transitive,
                    ),
                    requested_by: Some(package_key.clone()),
                });
            }
        }

        Ok(ResolvedDependencyGraph { packages })
    }
}

pub fn resolve_dependency_graph<M: PackageMetadataProvider>(
    requests: Vec<DependencyRequest>,
    metadata: &M,
) -> Result<ResolvedDependencyGraph, ResolutionError> {
    FifoResolutionStrategy::new().resolve(requests, metadata)
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ResolutionError {
    #[error("missing package metadata for {package_name}")]
    MissingMetadata { package_name: String },
    #[error("{package_name} requested {requested} error {source}")]
    VersionSelection {
        package_name: String,
        requested: String,
        source: SemverError,
    },
    #[error("invalid dependency declaration {declaration}")]
    InvalidDependencyDeclaration { declaration: String },
    #[error("resolved parent package {package_key} is missing from graph")]
    ParentPackageMissing { package_key: String },
}

impl ResolutionError {
    pub fn version_selection(
        package_name: impl Into<String>,
        requested: impl Into<String>,
        source: SemverError,
    ) -> Self {
        Self::VersionSelection {
            package_name: package_name.into(),
            requested: requested.into(),
            source,
        }
    }
}

#[derive(Debug, Clone)]
struct PendingRequest {
    request: DependencyRequest,
    requested_by: Option<String>,
}

fn normalize_requested(requested: String) -> String {
    if requested.is_empty() {
        "latest".to_string()
    } else {
        requested
    }
}

fn package_key(package_name: &str, version: &str) -> String {
    format!("{package_name}@{version}")
}

#[cfg(test)]
mod tests {
    use super::{
        resolve_dependency_graph, DependencyDeclaration, DependencyRequest, DependencyRequestKind,
        PackageMetadataProvider, ResolutionError,
    };
    use crate::registry::Registry;
    use crate::util::test_support::fixture_path;
    use std::cell::Cell;
    use std::collections::HashMap;
    use std::fs;
    use std::path::Path;

    struct FixtureMetadataProvider {
        registries: HashMap<String, Registry>,
    }

    impl FixtureMetadataProvider {
        fn from_fixture_root(root: &Path) -> Self {
            let mut registries = HashMap::new();
            for entry in fs::read_dir(root).expect("registry fixture root should exist") {
                let entry = entry.expect("registry fixture entry should be readable");
                let path = entry.path();
                if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                    continue;
                }

                let fixture = fs::read_to_string(&path).expect("registry fixture should be read");
                let registry: Registry = serde_json::from_str(&fixture).unwrap_or_else(|error| {
                    panic!("{} did not deserialize: {error}", path.display())
                });
                registries.insert(registry.name.clone(), registry);
            }
            Self { registries }
        }
    }

    impl PackageMetadataProvider for FixtureMetadataProvider {
        fn select_version(
            &self,
            package_name: &str,
            requested: &str,
        ) -> Result<String, ResolutionError> {
            let registry = self.registries.get(package_name).ok_or_else(|| {
                ResolutionError::MissingMetadata {
                    package_name: package_name.to_string(),
                }
            })?;
            registry.select_version(requested).map_err(|source| {
                ResolutionError::version_selection(package_name, requested, source)
            })
        }

        fn dependencies_for_version(
            &self,
            package_name: &str,
            version: &str,
        ) -> Result<Vec<DependencyDeclaration>, ResolutionError> {
            let registry = self.registries.get(package_name).ok_or_else(|| {
                ResolutionError::MissingMetadata {
                    package_name: package_name.to_string(),
                }
            })?;

            registry
                .get_dependencies_for_version(version)
                .into_iter()
                .map(DependencyDeclaration::from_spec)
                .collect()
        }
    }

    struct FailingSelectionProvider {
        dependency_reads: Cell<usize>,
    }

    impl PackageMetadataProvider for FailingSelectionProvider {
        fn select_version(
            &self,
            package_name: &str,
            requested: &str,
        ) -> Result<String, ResolutionError> {
            Err(ResolutionError::version_selection(
                package_name,
                requested,
                crate::core::resolver::semver::SemverError::UnsatisfiedRange {
                    range: requested.to_string(),
                },
            ))
        }

        fn dependencies_for_version(
            &self,
            _package_name: &str,
            _version: &str,
        ) -> Result<Vec<DependencyDeclaration>, ResolutionError> {
            self.dependency_reads.set(self.dependency_reads.get() + 1);
            Ok(Vec::new())
        }
    }

    #[test]
    fn resolves_shared_transitive_graph_from_offline_registry_metadata() {
        let root = fixture_path(&["registry", "shared-transitive", "metadata"]);
        let provider = FixtureMetadataProvider::from_fixture_root(&root);

        let graph = resolve_dependency_graph(
            vec![
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
            ],
            &provider,
        )
        .expect("shared transitive graph should resolve");

        let expected = fs::read_to_string(fixture_path(&[
            "registry",
            "shared-transitive",
            "expected",
            "resolved-packages.txt",
        ]))
        .expect("expected resolved package list should be readable");
        let resolved = graph
            .packages()
            .iter()
            .map(|package| {
                format!(
                    "{}@{} requested {}",
                    package.package_name, package.version, package.requests[0].requested
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        assert_eq!(format!("{resolved}\n"), expected);
        assert_eq!(graph.packages().len(), 3);

        let alpha = graph.package("@rpm-fixture/alpha", "1.0.0").unwrap();
        assert_eq!(
            alpha.requests[0].kind,
            DependencyRequestKind::DirectProduction
        );
        assert_eq!(alpha.dependencies.len(), 1);
        assert_eq!(alpha.dependencies[0].package_name, "@rpm-fixture/shared");
        assert_eq!(alpha.dependencies[0].requested, "^1.0.0");
        assert_eq!(alpha.dependencies[0].resolved_version, "1.0.0");

        let beta = graph.package("@rpm-fixture/beta", "1.0.0").unwrap();
        assert_eq!(
            beta.requests[0].kind,
            DependencyRequestKind::DirectDevelopment
        );
        assert_eq!(beta.dependencies.len(), 1);
        assert_eq!(beta.dependencies[0].package_name, "@rpm-fixture/shared");

        let shared = graph.package("@rpm-fixture/shared", "1.0.0").unwrap();
        assert_eq!(shared.requests.len(), 1);
        assert_eq!(shared.requests[0].kind, DependencyRequestKind::Transitive);
        assert!(shared.dependencies.is_empty());
    }

    #[test]
    fn failed_version_selection_stops_before_reading_dependency_metadata() {
        let provider = FailingSelectionProvider {
            dependency_reads: Cell::new(0),
        };

        let error = resolve_dependency_graph(
            vec![DependencyRequest::new(
                "@rpm-fixture/missing",
                ">=9.0.0",
                DependencyRequestKind::DirectProduction,
            )],
            &provider,
        )
        .expect_err("unsatisfied direct request should fail resolution");

        assert!(matches!(error, ResolutionError::VersionSelection { .. }));
        assert_eq!(provider.dependency_reads.get(), 0);
    }
}
