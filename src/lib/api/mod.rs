mod constants;

use constants::REGISTRY_PATH;

use crate::registry::Registry;
use std::io::Error;
#[cfg(test)]
use std::{fs, io::ErrorKind, path::PathBuf};

pub async fn get_registry(lib_name: &str, version: &str) -> std::io::Result<Registry> {
    #[cfg(test)]
    if let Some(registry) = read_registry_fixture(lib_name)? {
        return Ok(registry);
    }

    let request_url = format!("{}/{}/{}", REGISTRY_PATH, lib_name, version);
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
    let request_url = format!("{}/{}/{}", REGISTRY_PATH, lib_name, version);
    reqwest::get(&request_url)
        .await
        .map_err(|error| Error::other(format!("failed to fetch registry {request_url}: {error}")))?
        .text()
        .await
        .map_err(|error| Error::other(format!("failed to read registry {request_url}: {error}")))
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
    let package_json = format!(r#"{{"name":"{package_name}"}}"#);
    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut builder = Builder::new(encoder);
    let mut header = Header::new_gnu();
    header.set_size(package_json.len() as u64);
    header.set_cksum();
    builder.append_data(&mut header, "package/package.json", package_json.as_bytes())?;
    builder.finish()?;
    let mut encoder = builder.into_inner()?;
    encoder.flush()?;
    encoder.finish()
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
}
