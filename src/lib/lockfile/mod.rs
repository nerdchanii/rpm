pub(crate) mod constraint;

use constraint::LOCK_FILE_PATH;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::OpenOptions,
    io::{Error, ErrorKind, Read, Result, Write},
    path::Path,
};
use toml::Value;

use crate::util::parse_library_name;

const LOCKFILE_VERSION: u32 = 1;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Relationship {
    Direct,
    Dev,
    #[default]
    Transitive,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dependency {
    #[serde(default)]
    name: String,
    #[serde(default)]
    requested: String,
    #[serde(rename = "version")]
    version: String,
    #[serde(default)]
    relationship: Relationship,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tarball: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    integrity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    shasum: Option<String>,
    #[serde(default)]
    dependencies: HashSet<String>,
}

impl Dependency {
    pub fn new(version: String, dependencies: Option<HashSet<String>>) -> Self {
        Self {
            name: String::new(),
            requested: version.clone(),
            version,
            relationship: Relationship::Transitive,
            tarball: None,
            integrity: None,
            shasum: None,
            dependencies: dependencies.unwrap_or_default(),
        }
    }

    pub fn get_version(&self) -> String {
        self.version.clone()
    }

    pub fn get_requested(&self) -> String {
        self.requested.clone()
    }

    pub fn get_relationship(&self) -> Relationship {
        self.relationship.clone()
    }

    pub fn get_dependencies_name(&self) -> HashSet<String> {
        let mut dependencies = HashSet::new();
        for dep in self.dependencies.iter() {
            let (name, _) = parse_library_name(dep.clone());
            dependencies.insert(name);
        }
        dependencies
    }

    pub fn get_dependencies(&self) -> Vec<String> {
        let mut dependencies = self.dependencies.iter().cloned().collect::<Vec<_>>();
        dependencies.sort();
        dependencies
    }

    pub fn get_tarball(&self) -> Option<String> {
        self.tarball.clone()
    }

    pub fn get_integrity(&self) -> Option<String> {
        self.integrity.clone()
    }

    pub fn get_shasum(&self) -> Option<String> {
        self.shasum.clone()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockFile {
    lockfile_version: u32,
    #[serde(default)]
    name: String,
    #[serde(default)]
    version: String,
    #[serde(flatten)]
    dependencies: HashMap<String, Dependency>,
}

impl LockFile {
    fn empty() -> Self {
        Self {
            lockfile_version: LOCKFILE_VERSION,
            name: String::new(),
            version: String::new(),
            dependencies: HashMap::new(),
        }
    }

    pub fn load() -> Result<Self> {
        Self::load_from_path(LOCK_FILE_PATH)
    }

    pub fn load_from_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let mut buffer = String::new();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path.as_ref())?;
        file.read_to_string(&mut buffer)?;
        if buffer.trim().is_empty() {
            return Ok(Self::empty());
        }
        let parsed: Value = toml::from_str(&buffer).map_err(|error| {
            Error::new(
                ErrorKind::InvalidData,
                format!(
                    "failed to parse lockfile {}: {error}",
                    path.as_ref().display()
                ),
            )
        })?;
        let Some(parsed_version) = parsed
            .get("lockfile_version")
            .and_then(|version| version.as_integer())
        else {
            return Err(Error::new(
                ErrorKind::InvalidData,
                format!("missing lockfile_version in {}", path.as_ref().display()),
            ));
        };
        if parsed_version != LOCKFILE_VERSION as i64 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                format!(
                    "unsupported lockfile version {} in {}",
                    parsed_version,
                    path.as_ref().display()
                ),
            ));
        }
        let mut lock: Self = parsed.try_into().map_err(|error| {
            Error::new(
                ErrorKind::InvalidData,
                format!(
                    "failed to parse lockfile {}: {error}",
                    path.as_ref().display()
                ),
            )
        })?;
        lock.normalize_entries();

        Ok(lock)
    }

    fn normalize_entries(&mut self) {
        self.lockfile_version = LOCKFILE_VERSION;
        for (key, dependency) in self.dependencies.iter_mut() {
            if dependency.name.is_empty() {
                dependency.name = package_name_from_lock_key(key);
            }
            if dependency.requested.is_empty() {
                dependency.requested = dependency.version.clone();
            }
        }
    }

    pub fn get_packages(&self) -> Vec<(&String, &Dependency)> {
        self.dependencies.iter().collect::<Vec<_>>()
    }

    pub fn set_project_metadata(&mut self, name: String, version: String) {
        self.name = name;
        self.version = version;
    }

    pub fn add_dependency(&mut self, name: &String, version: String, dependencies: &[String]) {
        let package_name = package_name_from_lock_key(name);
        self.add_dependency_entry(
            name,
            package_name,
            version.clone(),
            version,
            Relationship::Transitive,
            None,
            None,
            None,
            dependencies,
        );
    }

    #[allow(clippy::too_many_arguments)]
    pub fn add_dependency_entry(
        &mut self,
        key: &String,
        package_name: String,
        requested: String,
        version: String,
        relationship: Relationship,
        tarball: Option<String>,
        integrity: Option<String>,
        shasum: Option<String>,
        dependencies: &[String],
    ) {
        if let Some(dep) = self.dependencies.get_mut(key) {
            let merged_relationship = merge_relationship(&dep.relationship, relationship.clone());
            dep.name = package_name;
            if should_replace_requested(&dep.relationship, &relationship) {
                dep.requested = requested;
            }
            dep.version = version;
            dep.relationship = merged_relationship;
            dep.tarball = tarball;
            dep.integrity = integrity;
            dep.shasum = shasum;
            dependencies.iter().for_each(|value| {
                dep.dependencies.insert(value.clone());
            });
        } else {
            self.dependencies.insert(
                key.clone(),
                Dependency {
                    name: package_name,
                    requested,
                    version,
                    relationship,
                    tarball,
                    integrity,
                    shasum,
                    dependencies: HashSet::from_iter(dependencies.iter().cloned()),
                },
            );
        }
    }

    pub fn save(&self) -> Result<()> {
        self.save_to_path(LOCK_FILE_PATH)
    }

    pub fn save_to_path<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let lockfile = toml::to_string(&self).map_err(|error| {
            Error::new(
                ErrorKind::InvalidData,
                format!(
                    "failed to serialize lockfile {}: {error}",
                    path.as_ref().display()
                ),
            )
        })?;
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path.as_ref())
            .map_err(|error| {
                Error::new(
                    error.kind(),
                    format!(
                        "failed to open lockfile {}: {error}",
                        path.as_ref().display()
                    ),
                )
            })?;

        file.write_all(lockfile.as_bytes()).map_err(|error| {
            Error::new(
                error.kind(),
                format!(
                    "failed to write lockfile {}: {error}",
                    path.as_ref().display()
                ),
            )
        })
    }

    pub fn get_dependency(&self, name: &str) -> Option<&Dependency> {
        self.dependencies.get(name)
    }

    pub fn get_dependency_for_request(
        &self,
        package_name: &str,
        requested: &str,
    ) -> Option<(String, Dependency)> {
        self.dependencies
            .iter()
            .find(|(_, dependency)| {
                dependency.name == package_name && dependency.requested == requested
            })
            .map(|(key, dependency)| (key.clone(), dependency.clone()))
    }
}

