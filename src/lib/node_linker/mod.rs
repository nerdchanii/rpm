use std::{
    fs::{self, File},
    io::Write,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    thread::sleep,
};

use crate::{
    common::constraint::CACHE_DIR,
    packge_json::Package,
    rpm_lock::lockfile::{Dependency, LockFile},
};
use flate2::read::GzDecoder;
use regex::Regex;
use tar::Archive;

pub struct NodeModules {
    pub path: PathBuf,
}

impl NodeModules {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn read_package(package_name: &str) -> Package {
        let node_module = PathBuf::from("node_modules");
        let path = node_module.join(package_name).join("package.json");
        let pkg: Package = Package::read_file(path.to_str().unwrap());
        pkg
    }

    pub fn get_path(&self) -> PathBuf {
        self.path.clone()
    }

    pub fn get_destination(&mut self, name: String) -> PathBuf {
        self.path.join(name)
    }

    pub fn init() -> Self {
        let dir = PathBuf::from("node_modules");
        if dir.exists() {
            fs::remove_dir_all(&dir).unwrap();
        }
        let mut modules = Self::new(dir);
        let lock_file = LockFile::load().unwrap();
        let packages = lock_file.get_packages();
        let cache_resolver = NodeResolver::new();
        cache_resolver.resolve_deps(&mut modules, &packages);
        modules.linking(packages);
        modules
    }

    // symbolic_linking
    pub fn linking(&self, deps: Vec<(&String, &Dependency)>) {
        for (key, dependency) in deps {
            print!("linking: {} ", key);
            std::io::stdout().flush().unwrap();
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");
            let pkg_name_regex = Regex::new(r"^(?P<name>.*)@(?P<version>.*)$").unwrap();
            let pkg_name = pkg_name_regex.captures(&key).unwrap();
            let name = pkg_name.name("name").unwrap().as_str();
            let root = self.get_path();
            // ex react
            for dep_name in dependency.get_dependencies_name() {
                let dest_node_modules =
                    PathBuf::from(format!("{}/{}/node_modules", root.to_str().unwrap(), name));
                let destination = dest_node_modules.join(dep_name);
                let dest_node_modules = destination.parent().unwrap();
                let link_path = root.join(name);
                if !dest_node_modules.exists() {
                    fs::create_dir_all(&dest_node_modules).unwrap();
                }

                if !destination.exists() {
                    symlink(link_path, destination);
                }
            }
        }
    }
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
    ) {
        for (key, dependency) in dependencies {
            print!("resolving: {} ", key);
            std::io::stdout().flush().unwrap();
            sleep(std::time::Duration::from_millis(1));
            print!("\r\x1B[K");

            self.resolve_tgz(node_module, key.to_string(), &dependency.to_owned())
                .expect("resolve tgz error");

            // .expect(format!("resolve tgz error {}", key).as_str());
        }
    }

    fn resolve_tgz(
        &self,
        node_module: &mut NodeModules,
        key: String,
        dependency: &Dependency,
    ) -> Result<(), std::io::Error> {
        let pkg_name_regex = Regex::new(r"^(?P<name>.*)@(?P<version>.*)$").unwrap();
        let pkg_name = pkg_name_regex.captures(&key).unwrap();
        let name = pkg_name.name("name").unwrap().as_str();
        let cached_version = dependency.get_version();
        let tgz_name = name.replace("/", "-");
        let tgz_path = &format!("{}/{}@{}.tgz", self.cache_dir, &tgz_name, cached_version);

        let tgz_path = Path::new(&tgz_path);
        let tgz = File::open(tgz_path)?;
        let gz = GzDecoder::new(tgz);
        let mut archive = Archive::new(gz);

        let destination = node_module.get_destination(name.to_string());

        if !destination.exists() {
            let unpack_result = archive.unpack(&destination);
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
                .join(name.split('/').last().unwrap())
                .read_dir()?
            {
                let entry = entry?;

                fs::rename(entry.path(), destination.join(entry.file_name()))?;
            }
        }

        Ok(())
    }
}
