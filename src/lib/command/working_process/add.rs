use std::io::Write;

use crate::{api, packge_json::Package, rapm_lock::lockfile::LockFile, util::parse_library_name};
use async_recursion::async_recursion;
use tokio::time::sleep;

#[async_recursion]
pub async fn add(
    pkg: &mut Package,
    lockfile: &mut LockFile,
    libs: Vec<String>,
    dev: bool,
    direct_dependency: bool,
) -> Result<(), reqwest::Error> {
    for lib in libs {
        print!("installing {}...", lib);
        std::io::stdout().flush().unwrap();
        sleep(std::time::Duration::from_millis(1)).await;
        print!("\r\x1b[K");
        let (library_name, version) = parse_library_name(lib.clone());
        let registry = api::get_registry(&library_name, &version).await?;
        let version = if version == "" {
            registry.get_latest_version().unwrap().to_owned()
        } else {
            version
        };
        let key = format!("{}@{}", library_name, version);
        let version = if version == "*" {
            registry.get_latest_version().unwrap().to_owned()
        } else {
            version
        };

        registry.download_tarball(&key, &version).await?;
        let dependencies = registry.get_dependencies();

        lockfile.add_dependency(&key, version.clone(), &mut dependencies.clone());
        if direct_dependency {
            if dev {
                pkg.add_dev_dependency(library_name, version);
            } else {
                pkg.add_dependency(library_name, version);
            }
        }

        add(pkg, lockfile, dependencies, dev, false).await?;
    }
    Ok(())
}
