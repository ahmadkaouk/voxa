use crate::cli::{Command, CommonArgs, OutputTarget};

pub fn run(command: Command) {
    let args = match command {
        Command::Toggle(args) | Command::Hold(args) => args,
    };
    run_mode(&args);
}

fn run_mode(args: &CommonArgs) {
    println!("OK TRANSCRIPTION_READY");

    if matches!(args.output, OutputTarget::Clipboard) {
        println!("OK COPIED_TO_CLIPBOARD");
    }
}
