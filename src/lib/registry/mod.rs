use chrono::{DateTime, Utc};
use serde::{de, ser::SerializeMap, Deserialize, Deserializer, Serialize, Serializer};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{Error, ErrorKind, Write},
    path::{Path, PathBuf},
};

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
        self.get_tarball_url().map(|url| {
            //ex https://registry.npmjs.org/axios/-/axios-0.21.1.tgz
            let url = url.replace("https://registry.npmjs.org/", "");
            let url: Vec<&str> = url.split("/-/").collect::<Vec<&str>>();
            // left name, right version
            // if socket-store sotcket-store-0.1.0.tgz
            // to socket-store@0.1.0.tgz
            // if @babel/core core-2.3.1.tgz
            // to @babel/core@2.3.1.tgz

            let tarball_name = format!("{}-{}.tgz", url[0], url[1]);

            tarball_name
        })
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
        let url = self.get_tarball_url().ok_or_else(|| {
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

        save_tarball(&key, &mut bytes_file)
    }
    /// get dependencies from registry
    /// return dependencies vector
    /// example: ["socket-store@0.0.1", "socket.io-client@1.22.3"]
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

fn save_tarball(tarball_name: &str, bytes_file: &mut [u8]) -> Result<(), Error> {
    save_tarball_to_dir(CACHE_DIR, tarball_name, bytes_file)
}

fn save_tarball_to_dir<P: AsRef<Path>>(
    cache_dir: P,
    tarball_name: &str,
    bytes_file: &mut [u8],
) -> Result<(), Error> {
    let file_name = tarball_name.replace("/", "-");

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

    let path: PathBuf = dir.join(format!("{file_name}.tgz"));
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|error| {
            Error::new(
                error.kind(),
                format!("failed to open cached tarball {}: {error}", path.display()),
            )
        })?;
    file.write_all(bytes_file).map_err(|error| {
        Error::new(
            error.kind(),
            format!("failed to write cached tarball {}: {error}", path.display()),
        )
    })?;
    file.flush().map_err(|error| {
        Error::new(
            error.kind(),
            format!("failed to flush cached tarball {}: {error}", path.display()),
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::save_tarball_to_dir;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

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
}
