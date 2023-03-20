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
pub struct Package {
    pub name: String,
    pub version: VersionString,
    // main type will be changed PathString
    pub main: String,
    pub author: String,
    // will be changed License Enum
    pub license: String,
    pub scripts: Option<HashMap<String, String>>,
    #[serde(default = "HashMap::new")]
    pub dependencies: HashMap<String, VersionString>,
    #[serde(rename = "devDependencies", skip_serializing_if = "Option::is_none")]
    pub dev_dependecies: Option<HashMap<String, VersionString>>,
    // other fields implement soon.
}

impl Package {
    fn new() -> Package {
        let text = fs::read_to_string("./package.json").unwrap_or("".to_owned());
        let package: Package = serde_json::from_str(&text).unwrap();
        package
    }

    pub fn read_file() -> Self {
        let text = fs::read_to_string("./package.json").unwrap_or("".to_owned());
        let package: Self = serde_json::from_str(&text).unwrap();
        package
    }

    fn save(&self) -> core::result::Result<(), ()> {
        let package_json_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(Path::new("./package.json"))
            .unwrap();

        // save serialized $self to package.json
        if let Ok(ser) = serde_json::to_value(self) {
            let writer = &mut BufWriter::new(package_json_file);
            println!("{}", &ser);
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

    fn add_dependecy(&mut self, pkg_name: String, version: VersionString) {
        self.dependencies.insert(pkg_name, version);
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
    use crate::packge_json::VersionString;

    use super::Package;
    use serde_json::{self, Value};
    use std::fs::{self, File};

    #[test]
    fn read_file() {
        // let p = OpenOptions::new().read(true).open("./package.json");
        let text = fs::read_to_string("./package.json").unwrap();
        let mut package: Package = serde_json::from_str(&text).unwrap();
        println!("{:?}\n\n\n", package);
        package.add_dependecy(
            "socket-store".to_owned(),
            VersionString::new("^0.1.0".to_owned()),
        );

        package.save();
        println!("{:?}", package);
    }
}
