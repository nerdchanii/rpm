use super::constraint::LOCK_FILE_PATH;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::OpenOptions,
    io::{Read, Result, Write},
};
use toml::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dependency {
    version: String,
    dependencies: Option<HashSet<String>>,
}

impl Dependency {
    pub fn new(version: String, dependencies: Option<HashSet<String>>) -> Self {
        Self {
            version,
            dependencies,
        }
    }

    pub fn get_version(&self) -> String {
        self.version.clone()
    }

    pub fn get_dependencies_name(&self) -> HashSet<String> {
        let regex = Regex::new(r"^(?P<package_name>@?[^@]*)(@\^?(?P<version>.*))?$").unwrap();
        let mut dependencies = HashSet::new();
        if let Some(deps) = &self.dependencies {
            for dep in deps.iter() {
                let pkg_name = regex.captures(&dep).unwrap();
                let name = pkg_name.name("package_name").map(|m| m.as_str()).unwrap();
                dependencies.insert(name.to_string());
            }
        }
        dependencies
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct LockFile {
    name: String,
    version: String,
    #[serde(flatten)]
    dependencies: HashMap<String, Dependency>,
}

impl<'de> Deserialize<'de> for LockFile {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        let mut name = String::new();
        let mut version = String::new();
        let mut deps = HashMap::new();
        for (key, value) in value.as_table().unwrap() {
            if key == "name" {
                name = value.as_str().unwrap().to_string();
            } else if key == "version" {
                version = value.as_str().unwrap().to_string();
            } else {
                let mut dependencies = HashSet::new();
                let mut dep_version = String::new();
                for (key, value) in value.as_table().unwrap() {
                    if key == "version" {
                        dep_version = value.as_str().unwrap().to_string();
                    } else if key == "dependencies" {
                        for dep in value.as_array().unwrap() {
                            dependencies.insert(dep.as_str().unwrap().to_string());
                        }
                    }
                }
                deps.insert(
                    key.to_string(),
                    Dependency {
                        version: dep_version,
                        dependencies: Some(dependencies),
                    },
                );
            }
        }

        Ok(Self {
            name,
            version,
            dependencies: deps,
        })
    }
}

impl LockFile {
    fn new(name: String, version: String, dependencies: HashMap<String, Dependency>) -> Self {
        Self {
            name,
            version,
            dependencies,
        }
    }

    // fn save(&self) -> Result<()> {
    //     let lockfile = serde_json::to_string(&self)?;
    //     let mut file = File::create("rpm-lock.toml")?;

    //     file.write_all(lockfile.as_bytes())?;
    //     Ok(())
    // }

    pub fn load() -> Result<Self> {
        let mut buffer = String::new();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(LOCK_FILE_PATH)?;
        file.read_to_string(&mut buffer)?;
        let lock: Self = toml::from_str(&buffer).unwrap();

        Ok(lock)
    }

    pub fn get_packages(&self) -> Vec<(&String, &Dependency)> {
        self.dependencies.iter().collect::<Vec<_>>()
    }

    pub fn add_dependency(
        &mut self,
        name: &String,
        version: String,
        dependencies: &mut Vec<String>,
    ) {
        if let Some(dep) = self.dependencies.get_mut(name) {
            dep.version = version;
            dependencies.iter().for_each(|value| {
                dep.dependencies.as_mut().unwrap().insert(value.clone());
            });
        } else {
            self.dependencies.insert(
                name.clone(),
                Dependency {
                    version,
                    dependencies: Some(HashSet::from_iter(dependencies.iter().cloned())),
                },
            );
        }
    }

    pub fn save(&self) -> Result<()> {
        let lockfile = toml::to_string(&self).unwrap();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(LOCK_FILE_PATH)?;

        // file initial
        file.set_len(0)?;

        // file write
        match file.write_all(lockfile.as_bytes()) {
            Ok(_) => Ok(()),
            Err(e) => {
                println!("error: {:?}", e);
                return Err(e);
            }
        }
    }

    pub fn get_dependency(&self, name: &str) -> Option<&Dependency> {
        self.dependencies.get(name)
    }
}

#[cfg(test)]
mod lock_file_test {
    use sha2::digest::typenum::IsEqual;

    use super::*;

    #[test]
    fn test_lock_file() {
        let lock = LockFile::load().unwrap();
        println!("{:?\n}", lock.name);
        println!("{:?\n}", lock.version);
        lock.dependencies
            .iter()
            .map(|(k, v)| {
                println!("key: {:?}", k);
                println!("version: {:?}", v.version);
                println!("deps: {:?}\n\n", v.dependencies.as_ref().unwrap());
                ()
            })
            .collect::<()>();
    }
}
