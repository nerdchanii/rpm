use rpm::command;
use rpm::command::Command;
use rpm::opt::Opt;
use structopt::StructOpt;

async fn run(opt: Opt) {
    match opt.cmd {
        Command::Add { libs, dev } => {
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
