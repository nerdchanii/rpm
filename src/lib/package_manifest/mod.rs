use serde::{Deserialize, Serialize};
use serde_json::to_writer_pretty;
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{BufWriter, Error},
    path::Path,
};

#[derive(Debug, Deserialize, Serialize)]
pub struct VersionString(String);

impl VersionString {
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
pub struct PackageManifest {
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scripts: Option<HashMap<String, String>>,
    #[serde(default = "HashMap::new")]
    pub dependencies: HashMap<String, VersionString>,
    #[serde(rename = "devDependencies", skip_serializing_if = "Option::is_none")]
    pub dev_dependecies: Option<HashMap<String, VersionString>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bin: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hompage: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bugs: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contributors: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engines: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub private: Option<String>,
    // other fields implement soon.
}

impl PackageManifest {
    pub fn read_file(file: &str) -> Self {
        let text = match fs::read_to_string(file) {
            Ok(text) => text,
            Err(_) => "{}".to_string(),
        };

        let package: Self = serde_json::from_str(&text).unwrap();
        package
    }

    pub fn get_bin(&self) -> Option<HashMap<String, String>> {
        self.bin.as_ref().map(|bin| bin.to_owned())
    }

    pub fn save(&self) -> core::result::Result<(), ()> {
        self.save_to_path("./package.json").map_err(|_| ())
    }

    pub fn save_to_path<P: AsRef<Path>>(&self, path: P) -> std::io::Result<()> {
        let package_json_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path.as_ref())?;

        let writer = &mut BufWriter::new(package_json_file);
        to_writer_pretty(writer, self).map_err(Error::other)
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

    use super::PackageManifest;
    use crate::util::test_support::{fixture_path, TempProject};

    #[test]
    fn read_file_uses_fixture_data() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-fields.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap());

        let dependencies = package.get_dependencies();
        let dev_dependencies = package.get_dev_dependencies();
        let scripts = package.get_scripts();

        assert_eq!(package.name.as_deref(), Some("fixture-app"));
        assert!(dependencies.contains(&("react".to_owned(), "18.2.0".to_owned())));
        assert!(dependencies.contains(&("vite".to_owned(), "5.2.0".to_owned())));
        assert!(dev_dependencies.contains(&("typescript".to_owned(), "5.4.0".to_owned())));
        assert_eq!(scripts.get("test").map(String::as_str), Some("cargo test"));
    }

    #[test]
    fn read_file_handles_missing_optional_fields() {
        let fixture = fixture_path(&["package_manifest", "manifest-minimal.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap());

        assert_eq!(package.name.as_deref(), Some("minimal-app"));
        assert!(package.get_dependencies().is_empty());
        assert!(package.get_dev_dependencies().is_empty());
        assert!(package.get_scripts().is_empty());
    }

    #[test]
    fn save_writes_only_to_temp_fixture_copy() {
        let temp_project = TempProject::new("package-manifest").unwrap();
        let temp_manifest_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-with-fields.json"]),
                "package.json",
            )
            .unwrap();

        let mut package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap());
        package.add_dependency("socket-store".to_owned(), "^0.1.0".to_owned());
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap());
        let dependencies = saved.get_dependencies();
        assert!(dependencies.contains(&("socket-store".to_owned(), "0.1.0".to_owned())));
    }
}
