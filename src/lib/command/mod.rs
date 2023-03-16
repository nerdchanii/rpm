pub mod working_process;
use structopt::StructOpt;

#[derive(Debug, StructOpt)]
pub enum Command {
    #[structopt(name = "add", about = "add libraries")]
    Add {
        #[structopt(help = "install libraries")]
        libs: Vec<String>,
        #[structopt(short, long, help = "install dev libraries")]
        dev: bool,
    },
    #[structopt(
        name = "install",
        about = "install libraries using rpm.lock file(when it not founded using package.json file)"
    )]
    Install,
    #[structopt(name = "remove", about = "remove libraries")]
    Remove { libs: Vec<String> },
    #[structopt(name = "list", about = "list installed libraries")]
    List,
    #[structopt(about = "display version of rpm")]
    Version,
}
