use chrono::{DateTime, Utc};
use serde::{ser::SerializeMap, Deserialize, Deserializer, Serialize, Serializer};
use std::{
    collections::HashMap,
    fs::OpenOptions,
    io::{Error, Write},
    time::Instant,
};

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
pub struct Repository {
    #[serde(rename = "type")]
    type_: String,
    url: String,
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
    pub integrity: String,
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
    name: String,
    email: String,
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
    name: String,
    email: String,
    url: Option<String>,
}
impl Author {
    fn new(name: String, email: String, url: Option<String>) -> Self {
        Self { name, email, url }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Bugs {
    url: Url,
}

/// Registry struct
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
    pub homepage: Url,
    pub keywords: Vec<String>,
    pub repository: Repository,
    pub author: Option<Author>,
    pub bugs: Bugs,
    pub license: String,
    pub readme: Option<String>,
    #[serde(rename = "readmeFilename")]
    pub readme_file_name: Option<String>,
    pub dist: Option<Dist>,
    sequence: Option<i32>,
}

impl Registry {
    pub fn get_tarball(&self) -> Option<String> {
        if self.versions.is_some() && self.rev.is_some() {
            let version = &self.versions.as_ref().unwrap();
            let lastest = &self.rev.as_ref().unwrap();
            let tarball = version.get(lastest.to_owned()).unwrap().get_tarball();
            Some(tarball)
        } else {
            None
        }
    }

    pub async fn download_tarball(&self) -> Result<Option<String>, reqwest::Error> {
        if self.versions.is_some() && self.dist_tags.is_some() {
            let version = &self.versions.as_ref().unwrap();
            let lastest = &self.dist_tags.as_ref().unwrap().get_latest();
            // println!("{:?}", lastest);
            // println!("{:?}", version);

            let tarball = version
                .get(&lastest.unwrap().to_owned())
                .unwrap()
                .get_tarball();
            let start = Instant::now();
            println!("install from {:?}", tarball);
            let response = reqwest::get(&tarball).await?.bytes().await;
            let tarball_name = tarball.split("/").last().unwrap();
            // let tarball_name = format!("{}.tgz", self.name);
            match response {
                Ok(response) => {
                    // println!("downloaded: {:?}", tarball_name);
                    let save_result = save_tarball(tarball_name.to_owned(), &mut response.to_vec());
                    match save_result {
                        Ok(_) => {
                            println!(
                                "added: {:?} {}ms",
                                tarball_name,
                                start.elapsed().as_millis()
                            );
                            Ok(Some(tarball_name.to_owned()))
                        }
                        Err(_) => Ok(None),
                    }
                }
                Err(_) => Ok(None),
            }
        } else {
            if self.dist.as_ref().unwrap().get_tarball().is_empty() {
                Ok(None)
            } else {
                let tarball = self.dist.as_ref().unwrap().get_tarball();
                println!("{:?}", tarball);
                let response = reqwest::get(&tarball).await?.bytes().await;

                match response {
                    Ok(response) => {
                        // regex for get tarball name from url;
                        let tarball_name = tarball.split("/").last().unwrap();
                        println!("{:?}", tarball_name);
                        let save_result =
                            save_tarball(tarball_name.to_owned(), &mut response.to_vec());
                        match save_result {
                            Ok(_) => Ok(Some(tarball_name.to_owned())),
                            Err(_) => Ok(None),
                        }
                    }
                    Err(_) => Ok(None),
                }
            }
        }
    }
}

fn save_tarball(tarball_name: String, tarball: &mut [u8]) -> Result<(), Error> {
    let base_path = "rpm/.cache";
    let file_path = format!("{}/{}", base_path, tarball_name);
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .open(file_path)?;
    file.write_all(tarball)?;
    file.flush()?;
    Ok(())
}
