use std::time::Duration;
use tokio::time::sleep;

use crate::{command::working_process, packge_json::Package};

pub async fn install() -> Result<(), reqwest::Error> {
    let pkg_json = Package::read_file();
    // 1. dependencies 받아와서 install
    // 2. devDependencies 받아와서 install
    let dependencies = pkg_json.get_dependencies();
    let libs = dependencies
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(libs, false).await?;

    let dev_deps = pkg_json.get_dev_dependencies();
    let dev_libs = dev_deps
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(dev_libs, true).await?;

    // println!("{:?}", pkg_json.get_dev_dependencies());
    sleep(Duration::from_secs(3.to_owned())).await;
    Ok(())
}
