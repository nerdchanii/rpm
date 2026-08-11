mod constants;

use constants::REGISTRY_PATH;

use crate::registry::Registry;
use std::io::Error;
#[cfg(test)]
use std::{fs, io::ErrorKind, path::PathBuf};

pub async fn get_registry(lib_name: &str, version: &str) -> std::io::Result<Registry> {
    #[cfg(test)]
    if let Some(registry) = read_registry_fixture(lib_name)? {
        test_support::record_metadata_read(lib_name);
        return Ok(registry);
    }

    let request_url = registry_lookup_url(lib_name, version);
    let registry = reqwest::get(&request_url)
        .await
        .map_err(|error| Error::other(format!("failed to fetch registry {request_url}: {error}")))?
        .json::<Registry>()
        .await
        .map_err(|error| {
            Error::other(format!(
                "failed to parse registry response for {lib_name}: {error}"
            ))
        })?;
    Ok(registry)
}

pub async fn get_tarball(tarball_url: &str) -> std::io::Result<Vec<u8>> {
    #[cfg(test)]
    if std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT").is_some() {
        test_support::record_tarball_download(&package_key_from_tarball_url(tarball_url));
        return fixture_tarball(tarball_url);
    }

    let response = reqwest::get(tarball_url)
        .await
        .map_err(|error| Error::other(format!("failed to download {tarball_url}: {error}")))?
        .bytes()
        .await
        .map_err(|error| Error::other(format!("failed to read {tarball_url}: {error}")))?;
    Ok(response.to_vec())
}

pub async fn get_registry_text(lib_name: &str, version: &str) -> std::io::Result<String> {
    let request_url = registry_lookup_url(lib_name, version);
    reqwest::get(&request_url)
        .await
        .map_err(|error| Error::other(format!("failed to fetch registry {request_url}: {error}")))?
        .text()
        .await
        .map_err(|error| Error::other(format!("failed to read registry {request_url}: {error}")))
}

/// Assemble the registry lookup URL for a package name and version segment.
///
/// npm serves a scoped packument at a single path segment, so the scoped name
/// (`@scope/name`) must be percent-encoded with `/` as `%2F` (for example
/// `@babel/core` → `/@babel%2Fcore`). Unscoped names carry no `/` and remain
/// byte-identical. The version segment stays a separate path component. The
/// package identity stays verbatim everywhere else; only this registry lookup
/// path encodes the name (see `docs/specs/core/registry/SPEC.md`).
fn registry_lookup_url(lib_name: &str, version: &str) -> String {
    let encoded_name = lib_name.replace('/', "%2F");
    format!("{}/{encoded_name}/{version}", REGISTRY_PATH)
}

#[cfg(test)]
fn read_registry_fixture(lib_name: &str) -> std::io::Result<Option<Registry>> {
    let Some(root) = std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT") else {
        return Ok(None);
    };
    let file_name = format!("{}.json", lib_name.replace('/', "__"));
    let path = PathBuf::from(root).join(file_name);
    let fixture = fs::read_to_string(&path).map_err(|error| {
        Error::new(
            error.kind(),
            format!(
                "failed to read registry fixture {}: {error}",
                path.display()
            ),
        )
    })?;
    serde_json::from_str(&fixture).map(Some).map_err(|error| {
        Error::new(
            ErrorKind::InvalidData,
            format!(
                "failed to parse registry fixture {}: {error}",
                path.display()
            ),
        )
    })
}

