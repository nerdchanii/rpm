use std::io::Write;

use crate::{
    api,
    lockfile::{LockFile, Relationship},
    package_manifest::PackageManifest,
    util::parse_library_name,
};
use async_recursion::async_recursion;
use tokio::time::sleep;

#[async_recursion]
pub async fn add(
    pkg: &mut PackageManifest,
    lockfile: &mut LockFile,
    libs: Vec<String>,
    dev: bool,
    write_manifest: bool,
) -> std::io::Result<()> {
    lockfile.set_project_metadata(pkg.get_name(), pkg.get_version());
    add_with_context(pkg, lockfile, libs, dev, write_manifest, true).await
}

#[async_recursion]
async fn add_with_context(
    pkg: &mut PackageManifest,
    lockfile: &mut LockFile,
    libs: Vec<String>,
    dev: bool,
    write_manifest: bool,
    root_dependency: bool,
) -> std::io::Result<()> {
    for lib in libs {
        print!("installing {}...", lib);
        std::io::stdout().flush()?;
        sleep(std::time::Duration::from_millis(1)).await;
        print!("\r\x1b[K");
        let (library_name, requested_range) = parse_library_name(lib.clone());
        let registry_range = registry_request_from_requested(&requested_range);
        let registry = api::get_registry(&library_name, &registry_range).await?;
        let requested = if requested_range.is_empty() {
            "latest".to_string()
        } else {
            requested_range.clone()
        };
        let version = registry
            .get_latest_version()
            .map(|version| version.to_owned())
            .unwrap_or_else(|| requested_range.clone());
        let key = format!("{}@{}", library_name, version);

        registry.download_tarball(&key, &version).await?;
        let dependencies = registry.get_dependencies_for_version(&version);
        let dist = registry.get_dist_for_version(&version);
        let manifest_version = manifest_version_from_requested(&requested, &version);
        let relationship = if root_dependency {
            if dev {
                Relationship::Dev
            } else {
                Relationship::Direct
            }
        } else {
            Relationship::Transitive
        };

        lockfile.add_dependency_entry(
            &key,
            library_name.clone(),
            requested,
            version.clone(),
            relationship,
            dist.map(|dist| dist.tarball.clone()),
            dist.and_then(|dist| dist.integrity.clone()),
            dist.map(|dist| dist.shasum.clone()),
            &dependencies,
        );
        if write_manifest {
            if dev {
                pkg.add_dev_dependency(library_name, manifest_version);
            } else {
                pkg.add_dependency(library_name, manifest_version);
            }
        }

        add_with_context(pkg, lockfile, dependencies, dev, false, false).await?;
    }
    Ok(())
}

fn registry_request_from_requested(requested: &str) -> String {
    let mut version = requested.to_string();
    if version.contains("||") {
        version = version
            .split("||")
            .last()
            .map(|version| version.trim().to_string())
            .unwrap_or_default();
    }
    if version.starts_with('^') || version.starts_with('~') {
        version.remove(0);
    }
    version
}

fn manifest_version_from_requested(requested: &str, resolved: &str) -> String {
    if requested == "latest" {
        resolved.to_string()
    } else {
        requested.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::registry_request_from_requested;

    #[test]
    fn registry_request_preserves_legacy_manifest_range_normalization() {
        assert_eq!(registry_request_from_requested("^18.0.0"), "18.0.0");
        assert_eq!(registry_request_from_requested("~5.2.0"), "5.2.0");
        assert_eq!(
            registry_request_from_requested("^17.0.0 || ^18.0.0"),
            "18.0.0"
        );
    }

    #[test]
    fn manifest_version_preserves_requested_range_for_direct_adds() {
        assert_eq!(
            super::manifest_version_from_requested("^1.2.0", "1.4.0"),
            "^1.2.0"
        );
        assert_eq!(
            super::manifest_version_from_requested("latest", "1.4.0"),
            "1.4.0"
        );
    }
}
