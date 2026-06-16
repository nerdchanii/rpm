use rpm::command::{working_process, Command};
use rpm::lockfile::LockFile;
use rpm::opt::Opt;
use rpm::package_manifest::PackageManifest;
use std::process::ExitCode;
use structopt::StructOpt;

fn exit_code_from_status(status: i32) -> ExitCode {
    match u8::try_from(status) {
        Ok(status) => ExitCode::from(status),
        Err(_) => ExitCode::FAILURE,
    }
}

async fn run(opt: Opt) -> std::io::Result<ExitCode> {
    match opt.cmd {
        Command::Install => {
            println!("installing...");
            let time = std::time::Instant::now();
            working_process::install().await?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(ExitCode::SUCCESS)
        }
        Command::Add { libs, dev } => {
            let time = std::time::Instant::now();
            let mut pkg = PackageManifest::read_default()?;
            let mut lockfile = LockFile::load()?;
            working_process::add(&mut pkg, &mut lockfile, libs, dev, true).await?;
            lockfile.save()?;
            pkg.save_to_path("./package.json")?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(ExitCode::SUCCESS)
        }
        Command::Run { script_key } => {
            let result = working_process::run(script_key).await;
            match result {
                Ok(status) => Ok(exit_code_from_status(status)),
                Err(error) => {
                    eprintln!("run failed: {error}");
                    Ok(ExitCode::FAILURE)
                }
            }
        }
        _ => {
            eprintln!("command is not implemented");
            Ok(ExitCode::FAILURE)
        }
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let opt = Opt::from_args();
    match run(opt).await {
        Ok(status) => status,
        Err(error) => {
            eprintln!("rpm failed: {error}");
            ExitCode::FAILURE
        }
    }
}