#[cfg(test)]
fn fixture_tarball(tarball_url: &str) -> std::io::Result<Vec<u8>> {
    use flate2::{write::GzEncoder, Compression};
    use std::io::Write;
    use tar::{Builder, Header};

    let package_name = package_name_from_tarball_url(tarball_url)?;
    let spec = read_fixture_tarball_spec(&package_name);
    let package_json = build_fixture_package_json(&package_name, spec.as_ref());
    let extra_files = spec
        .as_ref()
        .map(|spec| spec.files.as_slice())
        .unwrap_or(&[]);

    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut builder = Builder::new(encoder);

    let mut header = Header::new_gnu();
    header.set_size(package_json.len() as u64);
    header.set_cksum();
    builder.append_data(&mut header, "package/package.json", package_json.as_bytes())?;

    // When a fixture tarball spec declares extra files (for example a binary
    // target reachable through a `bin` field), append each one under the
    // `package/` prefix so the install extraction step strips the prefix and
    // lands them at `node_modules/<package>/<file>`, where `link_bins` expects
    // them. A missing spec keeps the legacy minimal archive unchanged.
    for file in extra_files {
        let archive_path = format!("package/{}", file.path);
        let mut header = Header::new_gnu();
        header.set_size(file.contents.len() as u64);
        header.set_mode(file.mode);
        header.set_cksum();
        builder.append_data(&mut header, &archive_path, file.contents.as_bytes())?;
    }

    builder.finish()?;
    let mut encoder = builder.into_inner()?;
    encoder.flush()?;
    encoder.finish()
}

/// Optional fixture-side description of a synthetic tarball's contents.
///
/// The legacy path serves a minimal `package/package.json` with only a `name`
/// field. Specs live at `<fixture-root>/tarballs/<package-name>.json` so a
/// fixture can declare a `bin` field and the binary target files the install
/// pipeline must extract alongside the manifest. Only tests that need `.bin`
/// linking or other non-trivial tarball contents provide a spec; every other
/// fixture stays on the minimal default.
#[cfg(test)]
#[derive(Debug, serde::Deserialize)]
struct FixtureTarballSpec {
    #[serde(default)]
    bin: Option<serde_json::Value>,
    #[serde(default)]
    files: Vec<FixtureTarballFile>,
}

#[cfg(test)]
#[derive(Debug, serde::Deserialize)]
struct FixtureTarballFile {
    path: String,
    contents: String,
    #[serde(default = "default_fixture_file_mode")]
    mode: u32,
}

#[cfg(test)]
fn default_fixture_file_mode() -> u32 {
    0o644
}

/// Read the optional tarball spec for `package_name` from the fixture registry
/// root. Returns `None` when the root is unset or no spec file exists, so the
/// minimal-archive default path stays intact for every fixture that does not
/// opt in.
#[cfg(test)]
fn read_fixture_tarball_spec(package_name: &str) -> Option<FixtureTarballSpec> {
    let root = std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT")?;
    let file_name = format!("{}.json", package_name.replace('/', "__"));
    let path = PathBuf::from(root).join("tarballs").join(file_name);
    let contents = match fs::read_to_string(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return None,
        Err(error) => panic!("{} did not deserialize: {error}", path.display()),
    };
    serde_json::from_str(&contents)
        .unwrap_or_else(|error| panic!("{} should be valid JSON: {error}", path.display()))
}

/// Build the `package/package.json` body for a fixture tarball. Without a spec
/// it is the legacy minimal `{"name":"..."}` object; with a spec the declared
/// `bin` fields are merged in so `link_bins` reads them after extraction.
#[cfg(test)]
fn build_fixture_package_json(package_name: &str, spec: Option<&FixtureTarballSpec>) -> String {
    let Some(spec) = spec else {
        return format!(r#"{{"name":"{package_name}"}}"#);
    };
    let mut root = serde_json::Map::new();
    root.insert(
        "name".to_string(),
        serde_json::Value::String(package_name.to_string()),
    );
    if let Some(bin) = &spec.bin {
        root.insert("bin".to_string(), bin.clone());
    }
    serde_json::Value::Object(root).to_string()
}

#[cfg(test)]
fn package_name_from_tarball_url(tarball_url: &str) -> std::io::Result<String> {
    let path = tarball_url
        .split_once("://")
        .and_then(|(_, rest)| rest.split_once('/').map(|(_, path)| path))
        .ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidInput,
                format!("invalid fixture tarball URL: {tarball_url}"),
            )
        })?;
    let parts = path
        .split('/')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    match parts.as_slice() {
        [scope, name, ..] if scope.starts_with('@') => Ok(format!("{scope}/{name}")),
        [name, ..] => Ok((*name).to_string()),
        _ => Err(Error::new(
            ErrorKind::InvalidInput,
            format!("invalid fixture tarball URL path: {tarball_url}"),
        )),
    }
}

