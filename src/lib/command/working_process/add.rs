use crate::{api, util::parse_library_name};
use async_recursion::async_recursion;

#[async_recursion]
pub async fn add(libs: Vec<String>, dev: bool) -> Result<(), reqwest::Error> {
    for lib in libs {
        let (library_name, version) = parse_library_name(lib);
        let registry = api::get_registry(&library_name, &version).await?;
        registry.download_tarball().await?;
        let dependencies = registry.get_dependencies();
        add(dependencies, false).await?;
    }
    Ok(())
}
