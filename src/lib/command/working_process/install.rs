use crate::{
    api,
    common::constraint::CACHE_DIR,
    lockfile::{LockFile, Relationship},
    node_linker::NodeModules,
    package_manifest::PackageManifest,
    registry::save_tarball_in_dir,
    resolver::{self, DependencyRequest, RequestKind},
};

use std::{io::Error, path::Path};

pub async fn install() -> std::io::Result<()> {
    install_with_sources(
        "./package.json",
        "./rpm.lock",
        "node_modules",
        CACHE_DIR,
        |name| {
            let name = name.to_string();
            async move { api::get_registry(&name).await }
        },
        |url| {
            let url = url.to_string();
            async move { api::get_tarball(&url).await }
        },
    )
    .await
}

pub(crate) async fn install_with_sources<P, Q, R, S, MF, MFut, TF, TFut>(
    manifest_path: P,
    lockfile_path: Q,
    node_modules_path: R,
    cache_dir: S,
    fetch_metadata: MF,
    fetch_tarball: TF,
) -> std::io::Result<()>
where
    P: AsRef<Path>,
    Q: AsRef<Path>,
    R: AsRef<Path>,
    S: AsRef<Path>,
    MF: Fn(&str) -> MFut + Copy,
    MFut: std::future::Future<Output = std::io::Result<crate::registry::Registry>>,
    TF: Fn(&str) -> TFut + Copy,
    TFut: std::future::Future<Output = std::io::Result<Vec<u8>>>,
{
    let package_manifest = PackageManifest::read_from_path(&manifest_path)?;
    let mut lockfile = LockFile::load_from_path(&lockfile_path)?;
    lockfile.set_project_metadata(package_manifest.get_name(), package_manifest.get_version());

    let requests = package_manifest
        .get_dependencies()
        .into_iter()
        .map(|(name, requested)| DependencyRequest::new(name, requested, RequestKind::Direct))
        .chain(
            package_manifest
                .get_dev_dependencies()
                .into_iter()
                .map(|(name, requested)| DependencyRequest::new(name, requested, RequestKind::Dev)),
        )
        .collect::<Vec<_>>();

    let graph = resolver::resolve_dependency_graph(requests, fetch_metadata).await?;

    for package in graph.packages() {
        let tarball_url = package.tarball.as_ref().ok_or_else(|| {
            Error::other(format!("missing tarball URL for {}", package.key))
        })?;
        let mut bytes = fetch_tarball(tarball_url).await?;
        save_tarball_in_dir(cache_dir.as_ref(), &package.key, &mut bytes)?;
        let relationship = match package.kind {
            RequestKind::Direct => Relationship::Direct,
            RequestKind::Dev => Relationship::Dev,
            RequestKind::Transitive => Relationship::Transitive,
        };
        let dependency_edges = package
            .dependencies
            .iter()
            .map(|dependency| format!("{}@{}", dependency.name, dependency.requested))
            .collect::<Vec<_>>();
        lockfile.add_dependency_entry(
            &package.key,
            package.name.clone(),
            package.requested.clone(),
            package.version.clone(),
            relationship,
            package.tarball.clone(),
            package.integrity.clone(),
            package.shasum.clone(),
            &dependency_edges,
        );
    }

    NodeModules::init_from_lockfile(node_modules_path, &lockfile, cache_dir)?;
    lockfile.save_to_path(lockfile_path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::install_with_sources;
    use crate::{
        registry::load_fixture_registry,
        util::test_support::{fixture_path, TempProject},
    };
    use flate2::{write::GzEncoder, Compression};
    use std::{
        fs,
        path::PathBuf,
    };
    use tar::Builder;

    #[tokio::test]
    async fn installs_small_fixture_from_deterministic_inputs() {
        let temp = TempProject::new("install-small-fixture").unwrap();
        let fixture_root = fixture_path(&["install-projects", "performance-small"]);
        let manifest_path = temp
            .copy_fixture(fixture_root.join("package.json"), "project/package.json")
            .unwrap();
        let lockfile_path = temp.project_root().join("project/rpm.lock");
        let node_modules_path = temp.project_root().join("project/node_modules");
        let cache_dir = temp.project_root().join("project/.rpm/.cache");
        let registry_root = fixture_root.join("registry");

        install_with_sources(
            &manifest_path,
            &lockfile_path,
            &node_modules_path,
            &cache_dir,
            |name| {
                let registry_root = registry_root.clone();
                let name = name.to_string();
                async move { load_fixture_registry(&registry_root, &name) }
            },
            |url| {
                let url = url.to_string();
                async move { Ok::<Vec<u8>, std::io::Error>(fixture_tarball_bytes(&url)) }
            },
        )
        .await
        .expect("fixture install should succeed");

        let resolved_packages = fs::read_to_string(fixture_root.join("expected/resolved-packages.txt"))
            .unwrap();
        let lockfile = fs::read_to_string(&lockfile_path).unwrap();
        for expected in resolved_packages.lines() {
            let package_key = expected.split(" requested ").next().unwrap();
            assert!(lockfile.contains(package_key), "lockfile should contain {package_key}");
        }

        assert!(node_modules_path.join("@rpm-fixture/alpha/package.json").exists());
        assert!(node_modules_path.join("@rpm-fixture/beta/package.json").exists());
        assert!(node_modules_path.join("@rpm-fixture/shared/package.json").exists());
        assert_eq!(
            fs::read_to_string(fixture_root.join("package.json")).unwrap(),
            fs::read_to_string(&manifest_path).unwrap()
        );
    }

    fn fixture_tarball_bytes(url: &str) -> Vec<u8> {
        let package_name = fixture_package_name_from_url(url);
        let version = fixture_version_from_url(url);
        let mut tarball_bytes = Vec::new();
        let encoder = GzEncoder::new(&mut tarball_bytes, Compression::default());
        let mut builder = Builder::new(encoder);
        let package_json = format!(
            "{{\"name\":\"{package_name}\",\"version\":\"{version}\"}}"
        );
        let mut header = tar::Header::new_gnu();
        header.set_size(package_json.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        builder
            .append_data(&mut header, "package/package.json", package_json.as_bytes())
            .unwrap();
        builder.finish().unwrap();
        drop(builder);
        tarball_bytes
    }

    fn fixture_package_name_from_url(url: &str) -> String {
        let trimmed = url.trim_start_matches("https://registry.example.invalid/");
        let parts = trimmed.split("/-/").next().unwrap();
        parts.to_string()
    }

    fn fixture_version_from_url(url: &str) -> String {
        let file_name = PathBuf::from(url)
            .file_name()
            .and_then(|file| file.to_str())
            .unwrap()
            .trim_end_matches(".tgz")
            .to_string();
        file_name
            .rsplit_once('-')
            .map(|(_, version)| version.to_string())
            .unwrap()
    }
}
