use std::{
    fs::{self, File},
    io::{Error, ErrorKind, Write},
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    thread::sleep,
};

use crate::{
    common::constraint::CACHE_DIR,
    lockfile::{Dependency, LockFile},
    package_manifest::PackageManifest,
};
use flate2::read::GzDecoder;
use tar::Archive;

pub struct NodeModules {
    pub path: PathBuf,
}

impl NodeModules {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn read_package(package_name: &str) -> PackageManifest {
        let node_module = PathBuf::from("node_modules");
        let path = node_module.join(package_name).join("package.json");
        let pkg: PackageManifest = PackageManifest::read_file(path.to_str().unwrap());
        pkg
    }

    pub fn get_path(&self) -> PathBuf {
        self.path.clone()
    }

    pub fn get_destination(&mut self, name: String) -> PathBuf {
        self.path.join(name)
    }

    pub fn init() -> Result<Self, std::io::Error> {
        let dir = PathBuf::from("node_modules");
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        let mut modules = Self::new(dir);
        let lock_file = LockFile::load()?;
        let packages = lock_file.get_packages();
        let cache_resolver = NodeResolver::new();
        cache_resolver.resolve_deps(&mut modules, &packages)?;
        modules.linking(packages)?;
        Ok(modules)
    }

    // symbolic_linking
    pub fn linking(&self, deps: Vec<(&String, &Dependency)>) -> Result<(), std::io::Error> {
        for (key, dependency) in deps {
            print!("linking: {} ", key);
            std::io::stdout().flush()?;
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");
            let name = package_name_from_lock_key(key)?;
            let root = self.get_path();
            for dep_name in dependency.get_dependencies_name() {
                let destination = root.join(name).join("node_modules").join(&dep_name);
                let dest_node_modules = destination.parent().ok_or_else(|| {
                    Error::new(
                        ErrorKind::InvalidInput,
                        format!("dependency destination has no parent: {destination:?}"),
                    )
                })?;
                let link_path = fs::canonicalize(root.join(&dep_name))?;
                if !dest_node_modules.exists() {
                    fs::create_dir_all(dest_node_modules)?;
                }

                if !destination.exists() {
                    symlink(link_path, destination)?;
                }
            }
        }
        Ok(())
    }
}

fn package_name_from_lock_key(key: &str) -> Result<&str, std::io::Error> {
    key.rsplit_once('@')
        .map(|(name, _version)| name)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| Error::new(ErrorKind::InvalidData, format!("invalid lock key: {key}")))
}

struct NodeResolver {
    cache_dir: String,
}

impl NodeResolver {
    fn new() -> Self {
        Self {
            cache_dir: CACHE_DIR.to_string(),
        }
    }

    fn resolve_deps(
        &self,
        node_module: &mut NodeModules,
        dependencies: &Vec<(&String, &Dependency)>,
    ) -> Result<(), std::io::Error> {
        for (key, dependency) in dependencies {
            print!("resolving: {} ", key);
            std::io::stdout().flush()?;
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");

            self.resolve_tgz(node_module, key.to_string(), dependency.to_owned())?;

            // .expect(format!("resolve tgz error {}", key).as_str());
        }
        Ok(())
    }

    fn resolve_tgz(
        &self,
        node_module: &mut NodeModules,
        key: String,
        dependency: &Dependency,
    ) -> Result<(), std::io::Error> {
        let name = package_name_from_lock_key(&key)?;
        let cached_version = dependency.get_version();
        let tgz_name = name.replace("/", "-");
        let tgz_path = &format!("{}/{}@{}.tgz", self.cache_dir, &tgz_name, cached_version);

        let tgz_path = Path::new(&tgz_path);
        let tgz = File::open(tgz_path)?;
        let gz = GzDecoder::new(tgz);
        let mut archive = Archive::new(gz);

        let destination = node_module.get_destination(name.to_string());

        if !destination.exists() {
            archive.unpack(&destination)?;
        };
        let pkg_path = destination.join("package");

        if pkg_path.exists() {
            for entry in pkg_path.read_dir()? {
                let entry = entry?;

                fs::rename(entry.path(), destination.join(entry.file_name()))?;
            }
        }
        if destination.read_dir()?.count() == 1 {
            // 만약 파일을 resolve했을때, nodemodules/pkg/pkg 이렇게 되어있는 경우
            // node_module/pkg을 pkg로 옮겨준다.
            for entry in destination
                .join(name.rsplit('/').next().ok_or_else(|| {
                    Error::new(
                        ErrorKind::InvalidData,
                        format!("invalid package name: {name}"),
                    )
                })?)
                .read_dir()?
            {
                let entry = entry?;

                fs::rename(entry.path(), destination.join(entry.file_name()))?;
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct TempNodeModules {
        path: PathBuf,
    }

    impl TempNodeModules {
        fn new() -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let path = std::env::temp_dir()
                .join(format!("rpm-node-linker-{}-{nanos}", std::process::id()));
            fs::create_dir_all(path.join("node_modules")).unwrap();
            Self { path }
        }

        fn node_modules(&self) -> PathBuf {
            self.path.join("node_modules")
        }
    }

    impl Drop for TempNodeModules {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn dependency(version: &str, dependencies: &[&str]) -> Dependency {
        Dependency::new(
            version.to_string(),
            Some(dependencies.iter().map(|dep| dep.to_string()).collect()),
        )
    }

    #[test]
    fn linking_points_dependency_to_actual_package() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("b")).unwrap();
        let node_modules = NodeModules::new(root.clone());
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["b@1.0.0"]);

        node_modules.linking(vec![(&parent_key, &parent)]).unwrap();

        let link = fs::read_link(root.join("a").join("node_modules").join("b")).unwrap();
        assert_eq!(link, fs::canonicalize(root.join("b")).unwrap());
    }

    #[test]
    fn linking_preserves_scoped_dependency_path() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("@scope").join("b")).unwrap();
        let node_modules = NodeModules::new(root.clone());
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["@scope/b@^1.0.0"]);

        node_modules.linking(vec![(&parent_key, &parent)]).unwrap();

        let link =
            fs::read_link(root.join("a").join("node_modules").join("@scope").join("b")).unwrap();
        assert_eq!(
            link,
            fs::canonicalize(root.join("@scope").join("b")).unwrap()
        );
    }

    #[test]
    fn linking_returns_error_when_dependency_target_is_missing() {
        let temp = TempNodeModules::new();
        let root = temp.node_modules();
        fs::create_dir_all(root.join("a")).unwrap();
        let node_modules = NodeModules::new(root);
        let parent_key = "a@1.0.0".to_string();
        let parent = dependency("1.0.0", &["missing@1.0.0"]);

        let error = node_modules
            .linking(vec![(&parent_key, &parent)])
            .unwrap_err();

        assert_eq!(error.kind(), ErrorKind::NotFound);
    }

    #[test]
    fn package_name_from_lock_key_handles_scoped_names() {
        assert_eq!(
            package_name_from_lock_key("@scope/pkg@1.2.3").unwrap(),
            "@scope/pkg"
        );
    }
}
