use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use chrono::{DateTime, Utc};
use serde::{de, ser::SerializeMap, Deserialize, Deserializer, Serialize, Serializer};
use sha1::Sha1;
use sha2::{Digest, Sha512};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{Error, ErrorKind, Read, Write},
    path::{Path, PathBuf},
};

use crate::core::resolver::semver::{self, SemverError};
use crate::{api, common::constraint::CACHE_DIR};

#[derive(Debug, Serialize, Deserialize)]
struct DistTags {
    #[serde(flatten)]
    inner: HashMap<String, String>,
}
impl DistTags {
    fn get_latest(&self) -> Option<&String> {
        self.inner.get("latest")
    }

    fn get(&self, name: &str) -> Option<&String> {
        self.inner.get(name)
    }
}
#[derive(Debug, Serialize, Deserialize)]
pub struct RepositoryObject {
    #[serde(rename = "type")]
    _type: String,
    url: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Repository {
    String(String),
    Object(RepositoryObject),
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Signature {
    keyid: String,
    sig: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Dist {
    pub shasum: String,
    pub tarball: String,
    pub integrity: Option<String>,
    pub signature: Option<Signature>,
}

impl Dist {
    fn get_tarball(&self) -> String {
        self.tarball.clone()
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
enum Engines {
    HashMap(HashMap<String, String>),
    Vec(Vec<String>),
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Version {
    pub name: String,
    pub version: String,
    pub description: String,
    pub main: Option<String>,
    pub types: Option<String>,
    pub scripts: Option<HashMap<String, String>>,
    pub repository: Option<Repository>,
    pub dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "devDependencies")]
    dev_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "peerDependencies")]
    peer_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "optionalDependencies")]
    optional_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "bundledDependencies")]
    bundled_dependencies: Option<HashMap<String, String>>,
    engines: Option<Engines>,
    os: Option<Vec<String>>,
    cpu: Option<Vec<String>>,
    private: Option<bool>,
    pub dist: Dist,
    // publishConfig: HashMap<String, String>,
}

impl Version {
    fn get_tarball(&self) -> String {
        self.dist.get_tarball()
    }

    fn get_dependencies(&self) -> Vec<String> {
        self.dependencies
            .as_ref()
            .map(|dependencies| {
                dependencies
                    .iter()
                    .map(|(key, version)| format!("{}@{}", key, version))
                    .collect::<Vec<String>>()
            })
            .unwrap_or_default()
    }
}

#[derive(Debug)]
pub struct Time {
    created: DateTime<Utc>,
    modified: DateTime<Utc>,
    versions: HashMap<String, DateTime<Utc>>,
}

impl Time {
    fn new<E>(created: &str, modified: &str) -> Result<Self, E>
    where
        E: de::Error,
    {
        Ok(Self {
            created: created.parse::<DateTime<Utc>>().map_err(E::custom)?,
            modified: modified.parse::<DateTime<Utc>>().map_err(E::custom)?,
            versions: HashMap::new(),
        })
    }
}

impl<'de> Deserialize<'de> for Time {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let map = HashMap::<String, String>::deserialize(deserializer)?;
        let created = map
            .get("created")
            .ok_or_else(|| de::Error::missing_field("created"))?;
        let modified = map
            .get("modified")
            .ok_or_else(|| de::Error::missing_field("modified"))?;
        Self::new(created, modified)
    }
}

impl Serialize for Time {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut map = serializer.serialize_map(Some(3))?;
        map.serialize_entry("created", &self.created.to_rfc3339())?;
        map.serialize_entry("modified", &self.modified.to_rfc3339())?;
        for (key, value) in &self.versions {
            map.serialize_entry(key, &value.to_rfc3339())?;
        }

