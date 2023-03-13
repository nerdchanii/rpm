use crate::parser::registry::Registry;
use reqwest;
use structopt::StructOpt;

mod constants;
use constants::REGISTRY_PATH;

#[derive(Debug, StructOpt)]
pub enum Command {
    #[structopt(name = "add", about = "add libraries")]
    Add {
        #[structopt(help = "install libraries")]
        libs: Vec<String>,
        #[structopt(short, long, help = "install dev libraries")]
        dev: bool,
    },
    #[structopt(name = "remove", about = "remove libraries")]
    Remove { libs: Vec<String> },
    #[structopt(name = "list", about = "list installed libraries")]
    List,
    #[structopt(about = "display version of rpm")]
    Version,
}

pub async fn add(libs: Vec<String>, dev: bool) -> Result<(), reqwest::Error> {
    for lib in libs {
        let (library_name, version) = parse_library_name(lib);
        let response = reqwest::get(format!("{}/{}/{}", REGISTRY_PATH, library_name, version));
        let registry: Result<Registry, reqwest::Error> = response.await?.json::<Registry>().await;

        match registry {
            Ok(registry) => {
                let tarball = registry.download_tarball().await;
            }
            Err(e) => {
                let response =
                    reqwest::get(format!("{}/{}/{}", REGISTRY_PATH, library_name, version));
                let text = response.await?.text().await;
                println!("error: {}", e);
                println!("text: {}", text.unwrap()[790..900].to_string());
            }
        }
    }
    Ok(())
}

fn parse_library_name(lib: String) -> (String, String) {
    if lib.contains("@v") {
        let lib_split: Vec<&str> = lib.split("@v").collect();
        (lib_split[0].to_string(), lib_split[1].to_string())
    } else {
        (lib, "".to_string())
    }
}
