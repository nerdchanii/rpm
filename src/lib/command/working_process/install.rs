use std::time::Duration;
use tokio::time::sleep;

pub async fn install() -> Result<(), reqwest::Error> {
    // for make sekeleton of install process with async
    sleep(Duration::from_secs(3.to_owned())).await;
    println!("install process");
    Ok(())
}