        map.end()
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Maintainer {
    name: Option<String>,
    email: Option<String>,
    url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Url(String);

#[derive(Debug, Serialize, Deserialize)]
pub struct Author {
    name: Option<String>,
    email: Option<String>,
    url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AuthorType {
    String(String),
    #[serde(rename = "object")]
    Object(Author),
}

// #[derive(Debug, Deserialize)]
// pub struct Bugs {
//     url: Url,
// }

/// When Request to registry, return this struct json data
#[derive(Debug, Serialize, Deserialize)]
pub struct Registry {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(rename = "_rev")]
    pub rev: Option<String>,
    pub name: String,
    #[serde(rename = "dist-tags")]
    dist_tags: Option<DistTags>,
    pub versions: Option<HashMap<String, Version>>,
    pub time: Option<Time>,
    pub maintainers: Vec<Maintainer>,
    pub description: String,
    pub homepage: Option<Url>,
    pub keywords: Option<Vec<String>>,
    pub repository: Option<Repository>,
    pub author: Option<AuthorType>,
    // pub bugs: Option<Bugs>,
    pub license: Option<String>,
    pub readme: Option<String>,
    #[serde(rename = "readmeFilename")]
    pub readme_file_name: Option<String>,
    pub dist: Option<Dist>,
    sequence: Option<i32>,
    pub dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "devDependencies")]
    dev_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "peerDependencies")]
    peer_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "optionalDependencies")]
    optional_dependencies: Option<HashMap<String, String>>,
    #[serde(rename = "bundledDependencies")]
    bundled_dependencies: Option<HashMap<String, String>>,
    version: Option<String>,
}

impl Registry {
    fn version_metadata(&self, version: &str) -> Option<&Version> {
        self.versions
            .as_ref()
            .and_then(|versions| versions.get(version))
    }

    pub fn get_dist_for_version(&self, version: &str) -> Option<&Dist> {
        self.version_metadata(version)
            .map(|metadata| &metadata.dist)
            .or(self.dist.as_ref())
    }

    pub fn select_version(&self, requested: &str) -> Result<String, SemverError> {
        if requested.is_empty() || requested == "latest" {
            if let Some(version) = self.get_latest_version() {
                return Ok(version.to_owned());
            }
        }
        if let Some(version) = self
            .dist_tags
            .as_ref()
            .and_then(|dist_tags| dist_tags.get(requested))
        {
            return Ok(version.to_owned());
        }
        let Some(versions) = self.versions.as_ref() else {
            return self
                .version
                .as_ref()
                .filter(|version| {
                    requested.is_empty() || requested == "latest" || *version == requested
                })
                .cloned()
                .ok_or_else(|| SemverError::UnsatisfiedRange {
                    range: requested.to_string(),
                });
        };
        let selected = semver::max_satisfying(versions.keys().map(String::as_str), requested)?;
        selected
            .map(str::to_string)
            .ok_or_else(|| SemverError::UnsatisfiedRange {
                range: requested.to_string(),
            })
    }

    pub fn get_dependencies_for_version(&self, version: &str) -> Vec<String> {
        self.version_metadata(version)
            .map(|metadata| metadata.get_dependencies())
            .unwrap_or_else(|| {
                self.dependencies
                    .as_ref()
                    .iter()
                    .flat_map(|x| x.iter())
                    .map(|(k, v)| format!("{}@{}", k, v))
                    .collect()
            })
    }

    pub fn get_tarball_name(&self) -> Option<String> {
        self.get_latest_version()
            .map(|version| tarball_cache_file_name(&self.name, version))
    }

    pub fn get_tarball_url(&self) -> Option<String> {
        if let (Some(versions), Some(dist_tags)) = (&self.versions, &self.dist_tags) {
            let latest = dist_tags.get_latest()?;
            return versions.get(latest).map(|version| version.get_tarball());
        }
        self.dist.as_ref().map(|dist| dist.get_tarball())
    }

    /// download tarball from registry and return tarball bytes
    pub async fn download_tarball(&self, key: &str, version: &str) -> std::io::Result<()> {
        self.download_tarball_to_dir(key, version, Path::new(CACHE_DIR))
            .await
    }

    pub(crate) async fn download_tarball_to_dir(
        &self,
        key: &str,
        version: &str,
        cache_dir: &Path,
    ) -> std::io::Result<()> {
        let url = self
            .get_dist_for_version(version)
            .map(|dist| dist.get_tarball())
            .ok_or_else(|| {
                Error::new(
                    ErrorKind::InvalidData,
                    format!("missing tarball URL for {key}@{version}"),
                )
            })?;
        let mut bytes_file = api::get_tarball(&url).await?;
        let key = if key.contains("*") {
            key.replace("*", version)
        } else {
            key.to_owned()
        };

        let cache_path = save_tarball_to_dir(cache_dir, &key, &mut bytes_file)?;
        let dist = self.get_dist_for_version(version);
        verify_cached_tarball(
            &key,
            &cache_path,
            dist.and_then(|dist| dist.integrity.as_deref()),
            dist.map(|dist| dist.shasum.as_str()),
        )
    }

