mod constants;

use constants::REGISTRY_PATH;

use crate::registry::Registry;

pub async fn get_registry(lib_name: &str, version: &str) -> Result<Registry, reqwest::Error> {
    // if version == "" => url/pkg
    // version != "" => url/pkg/version
    // if version start with ^ or ~ => remove ^ or ~
    let specific_version = version.starts_with('^') || version.starts_with('~');
    let version = if specific_version {
        version[1..].to_string()
    } else if version == "*" {
        "latest".to_string()
    } else {
        version.to_string()
    };

    let request_url = format!("{}/{}/{}", REGISTRY_PATH, lib_name, version);
    let response = reqwest::get(request_url);
    let registry = response
        .await?
        .json::<Registry>()
        .await
        .expect(format!("parse json error {}", lib_name).as_str());
    Ok(registry)
}

pub async fn get_tarball(tarball_url: &str) -> Result<Vec<u8>, reqwest::Error> {
    let response = reqwest::get(tarball_url).await?.bytes().await;
    match response {
        Ok(response) => Ok(response.to_vec()),
        Err(_) => panic!("download tarball error"),
    }
}

pub async fn get_registry_text(lib_name: &str, version: &str) -> Result<String, reqwest::Error> {
    let request_url = format!("{}/{}/{}", REGISTRY_PATH, lib_name, version);
    let response = reqwest::get(request_url).await?.text().await;
    match response {
        Ok(response) => Ok(response),
        Err(_) => panic!("download error"),
    }
}
