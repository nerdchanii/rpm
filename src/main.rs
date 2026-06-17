use rpm::command::{working_process, Command};
use rpm::lockfile::LockFile;
use rpm::opt::Opt;
use rpm::package_manifest::PackageManifest;
use std::process::ExitCode;
use structopt::StructOpt;

enum MainOutcome {
    ExitCode(ExitCode),
    ChildStatus(i32),
}

fn child_status(status: i32) -> MainOutcome {
    MainOutcome::ChildStatus(status)
}

#[allow(clippy::disallowed_methods)]
fn exit_with_status(status: i32) -> ! {
    // `rpm run` must preserve the child status even on platforms that expose
    // values outside the `u8` range accepted by `ExitCode`.
    std::process::exit(status);
}

async fn run(opt: Opt) -> std::io::Result<MainOutcome> {
    match opt.cmd {
        Command::Install => {
            println!("installing...");
            let time = std::time::Instant::now();
            working_process::install().await?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(MainOutcome::ExitCode(ExitCode::SUCCESS))
        }
        Command::Add { libs, dev } => {
            let time = std::time::Instant::now();
            let mut pkg = PackageManifest::read_default()?;
            let mut lockfile = LockFile::load()?;
            working_process::add(&mut pkg, &mut lockfile, libs, dev, true).await?;
            lockfile.save()?;
            pkg.save_to_path("./package.json")?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(MainOutcome::ExitCode(ExitCode::SUCCESS))
        }
        Command::Run { script_key } => {
            let result = working_process::run(script_key).await;
            match result {
                Ok(status) => Ok(child_status(status)),
                Err(error) => {
                    eprintln!("run failed: {error}");
                    Ok(MainOutcome::ExitCode(ExitCode::FAILURE))
                }
            }
        }
        _ => {
            eprintln!("command is not implemented");
            Ok(MainOutcome::ExitCode(ExitCode::FAILURE))
        }
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let opt = Opt::from_args();
    match run(opt).await {
        Ok(MainOutcome::ExitCode(status)) => status,
        Ok(MainOutcome::ChildStatus(status)) => exit_with_status(status),
        Err(error) => {
            eprintln!("rpm failed: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{child_status, MainOutcome};

    #[test]
    fn child_status_preserves_values_outside_u8() {
        match child_status(300) {
            MainOutcome::ChildStatus(status) => assert_eq!(status, 300),
            MainOutcome::ExitCode(_) => panic!("expected child status outcome"),
        }
    }
}
