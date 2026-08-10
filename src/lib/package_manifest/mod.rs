use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{from_str, to_writer_pretty};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{BufWriter, Error, ErrorKind},
    path::Path,
};

/// `package.json` `bin` field, accepting both npm-defined forms:
/// string form (`"bin": "./cli.js"`) and object form
/// (`"bin": { "<name>": "<target>" }`). The binary name for the string form is
/// resolved by the linker from the package `name`, not at parse time; see
/// `docs/specs/core/manifest/SPEC.md` and `docs/specs/core/linker/SPEC.md`.
///
/// A present-but-wrong-type value (for example a number or an array) is
/// discarded as absent during deserialization rather than failing the manifest,
/// mirroring the lenient handling used for other preserved fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum BinField {
    String(String),
    Object(HashMap<String, String>),
}

impl BinField {
    /// Returns the object-form map by value, or `None` for the string form.
    /// The linker resolves the string form into a single entry keyed by the
    /// package name; that resolution cannot happen at the manifest boundary
    /// because the manifest parser does not know which package name to use.
    pub fn into_object(self) -> Option<HashMap<String, String>> {
        match self {
            BinField::Object(map) => Some(map),
            BinField::String(_) => None,
        }
    }

    /// Returns the string-form target by reference, or `None` for the object
    /// form.
    pub fn as_string(&self) -> Option<&str> {
        match self {
            BinField::String(target) => Some(target),
            BinField::Object(_) => None,
        }
    }
}

