use serde::{Deserialize, Serialize};
use serde_json::to_writer_pretty;
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::BufWriter,
    path::Path,
};

#[derive(Debug, Deserialize, Serialize)]
pub struct VersionString(String);

impl VersionString {
    fn new(version: String) -> VersionString {
        VersionString(version)
    }

    fn to_string(&self) -> String {
        self.0.to_owned()
    }

    fn to_owned(&self) -> VersionString {
        VersionString(self.0.to_owned())
    }

    fn to_str(&self) -> &str {
        &self.0
    }

    fn to_specific_version(&self) -> String {
        let mut version = self.0.to_owned();
        if version.contains("||") {
            version = version
                .split("||")
                .collect::<Vec<&str>>()
                .last_mut()
                .unwrap()
                .trim()
                .to_owned();
        }
        if version.starts_with("^") {
            version = version.replace("^", "");
        }
        if version.starts_with("~") {
            version = version.replace("~", "");
        }
        version
    }
}

#[derive(Debug, Serialize, Deserialize)]

pub struct Author {
    name: String,
    email: String,
    url: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]

pub enum AuthorType {
    String(String),
    Object(Author),
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Package {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<VersionString>,
    // main type will be changed PathString
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    pub scripts: Option<HashMap<String, String>>,
    #[serde(default = "HashMap::new")]
    pub dependencies: HashMap<String, VersionString>,
    #[serde(rename = "devDependencies", skip_serializing_if = "Option::is_none")]
    pub dev_dependecies: Option<HashMap<String, VersionString>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bin: Option<HashMap<String, String>>,
    // other fields implement soon.
}

impl Package {
    fn new() -> Package {
        let text = fs::read_to_string("./package.json").unwrap_or("".to_owned());
        let package: Package = serde_json::from_str(&text).unwrap();
        package
    }

    pub fn read_file(file: &str) -> Self {
        let text = fs::read_to_string(file).unwrap_or("".to_owned());
        let package: Self = serde_json::from_str(&text).unwrap();
        package
    }

    pub fn get_bin(&self) -> Option<HashMap<String, String>> {
        self.bin.as_ref().map(|bin| bin.to_owned())
    }

    pub fn save(&self) -> core::result::Result<(), ()> {
        let package_json_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(Path::new("./package.json"))
            .unwrap();

        // save serialized $self to package.json
        if let Ok(ser) = serde_json::to_value(self) {
            let writer = &mut BufWriter::new(package_json_file);

            let result = to_writer_pretty(writer, &ser);
            if result.is_ok() {
                Ok(())
            } else {
                Ok(())
            }
        } else {
            panic!("error");
        }
    }

    pub fn add_dependency(&mut self, pkg_name: String, version: String) {
        print!("add dependency: {} {}", pkg_name, version);
        print!("\r\x1B[K");
        self.dependencies.insert(pkg_name, VersionString(version));
    }

    pub fn add_dev_dependency(&mut self, pkg_name: String, version: String) {
        if let Some(dev_deps) = &mut self.dev_dependecies {
            dev_deps.insert(pkg_name, VersionString(version));
        } else {
            let mut dev_deps = HashMap::new();
            dev_deps.insert(pkg_name, VersionString(version));
            self.dev_dependecies = Some(dev_deps);
        }
    }

    pub fn get_dependencies(&self) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        for (key, version) in &self.dependencies {
            deps.push((key.to_owned(), version.to_specific_version()))
        }
        deps
    }

    pub fn get_dev_dependencies(&self) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        if let Some(dev_deps) = &self.dev_dependecies {
            for (key, version) in dev_deps {
                deps.push((key.to_owned(), version.to_specific_version()))
            }
        }
        deps
    }

    pub fn get_scripts(&self) -> HashMap<String, String> {
        self.scripts.clone().unwrap_or(HashMap::new())
    }
}

#[cfg(test)]
mod package_json_test {

    use super::Package;
    use serde_json;
    use std::fs;

    #[test]
    fn read_file() {
        // let p = OpenOptions::new().read(true).open("./package.json");
        let text = fs::read_to_string("./package.json").unwrap();
        let mut package: Package = serde_json::from_str(&text).unwrap();
        println!("{:?}\n\n\n", package);
        package.add_dependency("socket-store".to_owned(), "^0.1.0".to_owned());

        package.save();
    }
}
