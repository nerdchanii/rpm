use rpm::command::{working_process, Command};
use rpm::lockfile::LockFile;
use rpm::opt::Opt;
use rpm::package_manifest::PackageManifest;
use structopt::StructOpt;

async fn run(opt: Opt) -> std::io::Result<()> {
    match opt.cmd {
        Command::Install => {
            println!("installing...");
            let time = std::time::Instant::now();
            working_process::install().await?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(())
        }
        Command::Add { libs, dev } => {
            let time = std::time::Instant::now();
            let mut pkg = PackageManifest::read_default()?;
            let mut lockfile = LockFile::load()?;
            working_process::add(&mut pkg, &mut lockfile, libs, dev, true).await?;
            lockfile.save()?;
            pkg.save_to_path("./package.json")?;
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
            Ok(())
        }
        Command::Run { script_key } => {
            let result = working_process::run(script_key).await;
            match result {
                Ok(status) => {
                    if status != 0 {
                        std::process::exit(status);
                    }
                }
                Err(error) => {
                    eprintln!("run failed: {error}");
                    std::process::exit(1);
                }
            }
            Ok(())
        }
        _ => {
            eprintln!("command is not implemented");
            std::process::exit(1);
        }
    }
}

#[tokio::main]
async fn main() {
    let opt = Opt::from_args();
    if let Err(error) = run(opt).await {
        eprintln!("rpm failed: {error}");
        std::process::exit(1);
    }
}
