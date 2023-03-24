use crate::{node_linker::NodeModules, packge_json::Package};
use std::{os::unix::process::CommandExt, process::Command};

pub async fn run(script_key: String) -> Result<(), std::io::Error> {
    let package = Package::read_file("./package.json");
    let scripts = package.get_scripts();
    let script = scripts.get(&script_key);
    NodeModules::init();

    if let Some(script) = script {
        println!("Running script: {}", script);

        // script like "node index.js"
        let mut args = script.split(' ');
        let cmd = args.next().unwrap();
        let args: Vec<&str> = args.collect();
        if cmd == "node" {
            Command::new("node").args(&args).exec();
        } else {
            let path = getbin(cmd);
            Command::new(path).args(&args).exec();
        }
    } else {
        println!("script not found");
    }

    Ok(())
}

fn getbin(cmd: &str) -> String {
    let path = get_bing_path(cmd);
    let node_modules = "./node_modules";

    let path = format!("{}/{}/{}", node_modules, cmd, path);
    path
}

fn get_bing_path(cmd: &str) -> String {
    let package = NodeModules::read_package(cmd);
    let bin = package.get_bin().unwrap();
    bin.get(cmd).unwrap().to_string()
}
