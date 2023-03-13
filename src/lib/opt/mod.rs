use crate::command::Command;
mod constants;
use constants::{APP_NAME, DESCRIPTION, VERSION};
use structopt::StructOpt;

#[derive(StructOpt, Debug)]
#[structopt(name = APP_NAME, about = DESCRIPTION , version = VERSION)]
pub struct Opt {
    /// define the Command
    #[structopt(name = "COMMAND", subcommand)]
    pub cmd: Command,
}
