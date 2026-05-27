use crate::{command::working_process, lockfile::LockFile, package_manifest::PackageManifest};

pub async fn install() -> std::io::Result<()> {
    let mut package_manifest = PackageManifest::read_default()?;
    let dependencies = package_manifest.get_dependencies();
    let mut lockfile = LockFile::load()?;
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

    lockfile.save()?;
    package_manifest.save_to_path("./package.json")?;
    Ok(())
}