fn package_name_from_lock_key(key: &str) -> String {
    match key.rsplit_once('@') {
        Some((name, _)) if !name.is_empty() => name.to_string(),
        _ => key.to_string(),
    }
}

fn merge_relationship(existing: &Relationship, incoming: Relationship) -> Relationship {
    match (existing, incoming) {
        (Relationship::Direct, _) | (_, Relationship::Direct) => Relationship::Direct,
        (Relationship::Dev, _) | (_, Relationship::Dev) => Relationship::Dev,
        _ => Relationship::Transitive,
    }
}

fn should_replace_requested(existing: &Relationship, incoming: &Relationship) -> bool {
    matches!(existing, Relationship::Transitive) || !matches!(incoming, Relationship::Transitive)
}

#[cfg(test)]
mod lock_file_test {

    use super::*;
    use crate::util::test_support::fixture_path;

    #[test]
    fn load_reads_fixture_without_touching_repo_root() {
        let lock = LockFile::load_from_path(fixture_path(&["lockfile", "valid.rpm.lock"])).unwrap();

        assert_eq!(lock.name, "fixture-app");
        assert_eq!(lock.version, "0.1.0");
        assert_eq!(
            lock.get_dependency("react@18.2.0")
                .map(|dependency| dependency.get_version()),
            Some("18.2.0".to_owned())
        );
        assert_eq!(
            lock.get_dependency("react@18.2.0")
                .map(|dependency| dependency.get_requested()),
            Some("^18.0.0".to_owned())
        );
    }