fn deserialize_bin_field<'de, D>(deserializer: D) -> Result<Option<BinField>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    if value.is_null() {
        return Ok(None);
    }
    match BinField::deserialize(value) {
        Ok(parsed) => Ok(Some(parsed)),
        Err(_) => Ok(None),
    }
}

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
    // Read and preserved only; not enqueued as dependency requests until an
    // optional-aware strategy owns resolve/install/skip behavior. See
    // docs/specs/core/manifest/SPEC.md.
    #[serde(
        rename = "optionalDependencies",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub optional_dependencies: Option<HashMap<String, VersionString>>,
    // Read and preserved only; not enqueued as ordinary dependency requests
    // until a peer-aware strategy owns peer-requirement resolution and
    // diagnostics. See docs/specs/core/manifest/SPEC.md.
    #[serde(
        rename = "peerDependencies",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub peer_dependencies: Option<HashMap<String, VersionString>>,
    #[serde(
        default,
        deserialize_with = "deserialize_bin_field",
        skip_serializing_if = "Option::is_none"
    )]
    pub bin: Option<BinField>,
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
    // Read and preserved only; not consumed for platform gating until a
    // platform-gating strategy owns filter/warn/skip/fail behavior. The field
    // types follow npm's schema (`engines` as a map, `os`/`cpu` as arrays) so a
    // real npm-shaped manifest parses instead of failing deserialization. See
    // docs/specs/core/manifest/SPEC.md.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engines: Option<HashMap<String, VersionString>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu: Option<Vec<String>>,
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

    /// Returns the raw `bin` field, preserving string-form vs object-form
    /// distinction. The linker resolves the string form into a binary name
    /// derived from the package name; the manifest boundary returns the raw
    /// value rather than guessing the package name. Returns `None` when the
    /// field is absent or was discarded as a wrong-type value.
    pub fn get_bin(&self) -> Option<&BinField> {
        self.bin.as_ref()
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

    pub fn get_optional_dependencies(&self) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        if let Some(optional_deps) = &self.optional_dependencies {
            for (key, version) in optional_deps {
                deps.push((key.to_owned(), version.0.to_owned()))
            }
        }
        deps
    }

    /// Preserved `peerDependencies` map (package name to range). Read-only: RPM
    /// does not enqueue peer dependencies as ordinary dependencies today.
    pub fn get_peer_dependencies(&self) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        if let Some(peer_deps) = &self.peer_dependencies {
            for (key, version) in peer_deps {
                deps.push((key.to_owned(), version.0.to_owned()))
            }
        }
        deps
    }

    /// Preserved `engines` map (engine name to range, for example
    /// `node -> >=14`). Read-only: RPM does not perform engine filtering today.
    pub fn get_engines(&self) -> Vec<(String, String)> {
        let mut engines = Vec::new();
        if let Some(map) = &self.engines {
            for (key, version) in map {
                engines.push((key.to_owned(), version.0.to_owned()))
            }
        }
        engines
    }

    /// Preserved `os` allowlist/denylist (entries may be negated, for example
    /// `!win32`). Read-only: RPM does not perform OS filtering today.
    pub fn get_os(&self) -> Vec<String> {
        self.os.clone().unwrap_or_default()
    }

    /// Preserved `cpu` allowlist/denylist (entries may be negated, for example
    /// `!arm64`). Read-only: RPM does not perform CPU filtering today.
    pub fn get_cpu(&self) -> Vec<String> {
        self.cpu.clone().unwrap_or_default()
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
    fn read_file_preserves_bin_string_form() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-bin-string.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        // String-form `bin` is preserved verbatim. The linker resolves the
        // binary name from the package name; the manifest boundary does not.
        let bin = package
            .get_bin()
            .expect("string-form bin must be preserved");
        assert_eq!(bin.as_string(), Some("./cli.js"));
        assert_eq!(bin.clone().into_object(), None);
    }

    #[test]
    fn read_file_preserves_bin_object_form() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-bin-object.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        let bin = package
            .get_bin()
            .expect("object-form bin must be preserved");
        let map = bin
            .clone()
            .into_object()
            .expect("object-form bin must expose a map");
        assert_eq!(map.get("my-cli").map(String::as_str), Some("./cli.js"));
        assert_eq!(
            map.get("helper").map(String::as_str),
            Some("./bin/helper.js")
        );
    }

    #[test]
    fn read_file_discards_wrong_type_bin_as_absent() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-bin-wrong-type.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        // A present-but-wrong-type `bin` value is discarded as absent rather
        // than failing the manifest, mirroring other preserved fields.
        assert_eq!(package.name.as_deref(), Some("wrong-type-bin-app"));
        assert_eq!(package.get_bin(), None);
    }

    #[test]
    fn bin_field_round_trips_through_save() {
        let temp_project = TempProject::new("package-manifest-bin-round-trip").unwrap();
        let temp_manifest_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-with-bin-object.json"]),
                "package.json",
            )
            .unwrap();

        let package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        let map = saved
            .get_bin()
            .expect("bin must survive round-trip")
            .clone()
            .into_object()
            .expect("object-form bin must survive round-trip");
        assert_eq!(map.get("my-cli").map(String::as_str), Some("./cli.js"));
        assert_eq!(
            map.get("helper").map(String::as_str),
            Some("./bin/helper.js")
        );
    }

    #[test]
    fn read_file_preserves_optional_dependencies() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-optional-deps.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        let optional_dependencies = package.get_optional_dependencies();
        assert_eq!(package.name.as_deref(), Some("optional-app"));
        assert!(optional_dependencies.contains(&("fsevents".to_owned(), "^2.3.3".to_owned())));
        // Optional deps are preserved but must not leak into ordinary deps.
        assert!(!package
            .get_dependencies()
            .contains(&("fsevents".to_owned(), "^2.3.3".to_owned())));
    }

    #[test]
    fn optional_dependencies_round_trip_through_save() {
        let temp_project = TempProject::new("package-manifest-optional").unwrap();
        let temp_manifest_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-with-optional-deps.json"]),
                "package.json",
            )
            .unwrap();

        let package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        let optional_dependencies = saved.get_optional_dependencies();
        assert!(optional_dependencies.contains(&("fsevents".to_owned(), "^2.3.3".to_owned())));
    }

    #[test]
    fn read_file_preserves_peer_dependencies() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-peer-deps.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        let peer_dependencies = package.get_peer_dependencies();
        assert_eq!(package.name.as_deref(), Some("peer-app"));
        assert!(peer_dependencies.contains(&("react".to_owned(), "^18.0.0".to_owned())));
        // Peer deps are preserved but must not leak into ordinary deps.
        assert!(!package
            .get_dependencies()
            .contains(&("react".to_owned(), "^18.0.0".to_owned())));
    }

    #[test]
    fn peer_dependencies_round_trip_through_save() {
        let temp_project = TempProject::new("package-manifest-peer").unwrap();
        let temp_manifest_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-with-peer-deps.json"]),
                "package.json",
            )
            .unwrap();

        let package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        let peer_dependencies = saved.get_peer_dependencies();
        assert!(peer_dependencies.contains(&("react".to_owned(), "^18.0.0".to_owned())));
    }

    #[test]
    fn read_file_preserves_engines_os_and_cpu() {
        let fixture = fixture_path(&["package_manifest", "manifest-with-engines-os-cpu.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        // Preserved with npm-accurate types, but not consumed by install today.
        let engines = package.get_engines();
        assert_eq!(package.name.as_deref(), Some("platform-app"));
        assert!(engines.contains(&("node".to_owned(), ">=14.0.0".to_owned())));
        assert_eq!(
            package.get_os(),
            vec!["linux".to_owned(), "darwin".to_owned(), "!win32".to_owned()]
        );
        assert_eq!(
            package.get_cpu(),
            vec!["x64".to_owned(), "arm64".to_owned(), "!ia32".to_owned()]
        );
        // Platform metadata must not leak into ordinary dependency edges.
        assert!(!package
            .get_dependencies()
            .contains(&("node".to_owned(), ">=14.0.0".to_owned())));
    }

    #[test]
    fn engines_os_and_cpu_round_trip_through_save() {
        let temp_project = TempProject::new("package-manifest-platform").unwrap();
        let temp_manifest_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-with-engines-os-cpu.json"]),
                "package.json",
            )
            .unwrap();

        let package = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        package.save_to_path(&temp_manifest_path).unwrap();

        let saved = PackageManifest::read_file(temp_manifest_path.to_str().unwrap()).unwrap();
        assert!(saved
            .get_engines()
            .contains(&("node".to_owned(), ">=14.0.0".to_owned())));
        assert_eq!(
            saved.get_os(),
            vec!["linux".to_owned(), "darwin".to_owned(), "!win32".to_owned()]
        );
        assert_eq!(
            saved.get_cpu(),
            vec!["x64".to_owned(), "arm64".to_owned(), "!ia32".to_owned()]
        );
    }

    #[test]
    fn read_file_handles_missing_optional_fields() {
        let fixture = fixture_path(&["package_manifest", "manifest-minimal.json"]);
        let package = PackageManifest::read_file(fixture.to_str().unwrap()).unwrap();

        assert_eq!(package.name.as_deref(), Some("minimal-app"));
        assert!(package.get_dependencies().is_empty());
        assert!(package.get_dev_dependencies().is_empty());
        assert!(package.get_peer_dependencies().is_empty());
        assert!(package.get_engines().is_empty());
        assert!(package.get_os().is_empty());
        assert!(package.get_cpu().is_empty());
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

    #[test]
    fn accessors_return_defaults_for_empty_manifest() {
        let package = PackageManifest::default();

        assert_eq!(package.get_name(), "");
        assert_eq!(package.get_version(), "");
        assert_eq!(package.get_bin(), None);
        assert!(package.get_dependencies().is_empty());
        assert!(package.get_dev_dependencies().is_empty());
        assert!(package.get_optional_dependencies().is_empty());
        assert!(package.get_peer_dependencies().is_empty());
        assert!(package.get_engines().is_empty());
        assert!(package.get_os().is_empty());
        assert!(package.get_cpu().is_empty());
        assert!(package.get_scripts().is_empty());
    }

    #[test]
    fn dependency_mutators_create_and_extend_dependency_sets() {
        let mut package = PackageManifest::default();

        package.add_dependency("left-pad".to_owned(), "^1.0.0".to_owned());
        package.add_dev_dependency("typescript".to_owned(), "^5.0.0".to_owned());
        package.add_dev_dependency("vitest".to_owned(), "^2.0.0".to_owned());

        assert_eq!(
            package.get_dependencies(),
            vec![("left-pad".to_owned(), "^1.0.0".to_owned())]
        );
        let dev_dependencies = package.get_dev_dependencies();
        assert!(dev_dependencies.contains(&("typescript".to_owned(), "^5.0.0".to_owned())));
        assert!(dev_dependencies.contains(&("vitest".to_owned(), "^2.0.0".to_owned())));
    }

    #[test]
    fn save_to_path_reports_open_errors_with_manifest_path() {
        let temp_project = TempProject::new("package-manifest-save-error").unwrap();
        let directory_path = temp_project
            .copy_fixture(
                fixture_path(&["package_manifest", "manifest-minimal.json"]),
                "nested/package.json",
            )
            .unwrap()
            .with_file_name("directory-target");
        std::fs::create_dir_all(&directory_path).unwrap();

        let error = PackageManifest::default()
            .save_to_path(&directory_path)
            .expect_err("saving to a directory should fail");

        assert!(error
            .to_string()
            .contains("failed to open package manifest"));
        assert!(error.to_string().contains("directory-target"));
    }
}
