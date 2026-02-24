use crate::cli::{Command, CommonArgs};
use crate::error::AppError;

pub fn run(command: Command) -> Result<(), AppError> {
    match command {
        Command::Toggle(args) => run_toggle(&args),
        Command::Hold(args) => run_hold(&args),
    }
}

fn run_toggle(args: &CommonArgs) -> Result<(), AppError> {
    args.validate()?;
    println!("OK COMMAND_PARSED: toggle");
    Ok(())
}

fn run_hold(args: &CommonArgs) -> Result<(), AppError> {
    args.validate()?;
    println!("OK COMMAND_PARSED: hold");
    Ok(())
}
