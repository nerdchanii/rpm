use crate::{command::working_process, packge_json::Package};

pub async fn install() -> Result<(), reqwest::Error> {
    let pkg_json = Package::read_file();
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

    Ok(())
}