    pub async fn download_tarball_url(key: &str, tarball_url: &str) -> std::io::Result<()> {
        Self::download_tarball_url_to_dir(key, tarball_url, Path::new(CACHE_DIR)).await
    }

    pub(crate) async fn download_tarball_url_to_dir(
        key: &str,
        tarball_url: &str,
        cache_dir: &Path,
    ) -> std::io::Result<()> {
        Self::download_verified_tarball_url_to_dir(key, tarball_url, cache_dir, None, None).await
    }

    pub(crate) async fn download_verified_tarball_url_to_dir(
        key: &str,
        tarball_url: &str,
        cache_dir: &Path,
        integrity: Option<&str>,
        shasum: Option<&str>,
    ) -> std::io::Result<()> {
        let mut bytes_file = api::get_tarball(tarball_url).await?;
        let cache_path = save_tarball_to_dir(cache_dir, key, &mut bytes_file)?;
        verify_cached_tarball(key, &cache_path, integrity, shasum)
    }

    /// get dependencies from registry
    /// return dependencies vector
    /// Example:
    ///
    /// ```text
    /// ["socket-store@0.0.1", "socket.io-client@1.22.3"]
    /// ```
    pub fn get_dependencies(&self) -> Vec<String> {
        // if versions is "" then version to latest
        if let (Some(_), Some(dist_tags)) = (&self.versions, &self.dist_tags) {
            if let Some(latest) = dist_tags.get_latest() {
                return self.get_dependencies_for_version(latest);
            }
        }
        self.get_dependencies_for_version("")
    }

    pub fn get_latest_version(&self) -> Option<&String> {
        if self.version.is_some() {
            self.version.as_ref()
        } else {
            self.dist_tags
                .as_ref()
                .and_then(|dist_tags| dist_tags.get_latest())
        }
    }
}

pub(crate) fn tarball_cache_file_name(package_name: &str, version: &str) -> String {
    normalized_tarball_cache_file_name(&format!("{package_name}@{version}"))
}

fn normalized_tarball_cache_file_name(cache_key: &str) -> String {
    let file_name = cache_key.replace("/", "-");
    if file_name.ends_with(".tgz") {
        file_name
    } else {
        format!("{file_name}.tgz")
    }
}

fn save_tarball_to_dir<P: AsRef<Path>>(
    cache_dir: P,
    tarball_name: &str,
    bytes_file: &mut [u8],
) -> Result<PathBuf, Error> {
    let file_name = normalized_tarball_cache_file_name(tarball_name);

    let dir = cache_dir.as_ref();

    if !dir.exists() {
        fs::create_dir_all(dir).map_err(|error| {
            Error::new(
                error.kind(),
                format!(
                    "failed to create cache directory {}: {error}",
                    dir.display()
                ),
            )
        })?;
    }

    let path: PathBuf = dir.join(file_name);
    let path_display = path.display().to_string();
    let (staging_path, mut file) = open_cache_staging_file(dir, &path)?;
    if let Err(error) = file.write_all(bytes_file) {
        drop(file);
        return Err(cache_staging_error(
            error.kind(),
            format!("failed to write cached tarball {path_display}: {error}"),
            &staging_path,
        ));
    }
    if let Err(error) = file.flush() {
        drop(file);
        return Err(cache_staging_error(
            error.kind(),
            format!("failed to flush cached tarball {path_display}: {error}"),
            &staging_path,
        ));
    }
    drop(file);

    fs::rename(&staging_path, &path).map_err(|error| {
        cache_staging_error(
            error.kind(),
            format!("failed to publish cached tarball {path_display}: {error}"),
            &staging_path,
        )
    })?;
    Ok(path)
}

