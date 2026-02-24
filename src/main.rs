mod cli;
mod command;

use clap::{Parser, error::ErrorKind};

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let cli = match cli::Cli::try_parse() {
        Ok(cli) => cli,
        Err(err) => {
            let show_success_exit = matches!(
                err.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            );
            let _ = err.print();
            return if show_success_exit { 0 } else { 1 };
        }
    };

    command::run(cli.command);
    0
}
