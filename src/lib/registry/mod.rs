use chrono::{DateTime, Utc};
use serde::{ser::SerializeMap, Deserialize, Deserializer, Serialize, Serializer};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{Error, Write},
    path::Path,
};

use crate::{api, common::constraint::CACHE_DIR};

#[derive(Debug, Serialize, Deserialize)]
struct DistTags {
    #[serde(flatten)]
    inner: HashMap<String, String>,
}
impl DistTags {
    fn new() -> Self {
        Self {
            inner: HashMap::new(),
        }
    }

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

    fn get_shasum(&self) -> String {
        self.shasum.clone()
    }

    fn verify(&self) -> bool {
        true
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
            .unwrap_or(vec![])
    }
}

#[derive(Debug)]
pub struct Time {
    created: DateTime<Utc>,
    modified: DateTime<Utc>,
    versions: HashMap<String, DateTime<Utc>>,
}

impl Time {
    fn new(created: String, modified: String) -> Self {
        Self {
            created: created.parse::<DateTime<Utc>>().unwrap(),
            modified: modified.parse::<DateTime<Utc>>().unwrap(),
            versions: HashMap::new(),
        }
    }

    fn set(&mut self, version: String, time: String) {
        let time = DateTime::parse_from_str(&time, "%YYYY-%MM-%DDT%HH:%MM:%SS.%fZ")
            .unwrap()
            .into();
        self.versions.insert(version, time);
    }
}

impl<'de> Deserialize<'de> for Time {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let map = HashMap::<String, String>::deserialize(deserializer)?;
        Ok(Self::new(
            map.get("created").unwrap().to_string(),
            map.get("modified").unwrap().to_string(),
        ))
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
impl Url {
    fn new(url: String) -> Self {
        Self(url)
    }

    fn get(&self) -> String {
        self.0.clone()
    }

    fn set(&mut self, url: String) {
        self.0 = url;
    }
}

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

impl Author {
    fn new(name: Option<String>, email: Option<String>, url: Option<String>) -> Self {
        Self { name, email, url }
    }
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
        if self.versions.is_some() && self.dist_tags.is_some() {
            let version = &self.versions.as_ref().unwrap();
            let lastest = &self.dist_tags.as_ref().unwrap().get_latest().unwrap();
            let url = version.get(lastest.to_owned()).unwrap().get_tarball();
            Some(url)
        } else {
            let tarball = &self.dist.as_ref().unwrap().get_tarball();
            Some(tarball.to_owned())
        }
    }

    /// download tarball from registry and return tarball bytes

    pub async fn download_tarball(&self, key: &str, version: &str) -> Result<(), reqwest::Error> {
        let url = &self.get_tarball_url().unwrap();
        let response = api::get_tarball(url).await;
        let key = if key.contains("*") {
            key.replace("*", version)
        } else {
            key.to_owned()
        };

        response
            .ok()
            .map(|mut bytes_file| save_tarball(&key, &mut bytes_file));

        Ok(())
    }
    /// get dependencies from registry
    /// return dependencies vector
    /// example: ["socket-store@0.0.1", "socket.io-client@1.22.3"]
    pub fn get_dependencies(&self) -> Vec<String> {
        // if versions is "" then version to latest
        if self.versions.is_some() && self.dist_tags.is_some() {
            let lastests = &self.dist_tags.as_ref().unwrap().get_latest().unwrap();
            let version = self
                .versions
                .as_ref()
                .unwrap()
                .get(lastests.to_owned())
                .unwrap();
            let dependencies = version.get_dependencies();

            dependencies
        } else {
            self.dependencies
                .as_ref()
                .iter()
                .flat_map(|x| x.iter())
                .map(|(k, v)| format!("{}@{}", k, v))
                .collect()
        }
    }

    pub fn get_latest_version(&self) -> Option<&String> {
        if self.version.is_some() {
            self.version.as_ref()
        } else {
            self.dist_tags.as_ref().unwrap().get_latest()
        }
    }
}

fn save_tarball(tarball_name: &str, bytes_file: &mut [u8]) -> Result<(), Error> {
    let base_path = CACHE_DIR;
    let file_name = tarball_name.replace("/", "-");

    let dir = Path::new(base_path);

    if !dir.exists() {
        fs::create_dir_all(dir)?;
    }

    let mut file = OpenOptions::new().write(true).create(true).open(format!(
        "{}/{}.tgz",
        dir.to_str().unwrap(),
        file_name
    ))?;
    file.write_all(bytes_file)?;
    file.flush()?;
    Ok(())
}
