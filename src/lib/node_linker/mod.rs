use std::{
    fs::{self, File},
    io::{Error, ErrorKind, Write},
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    thread::sleep,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{
    common::constraint::CACHE_DIR,
    lockfile::constraint::LOCK_FILE_PATH,
    lockfile::{Dependency, LockFile},
    package_manifest::PackageManifest,
    registry::tarball_cache_file_name,
};
use flate2::read::GzDecoder;
use tar::Archive;

#[derive(Debug)]
pub struct NodeModules {
    pub path: PathBuf,
}

impl NodeModules {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn read_package(package_name: &str) -> Result<PackageManifest, std::io::Error> {
        let node_module = PathBuf::from("node_modules");
        let path = node_module.join(package_name).join("package.json");
        PackageManifest::read_from_path(path)
    }

    pub fn get_path(&self) -> PathBuf {
        self.path.clone()
    }

    pub fn get_destination(&mut self, name: String) -> PathBuf {
        self.path.join(name)
    }

    pub fn init() -> Result<Self, std::io::Error> {
        Self::init_from_paths("node_modules", LOCK_FILE_PATH, CACHE_DIR)
    }

    fn init_from_paths<P, Q, R>(
        node_modules_path: P,
        lockfile_path: Q,
        cache_dir: R,
    ) -> Result<Self, std::io::Error>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
        R: AsRef<Path>,
    {
        let dir = node_modules_path.as_ref();
        let staging_dir = staging_path(dir);
        if staging_dir.exists() {
            fs::remove_dir_all(&staging_dir).map_err(|error| phase_error("write", error))?;
        }
        fs::create_dir_all(&staging_dir).map_err(|error| phase_error("write", error))?;

        let result = Self::build_staged(&staging_dir, lockfile_path, cache_dir)
            .and_then(|modules| replace_node_modules(dir, &staging_dir).map(|()| modules));

        if result.is_err() {
            let _ = fs::remove_dir_all(&staging_dir);
        }

        result.map(|_| Self::new(dir.to_path_buf()))
    }

    fn build_staged<P, Q, R>(
        staging_dir: P,
        lockfile_path: Q,
        cache_dir: R,
    ) -> Result<Self, std::io::Error>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
        R: AsRef<Path>,
    {
        let mut modules = Self::new(staging_dir.as_ref().to_path_buf());
        let lock_file = LockFile::load_from_path(lockfile_path)
            .map_err(|error| phase_error("resolve", error))?;
        let packages = lock_file.get_packages();
        if packages.is_empty() {
            return Err(phase_error(
                "resolve",
                Error::new(ErrorKind::InvalidData, "lockfile has no packages to link"),
            ));
        }
        let cache_resolver = NodeResolver::new(cache_dir.as_ref().to_path_buf());
        cache_resolver
            .resolve_deps(&mut modules, &packages)
            .map_err(|error| phase_error("extract", error))?;
        modules
            .linking(packages)
            .map_err(|error| phase_error("link", error))?;
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
                fs::metadata(root.join(&dep_name))?;
                let link_path = dependency_link_target(name, &dep_name);
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

fn phase_error(phase: &str, error: std::io::Error) -> std::io::Error {
    Error::new(error.kind(), format!("{phase} failed: {error}"))
}

fn staging_path(node_modules_path: &Path) -> PathBuf {
    let parent = node_modules_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    parent.join(format!(".node_modules.rpm-staging-{}", unique_suffix()))
}

fn backup_path(node_modules_path: &Path) -> PathBuf {
    let parent = node_modules_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    parent.join(format!(".node_modules.rpm-backup-{}", unique_suffix()))
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{nanos}", std::process::id())
}

fn replace_node_modules(target: &Path, staging_dir: &Path) -> Result<(), std::io::Error> {
    let backup_dir = backup_path(target);
    if backup_dir.exists() {
        fs::remove_dir_all(&backup_dir).map_err(|error| phase_error("write", error))?;
    }

    if target.exists() {
        fs::rename(target, &backup_dir).map_err(|error| phase_error("write", error))?;
    }

    match fs::rename(staging_dir, target) {
        Ok(()) => {
            if backup_dir.exists() {
                fs::remove_dir_all(&backup_dir).map_err(|error| phase_error("write", error))?;
            }
            Ok(())
        }
        Err(error) => {
            if backup_dir.exists() {
                let _ = fs::rename(&backup_dir, target);
            }
            Err(phase_error("write", error))
        }
    }
}

fn dependency_link_target(parent_name: &str, dependency_name: &str) -> PathBuf {
    let up_levels = Path::new(parent_name).components().count()
        + Path::new(dependency_name).components().count();
    let mut target = PathBuf::new();
    for _ in 0..up_levels {
        target.push("..");
    }
    target.join(dependency_name)
}

fn package_name_from_lock_key(key: &str) -> Result<&str, std::io::Error> {
    key.rsplit_once('@')
        .map(|(name, _version)| name)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| Error::new(ErrorKind::InvalidData, format!("invalid lock key: {key}")))
}

struct NodeResolver {
    cache_dir: PathBuf,
}

impl NodeResolver {
    fn new(cache_dir: PathBuf) -> Self {
        Self { cache_dir }
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
        let tgz_path = self
            .cache_dir
            .join(tarball_cache_file_name(name, &cached_version));
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
    use flate2::{write::GzEncoder, Compression};
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };
    use tar::{Builder, Header};

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

        fn cache_dir(&self) -> PathBuf {
            self.path.join("cache")
        }

        fn lockfile_path(&self) -> PathBuf {
            self.path.join("rpm.lock")
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

    fn write_lockfile(path: &Path, package: &str, dependencies: &[&str]) {
        let dependencies = dependencies
            .iter()
            .map(|dependency| format!("\"{dependency}\""))
            .collect::<Vec<_>>()
            .join(", ");
        fs::write(
            path,
            format!(
                "lockfile_version = 1\nname = \"fixture-app\"\nversion = \"0.1.0\"\n\n[\"{package}@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = [{dependencies}]\n"
            ),
        )
        .unwrap();
    }

    fn write_package_tgz(cache_dir: &Path, package: &str, version: &str) {
        fs::create_dir_all(cache_dir).unwrap();
        let tarball_name = format!("{}@{}.tgz", package.replace("/", "-"), version);
        let tarball = fs::File::create(cache_dir.join(tarball_name)).unwrap();
        let encoder = GzEncoder::new(tarball, Compression::default());
        let mut builder = Builder::new(encoder);
        let package_json = br#"{"name":"fixture"}"#;
        let mut header = Header::new_gnu();
        header.set_path("package/package.json").unwrap();
        header.set_size(package_json.len() as u64);
        header.set_cksum();
        builder.append(&header, &package_json[..]).unwrap();
        builder.finish().unwrap();
        builder.into_inner().unwrap().finish().unwrap();
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
        assert_eq!(link, PathBuf::from("../../b"));
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
        assert_eq!(link, PathBuf::from("../../../@scope/b"));
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

    #[test]
    fn init_keeps_existing_node_modules_when_extract_fails() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        write_lockfile(&temp.lockfile_path(), "a", &[]);

        let error = NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("extract failed"));
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_existing_node_modules_when_lockfile_is_empty() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        fs::write(temp.lockfile_path(), "").unwrap();

        let error = NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("resolve failed"));
        assert!(error.to_string().contains("lockfile has no packages"));
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_existing_node_modules_when_link_fails() {
        let temp = TempNodeModules::new();
        let existing_file = temp.node_modules().join("keep.txt");
        fs::write(&existing_file, "existing").unwrap();
        write_lockfile(&temp.lockfile_path(), "a", &["missing@1.0.0"]);
        write_package_tgz(&temp.cache_dir(), "a", "1.0.0");

        let error = NodeModules::init_from_paths(
            temp.node_modules(),
            temp.lockfile_path(),
            temp.cache_dir(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("link failed"));
        assert_eq!(fs::read_to_string(existing_file).unwrap(), "existing");
    }

    #[test]
    fn init_keeps_dependency_links_valid_after_replacement() {
        let temp = TempNodeModules::new();
        fs::write(
            temp.lockfile_path(),
            "lockfile_version = 1\nname = \"fixture-app\"\nversion = \"0.1.0\"\n\n[\"a@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = [\"b@1.0.0\"]\n\n[\"b@1.0.0\"]\nversion = \"1.0.0\"\ndependencies = []\n",
        )
        .unwrap();
        write_package_tgz(&temp.cache_dir(), "a", "1.0.0");
        write_package_tgz(&temp.cache_dir(), "b", "1.0.0");

        NodeModules::init_from_paths(temp.node_modules(), temp.lockfile_path(), temp.cache_dir())
            .unwrap();

        let link =
            fs::read_link(temp.node_modules().join("a").join("node_modules").join("b")).unwrap();
        assert_eq!(link, PathBuf::from("../../b"));
    }
}
