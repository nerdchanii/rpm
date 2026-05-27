use crate::{command::working_process, lockfile::LockFile, package_manifest::PackageManifest};

pub async fn install() -> Result<(), reqwest::Error> {
    let mut package_manifest = PackageManifest::read_file("./package.json");
    let dependencies = package_manifest.get_dependencies();
    let mut lockfile = LockFile::load().unwrap();
    let libs = dependencies
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(&mut package_manifest, &mut lockfile, libs, false, false).await?;

    let dev_deps = package_manifest.get_dev_dependencies();
    let dev_libs = dev_deps
        .iter()
        .map(|(lib_name, version)| format!("{}@{}", lib_name, version))
        .collect::<Vec<String>>();
    working_process::add(&mut package_manifest, &mut lockfile, dev_libs, true, false).await?;

    lockfile.save().expect("[Error] save Error");
    package_manifest.save().expect("[Error] save Error");
    Ok(())
}
