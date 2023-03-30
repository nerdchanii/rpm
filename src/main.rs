use rapm::command::{working_process, Command};
use rapm::opt::Opt;
use rapm::packge_json::Package;
use rapm::rapm_lock::lockfile::LockFile;
use structopt::StructOpt;

async fn run(opt: Opt) {
    match opt.cmd {
        Command::Install => {
            println!("installing...");
            let time = std::time::Instant::now();
            let result = working_process::install().await;
            result.expect("install failed\n");
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
        }
        Command::Add { libs, dev } => {
            let time = std::time::Instant::now();
            let mut pkg = Package::read_file("./package.json");
            let mut lockfile = LockFile::load().unwrap();
            let result = working_process::add(&mut pkg, &mut lockfile, libs, dev, true).await;
            result.expect("add failed\n");
            if lockfile.save().is_ok() {
                pkg.save().expect("save failed\n");
            }
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
        }
        Command::Run { script_key } => {
            let time = std::time::Instant::now();
            let result = working_process::run(script_key).await;
            result.expect("run failed\n");
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
        }
        _ => {
            panic!("not implemented");
        }
    }
}

#[tokio::main]
async fn main() {
    let opt = Opt::from_args();
    run(opt).await;
}
