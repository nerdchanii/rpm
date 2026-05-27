use serde::{Deserialize, Serialize};
use serde_json::{from_str, to_writer_pretty};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{BufWriter, Error, ErrorKind},
    path::Path,
};

#[derive(Debug, Deserialize, Serialize)]
pub struct VersionString(String);

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

#[derive(Debug, Serialize, Deserialize, Default)]
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
    pub fn read_file(file: &str) -> std::io::Result<Self> {
        Self::read_from_path(file)
    }

    pub fn read_from_path<P: AsRef<Path>>(path: P) -> std::io::Result<Self> {
        let path = path.as_ref();
        let text = read_manifest_text(path)?;
        from_str(&text).map_err(|error| {
            Error::new(
                ErrorKind::InvalidData,
                format!(
                    "failed to parse package manifest {}: {error}",
                    path.display()
                ),
            )
        })
    }

    pub fn read_default() -> std::io::Result<Self> {
        Self::read_from_path("./package.json")
    }

    pub fn get_name(&self) -> String {
        self.name.clone().unwrap_or_default()
    }

    pub fn get_version(&self) -> String {
        self.version
            .as_ref()
            .map(|version| version.0.clone())
            .unwrap_or_default()
    }

    pub fn get_bin(&self) -> Option<HashMap<String, String>> {
        self.bin.as_ref().map(|bin| bin.to_owned())
    }

    pub fn save(&self) -> std::io::Result<()> {
        self.save_to_path("./package.json")
    }

    pub fn save_to_path<P: AsRef<Path>>(&self, path: P) -> std::io::Result<()> {
        let path = path.as_ref();
        let package_json_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|error| {
                Error::new(
                    error.kind(),
                    format!(
                        "failed to open package manifest {}: {error}",
                        path.display()
                    ),
                )
            })?;

        let writer = &mut BufWriter::new(package_json_file);
        to_writer_pretty(writer, self).map_err(|error| {
            Error::other(format!(
                "failed to write package manifest {}: {error}",
                path.display()
            ))
        })
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
            deps.push((key.to_owned(), version.0.to_owned()))
        }
        deps
    }

    pub fn get_dev_dependencies(&self) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        if let Some(dev_deps) = &self.dev_dependecies {
            for (key, version) in dev_deps {
                deps.push((key.to_owned(), version.0.to_owned()))
            }
        }
        deps
    }

    pub fn get_scripts(&self) -> HashMap<String, String> {
        self.scripts.clone().unwrap_or_default()
    }
}

fn read_manifest_text(path: &Path) -> std::io::Result<String> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok("{}".to_string()),
        Err(error) => Err(Error::new(
            error.kind(),
            format!(
                "failed to read package manifest {}: {error}",
                path.display()
            ),
        )),
    }
}

#[cfg(test)]
mod package_json_test {

    use super::PackageManifest;
    use crate::util::test_support::{fixture_path, TempProject};

    #[test]
    fn read_file_uses_fixture_data() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-fields.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        let dependencies = package.get_dependencies();
        let dev_dependencies = package.get_dev_dependencies();
        let scripts = package.get_scripts();

        assert_eq!(package.name.as_deref(), Some("fixture-app"));
        assert_eq!(package.get_name(), "fixture-app");
        assert_eq!(package.get_version(), "0.1.0");
        assert!(dependencies.contains(&("react".to_owned(), "^18.2.0".to_owned())));
        assert!(dependencies.contains(&("vite".to_owned(), "~5.2.0".to_owned())));
        assert!(dev_dependencies.contains(&("typescript".to_owned(), "^5.4.0".to_owned())));
        assert_eq!(scripts.get("test").map(String::as_str), Some("cargo test"));
    }

    #[test]
    fn read_file_handles_missing_optional_fields() {
        let fixture = fixture_path(&["package_manifest", "manifest-minimal.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        assert_eq!(package.name.as_deref(), Some("minimal-app"));
        assert!(package.get_dependencies().is_empty());
        assert!(package.get_dev_dependencies().is_empty());
        assert!(package.get_scripts().is_empty());
    }

    #[test]
    fn read_from_path_reports_invalid_manifest_with_path() {
        let fixture = fixture_path(&["package_manifest", "manifest-invalid.json"]);
        let error = PackageManifest::read_from_path(&fixture).unwrap_err();

        assert!(error
            .to_string()
            .contains("failed to parse package manifest"));
        assert!(error.to_string().contains("manifest-invalid.json"));
    }

    #[test]
    fn read_from_path_uses_empty_manifest_for_missing_file() {
        let temp_project = TempProject::new("package-manifest-missing").unwrap();
        let missing_manifest = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-minimal.json"]),
                "nested/fixture.json",
            )
            .unwrap()
            .with_file_name("missing-package.json");
        let package = PackageManifest::read_from_path(missing_manifest)
            .expect("missing package.json should initialize an empty manifest");

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

        let mut package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        package.add_dependency("socket-store".to_owned(), "^0.1.0".to_owned());
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        let dependencies = saved.get_dependencies();
        assert!(dependencies.contains(&("socket-store".to_owned(), "^0.1.0".to_owned())));
    }
}