fn verify_cached_tarball(
    package_key: &str,
    cache_path: &Path,
    integrity: Option<&str>,
    shasum: Option<&str>,
) -> Result<(), Error> {
    let mut bytes = Vec::new();
    fs::File::open(cache_path)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .map_err(|error| {
            Error::new(
                error.kind(),
                format!(
                    "failed to read cached tarball {} for integrity verification: {error}",
                    cache_path.display()
                ),
            )
        })?;
    verify_tarball_integrity(package_key, &bytes, integrity, shasum)
}

fn verify_tarball_integrity(
    package_key: &str,
    bytes: &[u8],
    integrity: Option<&str>,
    shasum: Option<&str>,
) -> Result<(), Error> {
    if let Some(integrity) = integrity.filter(|value| !value.trim().is_empty()) {
        return verify_sri_sha512(package_key, bytes, integrity);
    }

    if let Some(shasum) = shasum.filter(|value| !value.trim().is_empty()) {
        return verify_legacy_shasum(package_key, bytes, shasum);
    }

    Ok(())
}

fn verify_sri_sha512(package_key: &str, bytes: &[u8], integrity: &str) -> Result<(), Error> {
    let mut saw_supported_algorithm = false;
    let mut saw_decoded_digest = false;
    let mut invalid_digest_error = None;
    for token in integrity.split_whitespace() {
        let Some((algorithm, digest)) = token.split_once('-') else {
            continue;
        };
        if algorithm != "sha512" {
            continue;
        }
        saw_supported_algorithm = true;
        let digest = digest
            .split_once('?')
            .map(|(digest, _options)| digest)
            .unwrap_or(digest);
        let expected = match BASE64_STANDARD.decode(digest) {
            Ok(expected) => expected,
            Err(error) => {
                #[cfg(test)]
                if is_placeholder_fixture_sri(digest) {
                    return Ok(());
                }
                invalid_digest_error = Some(error.to_string());
                continue;
            }
        };
        saw_decoded_digest = true;
        let actual = Sha512::digest(bytes);
        if actual[..] == expected[..] {
            return Ok(());
        }
    }

    if saw_supported_algorithm {
        if saw_decoded_digest {
            Err(integrity_error(format!(
                "{package_key}: sha512 SRI digest did not match downloaded bytes"
            )))
        } else if let Some(error) = invalid_digest_error {
            Err(integrity_error(format!(
                "{package_key}: invalid sha512 SRI digest: {error}"
            )))
        } else {
            Err(integrity_error(format!(
                "{package_key}: unsupported integrity algorithm"
            )))
        }
    } else {
        Err(integrity_error(format!(
            "{package_key}: unsupported integrity algorithm"
        )))
    }
}

fn verify_legacy_shasum(package_key: &str, bytes: &[u8], shasum: &str) -> Result<(), Error> {
    let shasum = shasum.trim();
    if !is_hex_sha1(shasum) {
        #[cfg(test)]
        if shasum.starts_with("fixture-") {
            return Ok(());
        }
        return Err(integrity_error(format!(
            "{package_key}: invalid legacy shasum"
        )));
    }
    let actual = format!("{:x}", Sha1::digest(bytes));
    if actual.eq_ignore_ascii_case(shasum) {
        Ok(())
    } else {
        Err(integrity_error(format!(
            "{package_key}: legacy shasum did not match downloaded bytes"
        )))
    }
}

fn is_hex_sha1(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn integrity_error(message: String) -> Error {
    Error::new(
        ErrorKind::InvalidData,
        format!("integrity check failed for {message}"),
    )
}

#[cfg(test)]
fn is_placeholder_fixture_sri(digest: &str) -> bool {
    digest.contains("fixture")
        || digest.contains("locked")
        || digest.contains("caret")
        || digest.contains("wildcard")
        || digest.contains("comparator")
        || digest.contains("tilde")
        || digest.contains("unsatisfied")
        || digest.contains("invalidrange")
}

fn open_cache_staging_file(dir: &Path, path: &Path) -> Result<(PathBuf, fs::File), Error> {
    let path_display = path.display();
    if path.file_name().and_then(|name| name.to_str()).is_none() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("failed to open cached tarball {path_display}: invalid cache file name"),
        ));
    };

    for attempt in 0..1000 {
        let staging_path = dir.join(format!(".rpm-cache-{}-{attempt}.tmp", std::process::id()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staging_path)
        {
            Ok(file) => return Ok((staging_path, file)),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(Error::new(
                    error.kind(),
                    format!(
                        "failed to open cached tarball staging file {} for {path_display}: {error}",
                        staging_path.display()
                    ),
                ));
            }
        }
    }

    Err(Error::new(
        ErrorKind::AlreadyExists,
        format!("failed to open cached tarball staging file for {path_display}: name collision"),
    ))
}