    #[test]
    fn load_initializes_empty_lockfile() {
        let lock = LockFile::load_from_path(fixture_path(&["lockfile", "empty.rpm.lock"])).unwrap();

        assert_eq!(lock.lockfile_version, LOCKFILE_VERSION);
        assert!(lock.get_packages().is_empty());
    }

    #[test]
    fn load_rejects_invalid_lockfile() {
        let error =
            LockFile::load_from_path(fixture_path(&["lockfile", "invalid.rpm.lock"])).unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(error.to_string().contains("failed to parse lockfile"));
        assert!(error.to_string().contains("invalid.rpm.lock"));
    }

    #[test]
    fn load_rejects_unsupported_lockfile_version() {
        let error =
            LockFile::load_from_path(fixture_path(&["lockfile", "unsupported-version.rpm.lock"]))
                .unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(error.to_string().contains("unsupported lockfile version 2"));
        assert!(error.to_string().contains("unsupported-version.rpm.lock"));
    }

    #[test]
    fn merging_entries_preserves_root_relationship() {
        let mut lock = LockFile::empty();
        let key = "shared@1.0.0".to_string();
        lock.add_dependency_entry(
            &key,
            "shared".to_string(),
            "^1.0.0".to_string(),
            "1.0.0".to_string(),
            Relationship::Direct,
            None,
            None,
            None,
            &[],
        );
        lock.add_dependency_entry(
            &key,
            "shared".to_string(),
            "1.0.0".to_string(),
            "1.0.0".to_string(),
            Relationship::Transitive,
            None,
            None,
            None,
            &[],
        );

        assert_eq!(
            lock.get_dependency(&key)
                .map(|dependency| dependency.get_relationship()),
            Some(Relationship::Direct)
        );
        assert_eq!(
            lock.get_dependency(&key)
                .map(|dependency| dependency.get_requested()),
            Some("^1.0.0".to_string())
        );
    }

    #[test]
    fn set_project_metadata_populates_empty_lockfile() {
        let mut lock = LockFile::empty();

        lock.set_project_metadata("fixture-app".to_string(), "0.1.0".to_string());

        assert_eq!(lock.name, "fixture-app");
        assert_eq!(lock.version, "0.1.0");
    }

    #[test]
    fn load_rejects_non_empty_lockfile_without_version_marker() {
        let error =
            LockFile::load_from_path(fixture_path(&["lockfile", "missing-version.rpm.lock"]))
                .unwrap_err();

        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(error.to_string().contains("missing lockfile_version"));
        assert!(error.to_string().contains("missing-version.rpm.lock"));
    }

    #[test]
    fn save_to_path_truncates_old_content() {
        let temp = crate::util::test_support::TempProject::new("lockfile-save").unwrap();
        let path = temp
            .copy_fixture(
                fixture_path(&["lockfile", "long-existing.rpm.lock"]),
                "rpm.lock",
            )
            .unwrap();
        let mut lock = LockFile::empty();
        lock.add_dependency(&"tiny@1.0.0".to_string(), "1.0.0".to_string(), &[]);

        lock.save_to_path(&path).unwrap();

        let saved = std::fs::read_to_string(path).unwrap();
        assert!(saved.contains("[\"tiny@1.0.0\"]"));
        assert!(!saved.contains("stale-package"));
    }
}
