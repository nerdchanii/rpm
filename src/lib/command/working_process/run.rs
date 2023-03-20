use std::{os::unix::process::CommandExt, process::Command};

use crate::packge_json::Package;

pub async fn run(script_key: String) -> Result<(), std::io::Error> {
    let package = Package::read_file();
    let scripts = package.get_scripts();
    let script = scripts.get(&script_key);
    match script {
        Some(script) => {
            println!("Running script: {}", script);
            // script like "node index.js"
            let mut args = script.split(' ');
            let cmd = args.next().unwrap();
            let args: Vec<&str> = args.collect();
            Command::new(cmd).args(args).exec();
        }
        None => {
            println!("script not found");
        }
    }

    Ok(())
}
