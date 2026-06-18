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
