use crate::{command::working_process, packge_json::Package, rapm_lock::lockfile::LockFile};

pub async fn install() -> Result<(), reqwest::Error> {
    let mut pkg_json = Package::read_file("./package.json");
    let dependencies = pkg_json.get_dependencies();
    let mut lockfile = LockFile::load().unwrap();
    let libs = dependencies
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(&mut pkg_json, &mut lockfile, libs, false, false).await?;

    let dev_deps = pkg_json.get_dev_dependencies();
    let dev_libs = dev_deps
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(&mut pkg_json, &mut lockfile, dev_libs, true, false).await?;

    lockfile.save().expect("[Error] save Error");
    pkg_json.save().expect("[Error] save Error");
    Ok(())
}
