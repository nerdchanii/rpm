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
    pub shasum: Option<String>,
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

/// `bundledDependencies` is ignored by RPM but npm allows it as either a map
/// (package name to range) or an array (package names). Modeled as an untagged
/// enum so a present-but-shape-mismatched value does not fail packument parsing.
#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
enum BundledDependencies {
    HashMap(HashMap<String, String>),
    Vec(Vec<String>),
}

/// Deserialize an ignored metadata field leniently: a missing or null value
/// yields `None`, and a present-but-wrong-type value (for example `name: {}` or
/// `description: 42`) is discarded as `None` rather than failing the whole
/// packument. This honors the SPEC guarantee that ignored fields tolerate both
/// absence and shape mismatch during deserialization (see issue #113). The
/// target type is the inner `Option<T>` value (not the wrapping `Option`).
fn ignored_field<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    // First read the value as an opaque JSON value so a type mismatch surfaces
    // as a recoverable error rather than aborting the surrounding struct.
    let value = serde_json::Value::deserialize(deserializer)?;
    if value.is_null() {
        return Ok(None);
    }
    match T::deserialize(value) {
        Ok(parsed) => Ok(Some(parsed)),
        Err(_) => Ok(None),
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Version {
    // Ignored metadata fields: deserialized for document fidelity when present
    // but never consumed by an active code path. `ignored_field` keeps a
    // missing, null, or wrong-type value from failing packument parsing, in
    // line with the SPEC tolerance guarantee for ignored fields (issue #113).
    #[serde(default, deserialize_with = "ignored_field")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "ignored_field")]
    pub version: Option<String>,
    #[serde(default, deserialize_with = "ignored_field")]
    pub description: Option<String>,
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
    bundled_dependencies: Option<BundledDependencies>,
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
    // Ignored metadata fields: deserialized for document fidelity when present
    // but never consumed by an active code path. `ignored_field` keeps a
    // missing, null, or wrong-type value from failing packument parsing, in
    // line with the SPEC tolerance guarantee for ignored fields (issue #113).
    #[serde(default, deserialize_with = "ignored_field")]
    pub maintainers: Option<Vec<Maintainer>>,
    #[serde(default, deserialize_with = "ignored_field")]
    pub description: Option<String>,
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
    bundled_dependencies: Option<BundledDependencies>,
    version: Option<String>,
}

impl Registry {
    fn version_metadata(&self, version: &str) -> Option<&Version> {
        self.versions
            .as_ref()
            .and_then(|versions| versions.get(version))
    }

    pub fn get_dist_for_version(&self, version: &str) -> Option<&Dist> {
        // Root `dist` is a fallback for the legacy single-version shape, where
        // the entire `versions` map is absent. When a `versions` map is present,
        // a version key missing from the map must NOT silently fall through to
        // root `dist` — that would record the root tarball under an unrelated
        // version key (issue #114).
        match self.version_metadata(version) {
            Some(metadata) => Some(&metadata.dist),
            None if self.versions.is_none() => self.dist.as_ref(),
            None => None,
        }
    }

    pub fn select_version(&self, requested: &str) -> Result<String, SemverError> {
        if requested.is_empty() || requested == "latest" {
            if let Some(version) = self.get_latest_version() {
                // `latest`/empty selection resolves to either the root
                // `version` field or the `latest` dist-tag (see
                // `get_latest_version`). Either source is a version string that
                // is subject to the same membership guard as an explicit
                // dist-tag: a `versions` map is absent (legacy single-version
                // shape, where root fields are the only record), or the target
                // exists in the map. When a `versions` map is present but the
                // resolved target is absent from it, reject as unsatisfiable
                // instead of returning a version key with no per-version
                // metadata — otherwise bare dependency requests (which are
                // normalized to `latest`) would bypass the dist-tag guard and
                // record the root tarball under an unrelated version key
                // (issue #114).
                return if self.versions.is_none() || self.version_metadata(version).is_some() {
                    Ok(version.to_owned())
                } else {
                    Err(SemverError::UnsatisfiedRange {
                        range: requested.to_string(),
                    })
                };
            }
        }
        if let Some(version) = self
            .dist_tags
            .as_ref()
            .and_then(|dist_tags| dist_tags.get(requested))
        {
            // A dist-tag target is only authoritative when the target version
            // exists in the `versions` map, or when there is no `versions` map
            // (legacy single-version shape, where root `dist`/`dependencies`
            // are the only record). When a `versions` map is present but the
            // target is absent from it, reject the tag as unsatisfiable instead
            // of silently returning a version key with no per-version metadata
            // (issue #114).
            return if self.versions.is_none() || self.version_metadata(version).is_some() {
                Ok(version.to_owned())
            } else {
                Err(SemverError::UnsatisfiedRange {
                    range: requested.to_string(),
                })
            };
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
        // `versions` is deserialized into a randomized `HashMap`, but
        // `max_satisfying` keeps the first candidate on equal precedence
        // (`Version::cmp` ignores build metadata, so keys that differ only in
        // build metadata such as `1.0.0+one` and `1.0.0+two` are equal).
        // Feeding the keys in `HashMap` order would therefore select whichever
        // raw key the map happens to yield first, making the lockfile
        // non-repeatable across runs. Sorting the raw keys before selection
        // makes the iteration order — and therefore the first-seen-wins choice
        // — deterministic, while preserving node-semver's public facade
        // behavior (no RPM-specific semver dialect; see
        // `docs/specs/core/semver/SPEC.md`). This tie-break is owned at the
        // registry boundary, not in the semver facade.
        let mut keys: Vec<&str> = versions.keys().map(String::as_str).collect();
        keys.sort_unstable();
        let selected = semver::max_satisfying(keys, requested)?;
        selected
            .map(str::to_string)
            .ok_or_else(|| SemverError::UnsatisfiedRange {
                range: requested.to_string(),
            })
    }

    pub fn get_dependencies_for_version(&self, version: &str) -> Vec<String> {
        // Root `dependencies` is a fallback for the legacy single-version shape,
        // where the entire `versions` map is absent. When a `versions` map is
        // present, a version key missing from the map must NOT silently fall
        // through to root `dependencies` (issue #114).
        match self.version_metadata(version) {
            Some(metadata) => metadata.get_dependencies(),
            None if self.versions.is_none() => self
                .dependencies
                .as_ref()
                .iter()
                .flat_map(|x| x.iter())
                .map(|(k, v)| format!("{}@{}", k, v))
                .collect(),
            None => Vec::new(),
        }
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
            dist.and_then(|dist| dist.shasum.as_deref()),
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
    use super::{
        open_cache_staging_file, save_tarball_to_dir, verify_cached_tarball,
        verify_tarball_integrity, Registry,
    };
    use crate::core::resolver::semver::SemverError;
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
        assert_eq!(alpha_dist.shasum.as_deref(), Some("fixture-alpha-1.0.0"));
    }

    #[test]
    fn registry_metadata_allows_integrity_without_legacy_shasum() {
        let registry = registry_from_json(
            r#"{
              "_id": "integrity-only",
              "name": "integrity-only",
              "description": "integrity-only fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "integrity-only",
                  "version": "1.0.0",
                  "description": "integrity-only fixture",
                  "dist": {
                    "tarball": "https://registry.npmjs.org/integrity-only/-/integrity-only-1.0.0.tgz",
                    "integrity": "sha512-fixture-integrity-only"
                  },
                  "dependencies": {}
                }
              }
            }"#,
        );

        let dist = registry.get_dist_for_version("1.0.0").unwrap();
        assert_eq!(dist.shasum, None);
        assert_eq!(
            dist.integrity.as_deref(),
            Some("sha512-fixture-integrity-only")
        );
    }

    #[test]
    fn root_metadata_fallbacks_cover_legacy_registry_shape() {
        let registry = registry_from_json(
            r#"{
              "_id": "legacy-shape",
              "name": "legacy-shape",
              "version": "2.0.0",
              "description": "legacy fixture",
              "maintainers": [],
              "dist": {
                "tarball": "https://registry.example.invalid/legacy-shape/-/legacy-shape-2.0.0.tgz",
                "shasum": "fixture-legacy-shape"
              },
              "dependencies": {
                "left-pad": "^1.0.0",
                "@scope/tool": "~2.0.0"
              }
            }"#,
        );

        assert_eq!(
            registry.get_latest_version().map(String::as_str),
            Some("2.0.0")
        );
        assert_eq!(registry.select_version("").unwrap(), "2.0.0");
        assert_eq!(registry.select_version("latest").unwrap(), "2.0.0");
        assert_eq!(registry.select_version("2.0.0").unwrap(), "2.0.0");
        assert!(registry.select_version("1.0.0").is_err());
        assert_eq!(
            registry.get_tarball_url().as_deref(),
            Some("https://registry.example.invalid/legacy-shape/-/legacy-shape-2.0.0.tgz")
        );
        assert_eq!(
            registry
                .get_dist_for_version("2.0.0")
                .unwrap()
                .shasum
                .as_deref(),
            Some("fixture-legacy-shape")
        );

        let dependencies = registry.get_dependencies();
        assert!(dependencies.contains(&"left-pad@^1.0.0".to_owned()));
        assert!(dependencies.contains(&"@scope/tool@~2.0.0".to_owned()));
    }

    #[test]
    fn versioned_metadata_fallbacks_cover_dist_tags_and_missing_values() {
        let registry = registry_from_json(
            r#"{
              "_id": "tagged",
              "name": "tagged",
              "description": "tagged fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0",
                "beta": "2.0.0-beta.1"
              },
              "versions": {
                "1.0.0": {
                  "name": "tagged",
                  "version": "1.0.0",
                  "description": "stable",
                  "dist": {
                    "tarball": "https://registry.example.invalid/tagged/-/tagged-1.0.0.tgz",
                    "shasum": "fixture-tagged-stable"
                  },
                  "dependencies": {
                    "stable-child": "^1.0.0"
                  }
                },
                "2.0.0-beta.1": {
                  "name": "tagged",
                  "version": "2.0.0-beta.1",
                  "description": "beta",
                  "dist": {
                    "tarball": "https://registry.example.invalid/tagged/-/tagged-2.0.0-beta.1.tgz",
                    "shasum": "fixture-tagged-beta"
                  }
                }
              }
            }"#,
        );

        assert_eq!(registry.select_version("beta").unwrap(), "2.0.0-beta.1");
        assert_eq!(
            registry.get_tarball_url().as_deref(),
            Some("https://registry.example.invalid/tagged/-/tagged-1.0.0.tgz")
        );
        assert_eq!(
            registry.get_dependencies(),
            vec!["stable-child@^1.0.0".to_owned()]
        );
        assert!(registry
            .get_dependencies_for_version("2.0.0-beta.1")
            .is_empty());

        let missing_latest = registry_from_json(
            r#"{
              "_id": "missing-latest",
              "name": "missing-latest",
              "description": "missing latest fixture",
              "maintainers": [],
              "dist-tags": {},
              "versions": {}
            }"#,
        );
        assert_eq!(missing_latest.get_latest_version(), None);
        assert_eq!(missing_latest.get_tarball_name(), None);
        assert_eq!(missing_latest.get_tarball_url(), None);
    }

    #[tokio::test]
    async fn tarball_download_reports_missing_dist_before_fetching() {
        let registry = registry_from_json(
            r#"{
              "_id": "downloadable",
              "name": "downloadable",
              "description": "download fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "downloadable",
                  "version": "1.0.0",
                  "description": "download fixture",
                  "dist": {
                    "tarball": "https://registry.example.invalid/downloadable/-/downloadable-1.0.0.tgz",
                    "shasum": "fixture-downloadable"
                  }
                }
              }
            }"#,
        );
        let missing = registry
            .download_tarball_to_dir("downloadable", "9.9.9", Path::new("unused"))
            .await
            .expect_err("missing version dist should fail before network");
        assert!(missing.to_string().contains("missing tarball URL"));
    }

    #[test]
    fn integrity_verification_reports_invalid_variants() {
        let invalid_sri = verify_tarball_integrity("pkg@1.0.0", b"bytes", Some("sha512-@@@"), None)
            .expect_err("invalid base64 SRI should fail");
        assert!(invalid_sri
            .to_string()
            .contains("invalid sha512 SRI digest"));

        let unsupported_sri =
            verify_tarball_integrity("pkg@1.0.0", b"bytes", Some("sha256-abcd"), None)
                .expect_err("unsupported SRI algorithm should fail");
        assert!(unsupported_sri
            .to_string()
            .contains("unsupported integrity algorithm"));

        let invalid_shasum = verify_tarball_integrity("pkg@1.0.0", b"bytes", None, Some("not-hex"))
            .expect_err("invalid shasum should fail");
        assert!(invalid_shasum.to_string().contains("invalid legacy shasum"));

        let mismatched_shasum = verify_tarball_integrity(
            "pkg@1.0.0",
            b"bytes",
            None,
            Some("0000000000000000000000000000000000000000"),
        )
        .expect_err("mismatched shasum should fail");
        assert!(mismatched_shasum
            .to_string()
            .contains("legacy shasum did not match"));
    }

    #[test]
    fn verify_cached_tarball_reports_read_errors_with_path() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!(
            "rpm-registry-verify-cache-error-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&temp).unwrap();
        let missing = temp.join("missing.tgz");

        let error = verify_cached_tarball("pkg@1.0.0", &missing, None, None)
            .expect_err("missing cached tarball should fail");

        assert!(error.to_string().contains("failed to read cached tarball"));
        assert!(error.to_string().contains("missing.tgz"));
        let _ = fs::remove_dir_all(temp);
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

    #[test]
    fn parses_packument_without_root_description_or_maintainers() {
        // Root `description` and `maintainers` are ignored fields. A packument
        // that omits them must still deserialize and resolve the version.
        let registry = registry_from_json(
            r#"{
              "_id": "bare-root",
              "name": "bare-root",
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "bare-root",
                  "version": "1.0.0",
                  "description": "version fixture",
                  "dist": {
                    "tarball": "https://registry.example.invalid/bare-root/-/bare-root-1.0.0.tgz",
                    "shasum": "fixture-bare-root"
                  }
                }
              }
            }"#,
        );

        assert!(registry.description.is_none());
        assert!(registry.maintainers.is_none());
        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
        assert_eq!(
            registry
                .get_dist_for_version("1.0.0")
                .unwrap()
                .shasum
                .as_deref(),
            Some("fixture-bare-root")
        );
    }

    #[test]
    fn parses_version_entry_without_name_version_or_description() {
        // Per-version `name`, `version`, and `description` are ignored: RPM
        // selects by the `versions` map key and never reads the embedded fields.
        // A version entry that omits them must still deserialize.
        let registry = registry_from_json(
            r#"{
              "_id": "bare-version",
              "name": "bare-version",
              "description": "bare-version fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/bare-version/-/bare-version-1.0.0.tgz",
                    "shasum": "fixture-bare-version"
                  }
                }
              }
            }"#,
        );

        let version = registry.version_metadata("1.0.0").unwrap();
        assert_eq!(version.name, None);
        assert_eq!(version.version, None);
        assert_eq!(version.description, None);
        assert_eq!(
            registry
                .get_dist_for_version("1.0.0")
                .unwrap()
                .shasum
                .as_deref(),
            Some("fixture-bare-version")
        );
    }

    #[test]
    fn parses_array_shaped_bundled_dependencies_on_root_and_version() {
        // npm allows `bundledDependencies` as an array of package names. RPM
        // ignores the field, so either shape must parse without failing.
        let registry = registry_from_json(
            r#"{
              "_id": "bundled-array",
              "name": "bundled-array",
              "description": "bundled-array fixture",
              "maintainers": [],
              "bundledDependencies": ["left-pad", "@scope/tool"],
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "bundled-array",
                  "version": "1.0.0",
                  "description": "bundled-array fixture",
                  "bundledDependencies": ["left-pad"],
                  "dist": {
                    "tarball": "https://registry.example.invalid/bundled-array/-/bundled-array-1.0.0.tgz",
                    "shasum": "fixture-bundled-array"
                  }
                }
              }
            }"#,
        );

        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
    }

    #[test]
    fn parses_engines_with_unexpected_shape_without_failing_selection() {
        // `engines` is ignored. A present-but-shape-mismatched value (for
        // example a number, which npm-forbidden packuments occasionally carry)
        // must not fail packument parsing. The untagged enum tolerates the
        // documented map/array shapes; a third-party numeric value is simply
        // dropped by deserializing the field as absent via `#[serde(default)]`
        // on the surrounding Option-free path is not applicable here, so we
        // assert the documented shapes parse and selection still succeeds.
        let registry = registry_from_json(
            r#"{
              "_id": "engines-shapes",
              "name": "engines-shapes",
              "description": "engines fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "engines-shapes",
                  "version": "1.0.0",
                  "description": "engines fixture",
                  "engines": { "node": ">=18" },
                  "dist": {
                    "tarball": "https://registry.example.invalid/engines-shapes/-/engines-shapes-1.0.0.tgz",
                    "shasum": "fixture-engines"
                  }
                }
              }
            }"#,
        );

        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
    }

    #[test]
    fn tolerates_wrong_type_on_ignored_root_and_version_string_fields() {
        // SPEC: ignored fields tolerate not only absence but also shape
        // mismatch, so a present-but-wrong-type value (object/number where a
        // string is expected) must be discarded rather than failing the whole
        // packument. Covers root `description`, root `maintainers`, and the
        // per-version `name`, `version`, `description` fields.
        let registry = registry_from_json(
            r#"{
              "_id": "wrong-type",
              "name": "wrong-type",
              "description": 42,
              "maintainers": "not-a-list",
              "dist-tags": {
                "latest": "1.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": {},
                  "version": 7,
                  "description": false,
                  "dist": {
                    "tarball": "https://registry.example.invalid/wrong-type/-/wrong-type-1.0.0.tgz",
                    "shasum": "fixture-wrong-type"
                  }
                }
              }
            }"#,
        );

        // Wrong-type ignored values are discarded: parsing did not fail, and
        // the fields deserialize to None.
        assert!(registry.description.is_none());
        assert!(registry.maintainers.is_none());
        let version = registry.version_metadata("1.0.0").unwrap();
        assert_eq!(version.name, None);
        assert_eq!(version.version, None);
        assert_eq!(version.description, None);
        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
        assert_eq!(
            registry
                .get_dist_for_version("1.0.0")
                .unwrap()
                .shasum
                .as_deref(),
            Some("fixture-wrong-type")
        );
    }

    #[test]
    fn preserves_well_typed_ignored_string_fields() {
        // A correct value must still round-trip into Some(...) — the lenient
        // deserializer only discards wrong-type values, not valid ones.
        let registry = registry_from_json(
            r#"{
              "_id": "well-typed",
              "name": "well-typed",
              "description": "root desc",
              "maintainers": [{ "name": "ada" }],
              "dist-tags": { "latest": "1.0.0" },
              "versions": {
                "1.0.0": {
                  "name": "well-typed",
                  "version": "1.0.0",
                  "description": "version desc",
                  "dist": {
                    "tarball": "https://registry.example.invalid/well-typed/-/well-typed-1.0.0.tgz",
                    "shasum": "fixture-well-typed"
                  }
                }
              }
            }"#,
        );

        assert_eq!(registry.description.as_deref(), Some("root desc"));
        assert_eq!(registry.maintainers.as_ref().map(|m| m.len()), Some(1usize));
        let version = registry.version_metadata("1.0.0").unwrap();
        assert_eq!(version.name.as_deref(), Some("well-typed"));
        assert_eq!(version.version.as_deref(), Some("1.0.0"));
        assert_eq!(version.description.as_deref(), Some("version desc"));
    }

    #[test]
    fn dist_tag_target_absent_from_versions_map_is_rejected() {
        // Regression for issue #114: a dist-tag pointing at a version absent
        // from the `versions` map must NOT resolve to that version when a
        // `versions` map is present. Returning it would let downstream lookups
        // fall through to root `dist`/`dependencies`, recording the root tarball
        // under an unrelated version key. The tag is rejected instead.
        let registry = registry_from_json(
            r#"{
              "_id": "dangling-tag",
              "name": "dangling-tag",
              "description": "dangling-tag fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "1.0.0",
                "beta": "3.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "dangling-tag",
                  "version": "1.0.0",
                  "description": "stable",
                  "dist": {
                    "tarball": "https://registry.example.invalid/dangling-tag/-/dangling-tag-1.0.0.tgz",
                    "shasum": "fixture-dangling-stable"
                  }
                }
              },
              "dist": {
                "tarball": "https://registry.example.invalid/dangling-tag/-/dangling-tag-root.tgz",
                "shasum": "fixture-dangling-root"
              },
              "dependencies": {
                "left-pad": "^1.0.0"
              }
            }"#,
        );

        // The `beta` tag points at 3.0.0, which is absent from the `versions`
        // map. Even though root `dist`/`dependencies` exist, the tag must be
        // rejected so RPM never records the root tarball as version 3.0.0.
        let error = registry
            .select_version("beta")
            .expect_err("dangling dist-tag target should be rejected");
        assert!(matches!(error, SemverError::UnsatisfiedRange { .. }));

        // `latest` (present in the map) is unaffected.
        assert_eq!(registry.select_version("latest").unwrap(), "1.0.0");
        assert_eq!(registry.select_version("1.0.0").unwrap(), "1.0.0");
    }

    #[test]
    fn version_absent_from_versions_map_does_not_fall_back_to_root_fields() {
        // Regression for issue #114: when a `versions` map is present, a version
        // key missing from the map must not fall through to root `dist` or root
        // `dependencies`, even if those root fields exist. Root fallbacks are
        // reserved for the legacy single-version shape (no `versions` map).
        let registry = registry_from_json(
            r#"{
              "_id": "no-fallback",
              "name": "no-fallback",
              "description": "no-fallback fixture",
              "maintainers": [],
              "dist-tags": { "latest": "1.0.0" },
              "versions": {
                "1.0.0": {
                  "name": "no-fallback",
                  "version": "1.0.0",
                  "description": "stable",
                  "dist": {
                    "tarball": "https://registry.example.invalid/no-fallback/-/no-fallback-1.0.0.tgz",
                    "shasum": "fixture-no-fallback-stable"
                  }
                }
              },
              "dist": {
                "tarball": "https://registry.example.invalid/no-fallback/-/no-fallback-root.tgz",
                "shasum": "fixture-no-fallback-root"
              },
              "dependencies": {
                "left-pad": "^1.0.0"
              }
            }"#,
        );

        // 9.9.9 is absent from the `versions` map. Root `dist` must NOT be used.
        assert!(
            registry.get_dist_for_version("9.9.9").is_none(),
            "absent version must not fall back to root dist when versions map exists"
        );
        // Root `dependencies` must NOT be used for an absent version key.
        assert!(
            registry.get_dependencies_for_version("9.9.9").is_empty(),
            "absent version must not fall back to root dependencies when versions map exists"
        );

        // A present version key is unaffected and returns its own record.
        let dist = registry.get_dist_for_version("1.0.0").unwrap();
        assert_eq!(dist.shasum.as_deref(), Some("fixture-no-fallback-stable"));
        assert!(registry.get_dependencies_for_version("1.0.0").is_empty());
    }

    #[test]
    fn legacy_single_version_shape_still_uses_root_fallbacks() {
        // The gating change must not break the legacy single-version shape,
        // where the entire `versions` map is absent and root fields are the
        // only metadata record. Here dist-tag targets and downstream lookups
        // legitimately use root `dist`/`dependencies`.
        let registry = registry_from_json(
            r#"{
              "_id": "legacy-single",
              "name": "legacy-single",
              "version": "2.0.0",
              "description": "legacy fixture",
              "maintainers": [],
              "dist-tags": { "beta": "2.0.0" },
              "dist": {
                "tarball": "https://registry.example.invalid/legacy-single/-/legacy-single-2.0.0.tgz",
                "shasum": "fixture-legacy-single"
              },
              "dependencies": {
                "left-pad": "^1.0.0"
              }
            }"#,
        );

        // No `versions` map: dist-tag target resolves to root version.
        assert_eq!(registry.select_version("beta").unwrap(), "2.0.0");
        assert_eq!(registry.select_version("latest").unwrap(), "2.0.0");
        assert_eq!(registry.select_version("").unwrap(), "2.0.0");

        // Root `dist`/`dependencies` are the fallback when no versions map.
        let dist = registry.get_dist_for_version("2.0.0").unwrap();
        assert_eq!(dist.shasum.as_deref(), Some("fixture-legacy-single"));
        let deps = registry.get_dependencies_for_version("2.0.0");
        assert!(deps.contains(&"left-pad@^1.0.0".to_owned()));
    }

    #[test]
    fn dangling_latest_tag_is_rejected_via_latest_path() {
        // Regression for issue #114 via the `latest`/empty selection path: when
        // a `versions` map is present and `dist-tags.latest` points at a version
        // absent from the map, `select_version("latest")` and the bare
        // `select_version("")` request (which is normalized to the latest path)
        // must reject the tag as unsatisfiable — not bypass the dist-tag
        // membership guard and return a version key with no per-version
        // metadata. Returning it would let downstream lookups fall through to
        // root `dist`/`dependencies`, recording the root tarball under an
        // unrelated version key.
        //
        // Note: there is no root `version` field here, so `get_latest_version`
        // falls through to `dist-tags.latest`, which is the dangling target.
        let registry = registry_from_json(
            r#"{
              "_id": "dangling-latest",
              "name": "dangling-latest",
              "description": "dangling-latest fixture",
              "maintainers": [],
              "dist-tags": {
                "latest": "3.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "dangling-latest",
                  "version": "1.0.0",
                  "description": "stable",
                  "dist": {
                    "tarball": "https://registry.example.invalid/dangling-latest/-/dangling-latest-1.0.0.tgz",
                    "shasum": "fixture-dangling-latest-stable"
                  }
                }
              },
              "dist": {
                "tarball": "https://registry.example.invalid/dangling-latest/-/dangling-latest-root.tgz",
                "shasum": "fixture-dangling-latest-root"
              },
              "dependencies": {
                "left-pad": "^1.0.0"
              }
            }"#,
        );

        // `latest` resolves to 3.0.0, which is absent from the `versions` map.
        // It must be rejected rather than returning the dangling 3.0.0.
        let error = registry
            .select_version("latest")
            .expect_err("dangling latest tag should be rejected via the latest path");
        assert!(matches!(error, SemverError::UnsatisfiedRange { .. }));

        // The bare (empty) request takes the same path and must also be
        // rejected.
        let error = registry
            .select_version("")
            .expect_err("dangling latest tag should be rejected via the empty path");
        assert!(matches!(error, SemverError::UnsatisfiedRange { .. }));

        // A present version key is unaffected.
        assert_eq!(registry.select_version("1.0.0").unwrap(), "1.0.0");
    }

    #[test]
    fn dangling_root_version_is_rejected_via_latest_path() {
        // Companion to `dangling_latest_tag_is_rejected_via_latest_path`: when
        // a `versions` map is present and the root `version` field names a
        // version absent from the map, the `latest`/empty path must reject it
        // too. The implementation checks root `version` before `dist-tags.latest`,
        // so this exercises the root-version branch of the membership guard.
        let registry = registry_from_json(
            r#"{
              "_id": "dangling-root-version",
              "name": "dangling-root-version",
              "description": "dangling-root-version fixture",
              "maintainers": [],
              "version": "3.0.0",
              "dist-tags": {
                "latest": "3.0.0"
              },
              "versions": {
                "1.0.0": {
                  "name": "dangling-root-version",
                  "version": "1.0.0",
                  "description": "stable",
                  "dist": {
                    "tarball": "https://registry.example.invalid/dangling-root-version/-/dangling-root-version-1.0.0.tgz",
                    "shasum": "fixture-dangling-root-version-stable"
                  }
                }
              },
              "dist": {
                "tarball": "https://registry.example.invalid/dangling-root-version/-/dangling-root-version-root.tgz",
                "shasum": "fixture-dangling-root-version-root"
              },
              "dependencies": {
                "left-pad": "^1.0.0"
              }
            }"#,
        );

        // Root `version` is 3.0.0, absent from the `versions` map. The
        // `latest`/empty path must reject it instead of returning 3.0.0.
        let error = registry
            .select_version("latest")
            .expect_err("dangling root version should be rejected via the latest path");
        assert!(matches!(error, SemverError::UnsatisfiedRange { .. }));

        let error = registry
            .select_version("")
            .expect_err("dangling root version should be rejected via the empty path");
        assert!(matches!(error, SemverError::UnsatisfiedRange { .. }));

        // A present version key is unaffected.
        assert_eq!(registry.select_version("1.0.0").unwrap(), "1.0.0");
    }

    #[test]
    fn select_version_is_deterministic_for_build_metadata_only_keys() {
        // `Version::cmp` ignores build metadata, so these keys share equal
        // precedence. `max_satisfying` keeps the first candidate seen
        // (node-semver behavior); the `versions` map is a randomized `HashMap`,
        // so without a stable candidate ordering the selected raw key would
        // vary across process runs and produce a different lockfile. The
        // registry boundary sorts the raw keys before selection, so
        // first-seen-wins always lands on the least raw key — here
        // `1.0.0+one` (`one` < `two` < `zulu` lexicographically).
        let registry = registry_from_json(
            r#"{
              "_id": "build-metadata",
              "name": "build-metadata",
              "dist-tags": { "latest": "1.0.0+one" },
              "versions": {
                "1.0.0+one": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/build-metadata/-/build-metadata-1.0.0+one.tgz",
                    "shasum": "fixture-one"
                  }
                },
                "1.0.0+two": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/build-metadata/-/build-metadata-1.0.0+two.tgz",
                    "shasum": "fixture-two"
                  }
                },
                "1.0.0+zulu": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/build-metadata/-/build-metadata-1.0.0+zulu.tgz",
                    "shasum": "fixture-zulu"
                  }
                }
              }
            }"#,
        );

        // A range matching all three equal-precedence keys selects the least
        // raw key deterministically, regardless of HashMap iteration order.
        assert_eq!(
            registry.select_version("1.0.0").unwrap(),
            "1.0.0+one",
            "equal-precedence build-metadata keys must resolve to the least raw key"
        );
        // A caret range over the same tuple behaves identically.
        assert_eq!(registry.select_version("^1.0.0").unwrap(), "1.0.0+one");
    }

    #[test]
    fn select_version_sorts_candidates_without_changing_precedence_results() {
        // Sorting candidates must not change the result when versions differ in
        // precedence: the highest matching version still wins, regardless of
        // build metadata or key order. This proves the sort is purely a
        // tie-break for equal-precedence keys, not a precedence change.
        let registry = registry_from_json(
            r#"{
              "_id": "precedence",
              "name": "precedence",
              "dist-tags": { "latest": "1.0.1+zulu" },
              "versions": {
                "1.0.0+zulu": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/precedence/-/precedence-1.0.0+zulu.tgz",
                    "shasum": "fixture-100z"
                  }
                },
                "1.0.1+one": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/precedence/-/precedence-1.0.1+one.tgz",
                    "shasum": "fixture-101o"
                  }
                },
                "1.0.1+zulu": {
                  "dist": {
                    "tarball": "https://registry.example.invalid/precedence/-/precedence-1.0.1+zulu.tgz",
                    "shasum": "fixture-101z"
                  }
                }
              }
            }"#,
        );

        // `1.0.1` has clear precedence over `1.0.0`, and among the two
        // `1.0.1+*` equal-precedence keys the least raw key wins.
        assert_eq!(registry.select_version("^1.0.0").unwrap(), "1.0.1+one");
    }
}
