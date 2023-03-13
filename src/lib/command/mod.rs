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
    let re = Regex::new(r"^([^@]+)(?:@(\d+\.\d+\.\d+))?$").unwrap();
    if let Some(captures) = re.captures(&lib) {
        let pkg_name = captures.get(1).unwrap().as_str();
        let version = captures.get(2).map_or("", |m| m.as_str());
        (pkg_name.to_owned(), version.to_owned())
    } else {
        panic!("error: invalid library name");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_lib_version() {
        let lib = "socket-store@0.0.1";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "socket-store");
        assert_eq!(version, "0.0.1");
        assert_ne!(version, "0.0.2");
    }
    #[test]
    fn parse_lib_without_version() {
        let lib = "socket-store";
        let (lib_name, version) = parse_library_name(lib.to_owned());
        assert_eq!(lib_name, "socket-store");
        assert_eq!(version, "");
    }
}
