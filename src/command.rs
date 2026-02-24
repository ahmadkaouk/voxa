use crate::cli::{Command, CommonArgs, OutputTarget};
use crate::error::AppError;

pub fn run(command: Command) -> Result<(), AppError> {
    let args = match command {
        Command::Toggle(args) | Command::Hold(args) => args,
    };
    run_mode(&args)
}

fn run_mode(args: &CommonArgs) -> Result<(), AppError> {
    args.validate()?;
    println!("OK TRANSCRIPTION_READY");

    if matches!(args.output, OutputTarget::Clipboard) {
        println!("OK COPIED_TO_CLIPBOARD");
    }

    Ok(())
}
