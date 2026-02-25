use std::io::{self, Write};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::terminal::{self, disable_raw_mode, enable_raw_mode};
use crossterm::{execute, terminal::supports_keyboard_enhancement};

use crate::audio;
use crate::cli::Command;
use crate::config;
use crate::error::AppError;
use crate::output;
use crate::stt;

pub fn run(command: Command) -> Result<(), AppError> {
    match command {
        Command::Toggle(args) => run_toggle(args),
        Command::Hold(args) => run_hold(args),
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

fn run_toggle(args: crate::cli::CommonArgs) -> Result<(), AppError> {
    let config = config::load(&args)?;

    eprintln!("Press Enter to start recording.");
    wait_for_enter()?;
    println!("OK RECORDING_STARTED");
    eprintln!("Press Enter again to stop recording.");

    let captured = audio::record_toggle(config.max_seconds)?;
    finalize_recording_and_transcription(config, captured)
}

fn run_hold(args: crate::cli::CommonArgs) -> Result<(), AppError> {
    let config = config::load(&args)?;
    eprintln!("Hold Space to record. Release Space to stop.");

    let captured = {
        let _input_guard = HoldInputGuard::setup()?;
        wait_for_space_press()?;
        print_raw_line("OK RECORDING_STARTED")?;

        let (stop_tx, stop_rx) = mpsc::channel();
        let (cancel_tx, cancel_rx) = mpsc::channel();
        let listener = spawn_space_release_listener(stop_tx, cancel_rx);

        let captured_result = audio::record_until_stop(config.max_seconds, stop_rx);
        let _ = cancel_tx.send(());

        let listener_result = listener
            .join()
            .map_err(|_| AppError::InputModeUnsupported)?;
        listener_result?;
        captured_result?
    };

    finalize_recording_and_transcription(config, captured)
}

fn finalize_recording_and_transcription(
    config: config::AppConfig,
    captured: audio::CapturedAudio,
) -> Result<(), AppError> {
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

fn wait_for_space_press() -> Result<(), AppError> {
    loop {
        let event = event::read().map_err(|_| AppError::InputModeUnsupported)?;
        if let Event::Key(key) = event {
            if is_space_press(key) {
                return Ok(());
            }
        }
    }
}

fn spawn_space_release_listener(
    stop_tx: mpsc::Sender<()>,
    cancel_rx: mpsc::Receiver<()>,
) -> thread::JoinHandle<Result<(), AppError>> {
    thread::spawn(move || {
        loop {
            if cancel_rx.try_recv().is_ok() {
                return Ok(());
            }

            let has_event = event::poll(Duration::from_millis(25))
                .map_err(|_| AppError::InputModeUnsupported)?;
            if !has_event {
                continue;
            }

            let event = event::read().map_err(|_| AppError::InputModeUnsupported)?;
            if let Event::Key(key) = event {
                if is_space_release(key) {
                    let _ = stop_tx.send(());
                    return Ok(());
                }
            }
        }
    })
}

fn is_space_press(key: KeyEvent) -> bool {
    matches!(key.code, KeyCode::Char(' ')) && matches!(key.kind, KeyEventKind::Press)
}

fn is_space_release(key: KeyEvent) -> bool {
    matches!(key.code, KeyCode::Char(' ')) && matches!(key.kind, KeyEventKind::Release)
}

fn print_raw_line(message: &str) -> Result<(), AppError> {
    print!("\r{message}\r\n");
    io::stdout()
        .flush()
        .map_err(|_| AppError::InputModeUnsupported)
}

struct HoldInputGuard {
    enhancement_enabled: bool,
}

impl HoldInputGuard {
    fn setup() -> Result<Self, AppError> {
        enable_raw_mode().map_err(|_| AppError::InputModeUnsupported)?;

        let supports = supports_keyboard_enhancement().map_err(|_| {
            let _ = disable_raw_mode();
            AppError::InputModeUnsupported
        })?;

        if !supports {
            let _ = disable_raw_mode();
            return Err(AppError::InputModeUnsupported);
        }

        execute!(
            io::stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::REPORT_EVENT_TYPES)
        )
        .map_err(|_| {
            let _ = disable_raw_mode();
            AppError::InputModeUnsupported
        })?;

        Ok(Self {
            enhancement_enabled: true,
        })
    }
}

impl Drop for HoldInputGuard {
    fn drop(&mut self) {
        if self.enhancement_enabled {
            let _ = execute!(io::stdout(), PopKeyboardEnhancementFlags);
        }

        let _ = terminal::disable_raw_mode();
    }
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

    use super::{is_space_press, is_space_release};

    #[test]
    fn space_press_matcher_only_accepts_press_space() {
        let press =
            KeyEvent::new_with_kind(KeyCode::Char(' '), KeyModifiers::NONE, KeyEventKind::Press);
        let release = KeyEvent::new_with_kind(
            KeyCode::Char(' '),
            KeyModifiers::NONE,
            KeyEventKind::Release,
        );
        let other =
            KeyEvent::new_with_kind(KeyCode::Char('x'), KeyModifiers::NONE, KeyEventKind::Press);

        assert!(is_space_press(press));
        assert!(!is_space_press(release));
        assert!(!is_space_press(other));
    }

    #[test]
    fn space_release_matcher_only_accepts_release_space() {
        let press =
            KeyEvent::new_with_kind(KeyCode::Char(' '), KeyModifiers::NONE, KeyEventKind::Press);
        let release = KeyEvent::new_with_kind(
            KeyCode::Char(' '),
            KeyModifiers::NONE,
            KeyEventKind::Release,
        );
        let other = KeyEvent::new_with_kind(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
            KeyEventKind::Release,
        );

        assert!(!is_space_release(press));
        assert!(is_space_release(release));
        assert!(!is_space_release(other));
    }
}
