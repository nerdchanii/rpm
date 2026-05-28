mod semver;

use std::{collections::{HashMap, VecDeque}, future::Future, io::{Error, ErrorKind}};

use crate::registry::Registry;

pub(crate) use semver::select_version;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RequestKind {
    Direct,
    Dev,
    Transitive,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DependencyRequest {
    pub name: String,
    pub requested: String,
    pub kind: RequestKind,
}

impl DependencyRequest {
    pub fn new(name: String, requested: String, kind: RequestKind) -> Self {
        Self {
            name,
            requested,
            kind,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedPackage {
    pub key: String,
    pub name: String,
    pub requested: String,
    pub version: String,
    pub kind: RequestKind,
    pub dependencies: Vec<DependencyRequest>,
    pub tarball: Option<String>,
    pub integrity: Option<String>,
    pub shasum: Option<String>,
}

#[derive(Debug, Default, Clone)]
pub struct ResolvedGraph {
    packages: HashMap<String, ResolvedPackage>,
}

impl ResolvedGraph {
    pub fn packages(&self) -> impl Iterator<Item = &ResolvedPackage> {
        self.packages.values()
    }

    pub fn into_packages(self) -> Vec<ResolvedPackage> {
        self.packages.into_values().collect()
    }
}

pub async fn resolve_dependency_graph<F, Fut>(
    requests: Vec<DependencyRequest>,
    fetch_metadata: F,
) -> std::io::Result<ResolvedGraph>
where
    F: Fn(&str) -> Fut,
    Fut: Future<Output = std::io::Result<Registry>>,
{
    let mut queue = VecDeque::from(requests);
    let mut graph = ResolvedGraph::default();

    while let Some(request) = queue.pop_front() {
        let metadata = fetch_metadata(&request.name).await?;
        let version = select_version(&metadata, &request.requested)?;
        let key = format!("{}@{}", request.name, version);

        if let Some(existing) = graph.packages.get_mut(&key) {
            existing.kind = merge_request_kind(&existing.kind, &request.kind);
            if should_replace_requested(&existing.kind, &request.kind) {
                existing.requested = request.requested.clone();
            }
            continue;
        }

        let dependencies = metadata
            .get_dependencies_for_version(&version)
            .into_iter()
            .map(crate::util::parse_library_name)
            .map(|(name, requested)| DependencyRequest::new(name, requested, RequestKind::Transitive))
            .collect::<Vec<_>>();

        let dist = metadata.get_dist_for_version(&version).ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidData,
                format!("missing dist metadata for {}@{}", request.name, version),
            )
        })?;

        let package = ResolvedPackage {
            key: key.clone(),
            name: request.name.clone(),
            requested: request.requested.clone(),
            version: version.clone(),
            kind: request.kind.clone(),
            dependencies: dependencies.clone(),
            tarball: Some(dist.tarball.clone()),
            integrity: dist.integrity.clone(),
            shasum: Some(dist.shasum.clone()),
        };
        graph.packages.insert(key, package);
        queue.extend(dependencies);
    }

    Ok(graph)
}

fn merge_request_kind(existing: &RequestKind, incoming: &RequestKind) -> RequestKind {
    match (existing, incoming) {
        (RequestKind::Direct, _) | (_, RequestKind::Direct) => RequestKind::Direct,
        (RequestKind::Dev, _) | (_, RequestKind::Dev) => RequestKind::Dev,
        _ => RequestKind::Transitive,
    }
}

fn should_replace_requested(existing: &RequestKind, incoming: &RequestKind) -> bool {
    !matches!(existing, RequestKind::Direct | RequestKind::Dev)
        && matches!(incoming, RequestKind::Direct | RequestKind::Dev)
}

#[cfg(test)]
mod tests {
    use super::{resolve_dependency_graph, DependencyRequest, RequestKind};
    use crate::{registry::load_fixture_registry, util::test_support::fixture_path};

    #[tokio::test]
    async fn resolves_shared_transitive_graph_from_offline_fixtures() {
        let fixture_root = fixture_path(&["install-projects", "performance-small", "registry"]);
        let requests = vec![
            DependencyRequest::new(
                "@rpm-fixture/alpha".to_string(),
                "^1.0.0".to_string(),
                RequestKind::Direct,
            ),
            DependencyRequest::new(
                "@rpm-fixture/beta".to_string(),
                "^1.0.0".to_string(),
                RequestKind::Direct,
            ),
        ];

        let graph = resolve_dependency_graph(requests, |name| {
            let fixture_root = fixture_root.clone();
            let name = name.to_string();
            async move { load_fixture_registry(&fixture_root, &name) }
        })
        .await
        .expect("resolver graph should load from fixtures");

        let mut packages = graph
            .into_packages()
            .into_iter()
            .map(|package| format!("{} requested {}", package.key, package.requested))
            .collect::<Vec<_>>();
        packages.sort();

        assert_eq!(
            packages,
            vec![
                "@rpm-fixture/alpha@1.0.0 requested ^1.0.0",
                "@rpm-fixture/beta@1.0.0 requested ^1.0.0",
                "@rpm-fixture/shared@1.0.0 requested ^1.0.0",
            ]
        );
    }
}
