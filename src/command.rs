use crate::cli::{Command, OutputTarget};
use crate::config;
use crate::error::AppError;

pub fn run(command: Command) -> Result<(), AppError> {
    let args = match command {
        Command::Toggle(args) | Command::Hold(args) => args,
    };

    let config = config::load(&args)?;

    println!("OK TRANSCRIPTION_READY");

    if matches!(config.output, OutputTarget::Clipboard) {
        println!("OK COPIED_TO_CLIPBOARD");
    }

    Ok(())
}
