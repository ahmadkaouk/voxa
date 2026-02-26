use crate::cli::Command;
use crate::daemon;
use crate::daemon_config;
use crate::error::AppError;
use crate::service;

pub fn run(command: Command) -> Result<(), AppError> {
    match command {
        Command::Daemon => daemon::run(),
        Command::Service(args) => service::run(args.command),
        Command::Config(args) => daemon_config::run(args.command),
    }
}
