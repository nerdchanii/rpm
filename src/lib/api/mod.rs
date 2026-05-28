mod constants;

use constants::REGISTRY_PATH;

use crate::registry::Registry;
use std::io::Error;

pub async fn get_registry(lib_name: &str) -> std::io::Result<Registry> {
    let request_url = format!("{}/{}", REGISTRY_PATH, lib_name);
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
    let response = reqwest::get(tarball_url)
        .await
        .map_err(|error| Error::other(format!("failed to download {tarball_url}: {error}")))?
        .bytes()
        .await
        .map_err(|error| Error::other(format!("failed to read {tarball_url}: {error}")))?;
    Ok(response.to_vec())
}

pub async fn get_registry_text(lib_name: &str) -> std::io::Result<String> {
    let request_url = format!("{}/{}", REGISTRY_PATH, lib_name);
    reqwest::get(&request_url)
        .await
        .map_err(|error| Error::other(format!("failed to fetch registry {request_url}: {error}")))?
        .text()
        .await
        .map_err(|error| Error::other(format!("failed to read registry {request_url}: {error}")))
}
