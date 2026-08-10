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
        reject_npm_alias(&dependency)?;
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
        reject_npm_alias(&dependency)?;
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
    #[error(
        "npm alias dependency declarations are not supported: {package_key} maps to alias {alias_target}"
    )]
    NpmAliasNotSupported {
        package_key: String,
        alias_target: String,
    },
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

/// Reject npm alias dependency declarations (issue #125).
///
/// An npm alias is a dependency map value whose range text begins with the
/// `npm:` scheme, matched ASCII case-insensitively (for example
/// `"foo": "npm:bar@1.2.3"` or `"foo": "NPM:bar@1.2.3"`). RPM does not resolve
/// aliases today, so it must reject them as input errors at the declaration
/// boundary — before any network fetch, lockfile write, or install side effect
/// — instead of silently misinterpreting `"foo@npm:bar@1.2.3"` as a lookup for
/// a nonexistent package. The case-insensitive scheme match mirrors npm's own
/// `npm-package-arg`, which tests `spec.toLowerCase().startsWith('npm:')`.
///
/// Detection runs on the combined `name@range` declaration *before*
/// `parse_library_name` splits it. `parse_library_name` splits on the *last*
/// `@`, so for `"foo@npm:bar@1.2.3"` it would yield `foo@npm:bar` / `1.2.3`
/// and hide the alias prefix in the package name. A well-formed non-alias
/// declaration — either `name@range` or `@scope/name@range` — can never
/// contain the literal `@npm:`, because `npm:` is not a valid version-range
/// prefix, so finding `@npm:` in the combined declaration identifies an alias
/// unambiguously without over-matching a range that merely contains `npm:` at
/// a non-prefix position. `package_key` is the original combined declaration
/// and names the offending package; `alias_target` is the alias range text.
fn reject_npm_alias(dependency: &str) -> Result<(), ResolutionError> {
    if let Some(alias_start) = find_alias_marker(dependency) {
        let alias_target = dependency[alias_start + 1..].to_string();
        return Err(ResolutionError::NpmAliasNotSupported {
            package_key: dependency.to_string(),
            alias_target,
        });
    }
    Ok(())
}

/// The `@npm:` marker that identifies an alias in an assembled declaration.
const NPM_ALIAS_MARKER: &str = "@npm:";