/// Derive the selected `package-name@version` a fixture tarball URL stands for.
///
/// Install deduplication is keyed by the selected package and version, not by
/// the requested range, so download measurement records the same unit. URLs
/// that do not follow the fixture layout fall back to the raw URL, which keeps
/// distinct downloads distinct instead of silently merging counters.
#[cfg(test)]
fn package_key_from_tarball_url(tarball_url: &str) -> String {
    let Ok(package_name) = package_name_from_tarball_url(tarball_url) else {
        return tarball_url.to_string();
    };
    let unscoped = package_name
        .rsplit('/')
        .next()
        .unwrap_or(package_name.as_str());
    let version = tarball_url
        .rsplit('/')
        .next()
        .and_then(|file_name| file_name.strip_suffix(".tgz"))
        .and_then(|stem| stem.strip_prefix(&format!("{unscoped}-")))
        .filter(|version| !version.is_empty());
    match version {
        Some(version) => format!("{package_name}@{version}"),
        None => tarball_url.to_string(),
    }
}

/// Tarball download counters for the fixture registry API.
///
/// ADR 0005 places installer measurement on the fake registry API that serves
/// deterministic fixture responses, recording calls by package name and
/// selected version. These counters are test-only; production downloads never
/// reach them.
#[cfg(test)]
pub(crate) mod test_support {
    // A documented `std::sync::Mutex` guards the counter map because libtest
    // runs test functions on parallel OS threads, so a `thread_local` or
    // `RefCell` counter would be per-thread state that silently miscounts
    // downloads across concurrently running tests.
    #![allow(clippy::disallowed_types)]

    use std::{
        collections::HashMap,
        sync::{Mutex, OnceLock},
    };

