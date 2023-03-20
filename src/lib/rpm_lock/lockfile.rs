use super::constraint::LOCK_FILE_PATH;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::{Read, Result, Write},
};
use toml::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dependency {
    version: String,
    dependencies: Option<Vec<String>>,
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
                let mut dependencies = Vec::new();
                let mut dep_version = String::new();
                for (key, value) in value.as_table().unwrap() {
                    if key == "version" {
                        dep_version = value.as_str().unwrap().to_string();
                    } else if key == "dependencies" {
                        for dep in value.as_array().unwrap() {
                            dependencies.push(dep.as_str().unwrap().to_string());
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

    fn save(&self) -> Result<()> {
        let lockfile = serde_json::to_string(&self)?;
        let mut file = File::create("rpm-lock.toml")?;

        file.write_all(lockfile.as_bytes())?;
        Ok(())
    }

    fn load() -> Result<Self> {
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