/// Find the first `@npm:` marker in `dependency`, matching ASCII
/// case-insensitively so `@NPM:`/`@Npm:` aliases are detected too. Returns the
/// byte offset of the leading `@` of the marker, mirroring `str::find`.
fn find_alias_marker(dependency: &str) -> Option<usize> {
    dependency
        .as_bytes()
        .windows(NPM_ALIAS_MARKER.len())
        .position(|window| window.eq_ignore_ascii_case(NPM_ALIAS_MARKER.as_bytes()))
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
    fn peer_dependency_metadata_is_preserved_without_enqueue_or_install_failure() {
        let root = fixture_path(&["registry", "peer-preserve", "metadata"]);
        let provider = FixtureMetadataProvider::from_fixture_root(&root);

        // Request only the peer consumer. Its only edge is a peerDependencies
        // entry; the peer target is never requested directly.
        let graph = resolve_dependency_graph(
            vec![DependencyRequest::new(
                "@rpm-fixture/peer-consumer",
                "^1.0.0",
                DependencyRequestKind::DirectProduction,
            )],
            &provider,
        )
        .expect(
            "unmet peer requirement must not fail resolution under the non-peer-aware strategy",
        );

        let expected = fs::read_to_string(fixture_path(&[
            "registry",
            "peer-preserve",
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

        // The peer target must NOT be enqueued as an ordinary dependency: the
        // graph contains only the consumer.
        assert_eq!(graph.packages().len(), 1);
        let consumer = graph
            .package("@rpm-fixture/peer-consumer", "1.0.0")
            .expect("peer consumer resolves to a graph node");
        assert!(
            consumer.dependencies.is_empty(),
            "peerDependencies must not become ordinary dependency edges"
        );
        assert!(
            graph.package("@rpm-fixture/peer-target", "1.0.0").is_none(),
            "peer target must not appear in the resolved graph before a peer-aware strategy exists"
        );
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

    // An npm alias declaration (a dependency map value whose range text begins
    // with `npm:`, for example `"foo": "npm:bar@1.2.3"`) is rejected as an
    // input error before resolution, rather than being silently misread as a
    // lookup for a nonexistent package (issue #125).

    #[test]
    fn direct_request_rejects_root_manifest_npm_alias() {
        let error = DependencyRequest::from_spec(
            "foo@npm:bar@1.2.3",
            DependencyRequestKind::DirectProduction,
        )
        .expect_err("root-manifest npm alias should be rejected");

        assert!(matches!(
            error,
            ResolutionError::NpmAliasNotSupported {
                ref package_key,
                ref alias_target,
            } if package_key == "foo@npm:bar@1.2.3"
                && alias_target == "npm:bar@1.2.3"
        ));
        let message = error.to_string();
        assert!(
            message.contains("npm alias"),
            "error should name the alias syntax, got {message:?}"
        );
        assert!(
            message.contains("foo@npm:bar@1.2.3"),
            "error should identify the offending package, got {message:?}"
        );
    }

    #[test]
    fn declaration_rejects_transitive_npm_alias() {
        // Transitive registry dependency edges flow through the same
        // `from_spec` boundary after being assembled as `name@range`; an alias
        // value must be rejected here too, before any fetch or lockfile write.
        let error = DependencyDeclaration::from_spec("transitive-dep@npm:other@^2.0.0")
            .expect_err("transitive npm alias should be rejected");

        assert!(matches!(
            error,
            ResolutionError::NpmAliasNotSupported {
                ref package_key,
                ref alias_target,
            } if package_key == "transitive-dep@npm:other@^2.0.0"
                && alias_target == "npm:other@^2.0.0"
        ));
    }

    #[test]
    fn non_prefix_npm_substring_is_not_rejected() {
        // A range that merely contains `npm:` at a non-prefix position must
        // flow through normally; only a value that *starts with* `npm:` is an
        // alias. `1.2.3` is not a real range, but it reaches `from_spec`
        // intact and must not trip the alias guard.
        let request = DependencyRequest::from_spec(
            "not-alias@1.2.3",
            DependencyRequestKind::DirectProduction,
        )
        .expect("non-prefix npm substring must not be rejected");
        assert_eq!(request.package_name, "not-alias");
        assert_eq!(request.requested, "1.2.3");
    }

    #[test]
    fn npm_alias_marker_is_matched_case_insensitively() {
        // npm's own `npm-package-arg` tests `spec.toLowerCase().startsWith("npm:")`,
        // so `NPM:` and `Npm:` are aliases too. Detection must not require an
        // exact-case `npm:` marker, otherwise the declaration degrades to the
        // misleading MissingMetadata failure that rejection is meant to replace.
        for &mixed_case_marker in &["@NPM:", "@Npm:", "@nPm:"] {
            let spec = format!("foo{mixed_case_marker}bar@1.2.3");
            let expected_alias = format!("{}bar@1.2.3", &mixed_case_marker[1..]);

            let error =
                DependencyRequest::from_spec(&spec, DependencyRequestKind::DirectProduction)
                    .expect_err("mixed-case root-manifest alias must be rejected");
            assert!(
                matches!(
                    error,
                    ResolutionError::NpmAliasNotSupported {
                        ref package_key,
                        ref alias_target,
                    } if package_key == &spec && alias_target == &expected_alias
                ),
                "for {spec:?}: expected NpmAliasNotSupported, got {error:?}"
            );

            let error = DependencyDeclaration::from_spec(&spec)
                .expect_err("mixed-case transitive alias must be rejected");
            assert!(
                matches!(
                    error,
                    ResolutionError::NpmAliasNotSupported {
                        ref package_key,
                        ref alias_target,
                    } if package_key == &spec && alias_target == &expected_alias
                ),
                "for {spec:?}: expected NpmAliasNotSupported, got {error:?}"
            );
        }
    }
}