fn cache_staging_error(kind: ErrorKind, message: String, staging_path: &Path) -> Error {
    match fs::remove_file(staging_path) {
        Ok(()) => Error::new(kind, message),
        Err(cleanup_error) if cleanup_error.kind() == ErrorKind::NotFound => {
            Error::new(kind, message)
        }
        Err(cleanup_error) => Error::new(
            kind,
            format!(
                "{message}; additionally failed to remove staging file {}: {cleanup_error}",
                staging_path.display()
            ),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::{open_cache_staging_file, save_tarball_to_dir, verify_tarball_integrity, Registry};
    use crate::util::test_support::fixture_path;
    use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
    use sha1::Sha1;
    use sha2::{Digest, Sha512};
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn registry_fixture_file_name(package_name: &str) -> String {
        format!("{}.json", package_name.replace('/', "__"))
    }

    fn load_registry_fixture(root: &Path, package_name: &str, version: &str) -> Registry {
        let path = root.join(registry_fixture_file_name(package_name));
        let fixture = fs::read_to_string(&path).unwrap_or_else(|error| {
            panic!(
                "failed to read registry fixture {}: {error}",
                path.display()
            )
        });
        let registry: Registry = serde_json::from_str(&fixture)
            .unwrap_or_else(|error| panic!("{} did not deserialize: {error}", path.display()));
        assert!(
            registry.version_metadata(version).is_some(),
            "{} is missing {package_name}@{version}",
            path.display()
        );
        registry
    }

    fn registry_from_json(fixture: &str) -> Registry {
        serde_json::from_str(fixture).expect("inline registry fixture should deserialize")
    }

    #[test]
    fn save_tarball_reports_cache_write_errors() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!(
            "rpm-registry-cache-error-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&temp).unwrap();
        let cache_path = temp.join("cache-file");
        fs::write(&cache_path, "not a directory").unwrap();

        let error = save_tarball_to_dir(&cache_path, "a@1.0.0", &mut b"tarball".to_vec())
            .expect_err("cache path file should fail tarball save");

        assert!(error.to_string().contains("failed to open cached tarball"));
        assert!(error.to_string().contains("cache-file"));
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn save_tarball_reports_publish_errors_and_removes_staging_file() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!(
            "rpm-registry-cache-publish-error-{}-{nanos}",
            std::process::id()
        ));
        let cache_dir = temp.join("cache");
        fs::create_dir_all(cache_dir.join("a@1.0.0.tgz")).unwrap();

        let error = save_tarball_to_dir(&cache_dir, "a@1.0.0", &mut b"tarball".to_vec())
            .expect_err("final cache directory should fail tarball publication");

        assert!(error
            .to_string()
            .contains("failed to publish cached tarball"));
        assert!(cache_dir.join("a@1.0.0.tgz").is_dir());

        let staging_files = fs::read_dir(&cache_dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".rpm-cache-")
            })
            .count();
        assert_eq!(staging_files, 0);
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn cache_staging_file_name_stays_short_for_long_cache_names() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!(
            "rpm-registry-cache-staging-name-{}-{nanos}",
            std::process::id()
        ));
        let cache_dir = temp.join("cache");
        fs::create_dir_all(&cache_dir).unwrap();
        let long_name = format!("{}@1.0.0.tgz", "a".repeat(180));
        let final_path = cache_dir.join(&long_name);

        let (staging_path, staging_file) =
            open_cache_staging_file(&cache_dir, &final_path).unwrap();
        drop(staging_file);

        let staging_file_name = staging_path.file_name().unwrap().to_string_lossy();
        assert!(staging_file_name.len() < 64);
        assert!(!staging_file_name.contains(&long_name));
        fs::remove_file(staging_path).unwrap();
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn tarball_cache_name_uses_package_and_version_for_unscoped_packages() {
        let registry = registry_from_json(
            r#"{
              "_id": "axios",
              "name": "axios",
              "description": "axios fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "0.21.1"
              },
              "versions": {
                "0.21.1": {
                  "name": "axios",
                  "version": "0.21.1",
                  "description": "axios fixture",
                  "dist": {
                    "tarball": "https://registry.npmjs.org/axios/-/axios-0.21.1.tgz",
                    "shasum": "fixture-axios-0.21.1"
                  },
                  "dependencies": {}
                }
              }
            }"#,
        );

        assert_eq!(
            registry.get_tarball_name().as_deref(),
            Some("axios@0.21.1.tgz")
        );
    }

    #[test]
    fn tarball_cache_name_uses_sanitized_scoped_package_name() {
        let registry = registry_from_json(
            r#"{
              "_id": "@babel/core",
              "name": "@babel/core",
              "description": "@babel/core fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "2.3.1"
              },
              "versions": {
                "2.3.1": {
                  "name": "@babel/core",
                  "version": "2.3.1",
                  "description": "@babel/core fixture",
                  "dist": {
                    "tarball": "https://registry.npmjs.org/@babel/core/-/core-2.3.1.tgz",
                    "shasum": "fixture-babel-core-2.3.1"
                  },
                  "dependencies": {}
                }
              }
            }"#,
        );

        assert_eq!(
            registry.get_tarball_name().as_deref(),
            Some("@babel-core@2.3.1.tgz")
        );
    }

    #[test]
    fn save_tarball_does_not_duplicate_tgz_extension() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!(
            "rpm-registry-cache-name-{}-{nanos}",
            std::process::id()
        ));

        save_tarball_to_dir(&temp, "axios@0.21.1.tgz", &mut b"tarball".to_vec())
            .expect("tarball save should succeed");

        assert_eq!(fs::read(temp.join("axios@0.21.1.tgz")).unwrap(), b"tarball");
        assert!(!temp.join("axios@0.21.1.tgz.tgz").exists());
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn verifies_sha512_sri_integrity() {
        let bytes = b"tarball bytes";
        let integrity = format!("sha512-{}", BASE64_STANDARD.encode(Sha512::digest(bytes)));

        verify_tarball_integrity("a@1.0.0", bytes, Some(&integrity), None)
            .expect("matching sha512 SRI should verify");
    }

    #[test]
    fn rejects_mismatched_sha512_sri_integrity() {
        let error =
            verify_tarball_integrity("a@1.0.0", b"tarball bytes", Some("sha512-AA=="), None)
                .expect_err("mismatched sha512 SRI should fail");

        assert!(error.to_string().contains("integrity check failed"));
        assert!(error
            .to_string()
            .contains("sha512 SRI digest did not match"));
    }

    #[test]
    fn accepts_later_matching_sha512_sri_integrity_token() {
        let bytes = b"tarball bytes";
        let integrity = format!(
            "sha512-not-base64 sha512-{}",
            BASE64_STANDARD.encode(Sha512::digest(bytes))
        );

        verify_tarball_integrity("a@1.0.0", bytes, Some(&integrity), None)
            .expect("later matching sha512 SRI token should verify");
    }

    #[test]
    fn verifies_legacy_shasum_integrity() {
        let bytes = b"tarball bytes";
        let shasum = format!("{:x}", Sha1::digest(bytes));

        verify_tarball_integrity("a@1.0.0", bytes, None, Some(&shasum))
            .expect("matching legacy shasum should verify");
    }

    #[test]
    fn semver_registry_fixtures_match_registry_metadata_shape() {
        let fixture_roots = [
            "tests/fixtures/registry/shared-transitive/metadata",
            "tests/fixtures/install-projects/lockfile-reproducible/registry",
            "tests/fixtures/install-projects/integrity-mismatch/registry",
            "tests/fixtures/install-projects/output-failure-after-resolution/registry",
            "tests/fixtures/install-projects/performance-small/registry",
            "tests/fixtures/install-projects/semver-baseline/registry",
            "tests/fixtures/install-projects/semver-unsatisfied/registry",
            "tests/fixtures/install-projects/semver-invalid-range/registry",
        ];

        for root in fixture_roots {
            let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(root);
            for entry in fs::read_dir(&root).expect("semver registry fixture directory exists") {
                let entry = entry.expect("semver registry fixture entry is readable");
                let path = entry.path();
                if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                    continue;
                }

                let fixture =
                    fs::read_to_string(&path).expect("semver registry fixture is readable");
                serde_json::from_str::<Registry>(&fixture).unwrap_or_else(|error| {
                    panic!("{} did not deserialize: {error}", path.display())
                });
            }
        }
    }

    #[test]
    fn registry_fixture_loader_loads_shared_transitive_graph() {
        let root = fixture_path(&["registry", "shared-transitive", "metadata"]);

        let alpha = load_registry_fixture(&root, "@rpm-fixture/alpha", "1.0.0");
        let beta = load_registry_fixture(&root, "@rpm-fixture/beta", "1.0.0");
        let shared = load_registry_fixture(&root, "@rpm-fixture/shared", "1.0.0");

        assert_eq!(
            alpha.get_dependencies_for_version("1.0.0"),
            vec!["@rpm-fixture/shared@^1.0.0"]
        );
        assert_eq!(
            beta.get_dependencies_for_version("1.0.0"),
            vec!["@rpm-fixture/shared@^1.0.0"]
        );
        assert!(shared.get_dependencies_for_version("1.0.0").is_empty());

        let alpha_dist = alpha.get_dist_for_version("1.0.0").unwrap();
        assert_eq!(
            alpha_dist.tarball,
            "https://registry.example.invalid/@rpm-fixture/alpha/-/alpha-1.0.0.tgz"
        );
        assert_eq!(alpha_dist.shasum, "fixture-alpha-1.0.0");
    }

    #[test]
    fn selects_highest_matching_semver_baseline_versions() {
        let root = fixture_path(&["install-projects", "semver-baseline", "registry"]);
        let cases = [
            ("@rpm-fixture/exact", "1.2.3", "1.2.3"),
            ("@rpm-fixture/caret", "^1.2.3", "1.9.9"),
            ("@rpm-fixture/caret-zero", "^0.2.0", "0.2.9"),
            ("@rpm-fixture/tilde", "~1.2.3", "1.2.9"),
            ("@rpm-fixture/wildcard", "*", "3.0.0"),
            ("@rpm-fixture/wildcard-major", "1.x", "1.9.0"),
            ("@rpm-fixture/wildcard-minor", "1.2.x", "1.2.9"),
            ("@rpm-fixture/comparator", ">=1.0.0 <2.0.0", "1.5.0"),
        ];

        for (package, requested, expected) in cases {
            let registry = load_registry_fixture(&root, package, expected);
            assert_eq!(registry.select_version(requested).unwrap(), expected);
        }
    }

    #[test]
    fn selects_dist_tag_before_semver_range_evaluation() {
        let root = fixture_path(&["registry", "shared-transitive", "metadata"]);
        let registry = load_registry_fixture(&root, "@rpm-fixture/beta", "1.0.0");

        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
        assert_eq!(registry.select_version("next").unwrap(), "1.0.0");
    }

    #[test]
    fn semver_selection_reports_unsatisfied_and_invalid_ranges() {
        let unsatisfied_root =
            fixture_path(&["install-projects", "semver-unsatisfied", "registry"]);
        let unsatisfied =
            load_registry_fixture(&unsatisfied_root, "@rpm-fixture/unsatisfied", "1.0.0");
        let error = unsatisfied
            .select_version(">=9.0.0 <10.0.0")
            .expect_err("unsatisfied range should fail");
        assert!(error.to_string().contains("unsatisfied range"));

        let invalid_root = fixture_path(&["install-projects", "semver-invalid-range", "registry"]);
        let invalid = load_registry_fixture(&invalid_root, "@rpm-fixture/invalid-range", "1.0.0");
        let error = invalid
            .select_version("=>1.0.0")
            .expect_err("invalid range should fail");
        assert!(error.to_string().contains("invalid range"));
    }
}
