use rpm::command::{working_process, Command};
use rpm::opt::Opt;
use structopt::StructOpt;

async fn run(opt: Opt) {
    match opt.cmd {
        Command::Install => {
            let time = std::time::Instant::now();
            let result = working_process::install().await;
            result.expect("install failed\n");
            println!("time: {:.2}s", time.elapsed().as_secs_f32());
        }
        Command::Add { libs, dev } => {
            let time = std::time::Instant::now();
            let result = working_process::add(libs, dev).await;
            result.expect("add failed\n");
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