    fn counts() -> &'static Mutex<HashMap<String, u32>> {
        static COUNTS: OnceLock<Mutex<HashMap<String, u32>>> = OnceLock::new();
        COUNTS.get_or_init(|| Mutex::new(HashMap::new()))
    }

    fn locked_counts() -> std::sync::MutexGuard<'static, HashMap<String, u32>> {
        counts().lock().unwrap_or_else(|error| error.into_inner())
    }

    pub(crate) fn record_tarball_download(package_key: &str) {
        *locked_counts().entry(package_key.to_string()).or_insert(0) += 1;
    }

    /// Clear recorded downloads. Tests must call this while holding the shared
    /// install test env lock so counts never leak between tests.
    pub(crate) fn reset_tarball_download_counts() {
        locked_counts().clear();
    }

    pub(crate) fn tarball_download_count(package_key: &str) -> u32 {
        locked_counts().get(package_key).copied().unwrap_or(0)
    }

    /// Recorded downloads as a stable, sorted `(package@version, count)` list
    /// so expected download counts stay reviewable in test output.
    pub(crate) fn recorded_tarball_downloads() -> Vec<(String, u32)> {
        let mut recorded = locked_counts()
            .iter()
            .map(|(key, count)| (key.clone(), *count))
            .collect::<Vec<_>>();
        recorded.sort();
        recorded
    }

    // Metadata read counters. A registry metadata document covers every version
    // of a package, so version selection happens after the fetch. Metadata reads
    // are therefore counted by package name, while tarball downloads are counted
    // by the selected `package@version`.
    fn metadata_counts() -> &'static Mutex<HashMap<String, u32>> {
        static METADATA_COUNTS: OnceLock<Mutex<HashMap<String, u32>>> = OnceLock::new();
        METADATA_COUNTS.get_or_init(|| Mutex::new(HashMap::new()))
    }

    fn locked_metadata_counts() -> std::sync::MutexGuard<'static, HashMap<String, u32>> {
        metadata_counts()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    pub(crate) fn record_metadata_read(package_name: &str) {
        *locked_metadata_counts()
            .entry(package_name.to_string())
            .or_insert(0) += 1;
    }

    /// Clear recorded metadata reads. Tests must call this while holding the
    /// shared install test env lock so counts never leak between tests.
    pub(crate) fn reset_metadata_read_counts() {
        locked_metadata_counts().clear();
    }

    pub(crate) fn metadata_read_count(package_name: &str) -> u32 {
        locked_metadata_counts()
            .get(package_name)
            .copied()
            .unwrap_or(0)
    }

    /// Recorded metadata reads as a stable, sorted `(package-name, count)` list
    /// so expected read counts stay reviewable in test output.
    pub(crate) fn recorded_metadata_reads() -> Vec<(String, u32)> {
        let mut recorded = locked_metadata_counts()
            .iter()
            .map(|(name, count)| (name.clone(), *count))
            .collect::<Vec<_>>();
        recorded.sort();
        recorded
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::test_support::fixture_path;
    use std::{
        ffi::OsString,
        io,
        path::PathBuf,
        thread,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct FixtureRoot {
        previous: Option<OsString>,
        lock_path: PathBuf,
    }

    impl FixtureRoot {
        fn set(path: impl AsRef<std::path::Path>) -> Self {
            let lock_path = acquire_env_lock().expect("fixture env lock should be available");
            let previous = std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT");
            std::env::set_var("RPM_REGISTRY_FIXTURE_ROOT", path.as_ref());
            Self {
                previous,
                lock_path,
            }
        }

        fn unset() -> Self {
            let lock_path = acquire_env_lock().expect("fixture env lock should be available");
            let previous = std::env::var_os("RPM_REGISTRY_FIXTURE_ROOT");
            std::env::remove_var("RPM_REGISTRY_FIXTURE_ROOT");
            Self {
                previous,
                lock_path,
            }
        }
    }

    impl Drop for FixtureRoot {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => std::env::set_var("RPM_REGISTRY_FIXTURE_ROOT", value),
                None => std::env::remove_var("RPM_REGISTRY_FIXTURE_ROOT"),
            }
            let _ = fs::remove_dir(&self.lock_path);
        }
    }

    fn acquire_env_lock() -> io::Result<PathBuf> {
        let path = std::env::temp_dir().join("rpm-install-test-env-lock");
        loop {
            match fs::create_dir(&path) {
                Ok(()) => return Ok(path),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn temp_dir(prefix: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!("rpm-api-{prefix}-{nanos}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[tokio::test]
    async fn get_registry_reads_scoped_fixture_from_env_root() {
        let _fixture_root =
            FixtureRoot::set(fixture_path(&["registry", "shared-transitive", "metadata"]));

        let registry = get_registry("@rpm-fixture/alpha", "^1.0.0")
            .await
            .expect("fixture registry should load");

        assert_eq!(registry.name, "@rpm-fixture/alpha");
        assert_eq!(registry.select_version("^1.0.0").unwrap(), "1.0.0");
    }

    #[tokio::test]
    async fn get_registry_counts_metadata_reads_by_package_name() {
        let _fixture_root =
            FixtureRoot::set(fixture_path(&["registry", "shared-transitive", "metadata"]));
        test_support::reset_metadata_read_counts();

        get_registry("@rpm-fixture/alpha", "").await.unwrap();
        get_registry("@rpm-fixture/beta", "").await.unwrap();
        get_registry("@rpm-fixture/shared", "").await.unwrap();
        get_registry("@rpm-fixture/alpha", "").await.unwrap();

        assert_eq!(test_support::metadata_read_count("@rpm-fixture/alpha"), 2);
        assert_eq!(test_support::metadata_read_count("@rpm-fixture/beta"), 1);
        assert_eq!(test_support::metadata_read_count("@rpm-fixture/shared"), 1);
        assert_eq!(
            test_support::recorded_metadata_reads(),
            vec![
                ("@rpm-fixture/alpha".to_string(), 2),
                ("@rpm-fixture/beta".to_string(), 1),
                ("@rpm-fixture/shared".to_string(), 1),
            ],
        );
    }

    #[test]
    fn read_registry_fixture_returns_none_without_env_root() {
        let _fixture_root = FixtureRoot::unset();

        assert!(read_registry_fixture("@rpm-fixture/alpha")
            .expect("missing env should not fail")
            .is_none());
    }

    #[test]
    fn read_registry_fixture_reports_missing_and_invalid_fixtures() {
        let temp = temp_dir("invalid-fixture");
        let _fixture_root = FixtureRoot::set(&temp);

        let missing = read_registry_fixture("@scope/missing")
            .expect_err("missing fixture should include path context");
        assert!(missing.to_string().contains("@scope__missing.json"));

        fs::write(temp.join("@scope__broken.json"), "{").unwrap();
        let invalid =
            read_registry_fixture("@scope/broken").expect_err("invalid fixture JSON should fail");
        assert_eq!(invalid.kind(), ErrorKind::InvalidData);
        assert!(invalid.to_string().contains("@scope__broken.json"));
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn fixture_tarball_builds_minimal_package_archive() {
        let bytes =
            fixture_tarball("https://registry.example.invalid/@rpm-fixture/alpha/-/alpha.tgz")
                .expect("fixture tarball should be generated");

        let decoder = flate2::read::GzDecoder::new(bytes.as_slice());
        let mut archive = tar::Archive::new(decoder);
        let package_json = archive
            .entries()
            .unwrap()
            .find_map(|entry| {
                let mut entry = entry.unwrap();
                if entry.path().unwrap() == std::path::Path::new("package/package.json") {
                    let mut text = String::new();
                    use std::io::Read;
                    entry.read_to_string(&mut text).unwrap();
                    Some(text)
                } else {
                    None
                }
            })
            .expect("package.json should exist in generated archive");

        assert_eq!(package_json, r#"{"name":"@rpm-fixture/alpha"}"#);
    }

    #[test]
    fn package_key_from_tarball_url_records_selected_package_and_version() {
        assert_eq!(
            package_key_from_tarball_url(
                "https://registry.example.invalid/@rpm-fixture/shared/-/shared-1.0.0.tgz"
            ),
            "@rpm-fixture/shared@1.0.0"
        );
        assert_eq!(
            package_key_from_tarball_url(
                "https://registry.example.invalid/alpha/-/alpha-2.1.0.tgz"
            ),
            "alpha@2.1.0"
        );
        assert_eq!(package_key_from_tarball_url("not-a-url"), "not-a-url");
        assert_eq!(
            package_key_from_tarball_url("https://registry.example.invalid/alpha/-/alpha.tgz"),
            "https://registry.example.invalid/alpha/-/alpha.tgz"
        );
    }

    #[test]
    fn package_name_from_tarball_url_rejects_invalid_fixture_urls() {
        let error = package_name_from_tarball_url("not-a-url").unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(error.to_string().contains("invalid fixture tarball URL"));

        let error = package_name_from_tarball_url("https://registry.example.invalid/").unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(error
            .to_string()
            .contains("invalid fixture tarball URL path"));
    }

    #[test]
    fn registry_lookup_url_percent_encodes_scoped_name_segment() {
        let url = registry_lookup_url("@babel/core", "2.3.1");
        assert_eq!(url, "https://registry.npmjs.org/@babel%2Fcore/2.3.1");
        assert!(url.contains("%2F"));
    }

    #[test]
    fn registry_lookup_url_leaves_unscoped_name_unchanged() {
        let url = registry_lookup_url("express", "4.18.2");
        assert_eq!(url, "https://registry.npmjs.org/express/4.18.2");
        assert!(!url.contains("%2F"));
    }
}
