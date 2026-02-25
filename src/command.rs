use std::io;

use crate::audio;
use crate::cli::Command;
use crate::config;
use crate::error::AppError;
use crate::output;
use crate::stt;

pub fn run(command: Command) -> Result<(), AppError> {
    match command {
        Command::Toggle(args) => {
            let config = config::load(&args)?;

            eprintln!("Press Enter to start recording.");
            wait_for_enter()?;
            println!("OK RECORDING_STARTED");
            eprintln!("Press Enter again to stop recording.");

            let captured = audio::record_toggle(config.max_seconds)?;
            println!("OK RECORDING_STOPPED");

            if captured.max_duration_reached {
                println!(
                    "WARN AUDIO_MAX_DURATION_REACHED: recording reached max duration and was stopped."
                );
            }

            let transcript = stt::transcribe(
                &config.api_key,
                config.model,
                config.language,
                &captured.wav_bytes,
            )?;
            println!("OK TRANSCRIPTION_READY");
            output::emit(&transcript, config.output);

            Ok(())
        }
        Command::Hold(_) => Err(AppError::InputModeUnsupported),
    }
}

fn wait_for_enter() -> Result<(), AppError> {
    let mut line = String::new();
    let read = io::stdin()
        .read_line(&mut line)
        .map_err(|_| AppError::AudioCaptureFailed)?;

    if read == 0 {
        return Err(AppError::AudioCaptureFailed);
    }

    Ok(())
}
