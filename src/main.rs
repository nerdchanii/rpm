use rpm::command::{working_process, Command};
use rpm::opt::Opt;
use structopt::StructOpt;

async fn run(opt: Opt) {
    match opt.cmd {
        Command::Install => {
            let result = working_process::install().await;
            match result {
                Ok(_) => {}
                Err(e) => {
                    panic!("{}", e);
                }
            };
        }
        Command::Add { libs, dev } => {
            let result = working_process::add(libs, dev).await;
            match result {
                Ok(_) => {}
                Err(e) => {
                    panic!("{}", e);
                }
            };
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
