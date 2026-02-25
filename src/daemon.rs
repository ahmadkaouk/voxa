use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

use rdev::{EventType, Key, listen};

use crate::audio;
use crate::config;
use crate::daemon_config::{self, DaemonConfig, DaemonHotkey};
use crate::error::AppError;
use crate::hotkey::{HotkeyEventKind, HotkeyKey, HotkeyMatcher};
use crate::output;
use crate::stt;

const LISTENER_POLL_INTERVAL_MS: u64 = 100;

enum DaemonEvent {
    Trigger,
    ListenerFailed,
}

struct ActiveRecording {
    stop_tx: mpsc::Sender<()>,
    stop_requested: bool,
}

pub fn run() -> Result<(), AppError> {
    let daemon_cfg = daemon_config::load()?;

    println!("OK DAEMON_STARTED");
    println!("hotkey = {}", daemon_cfg.hotkey.as_str());
    println!("output = {}", daemon_cfg.output.as_str());

    let (daemon_tx, daemon_rx) = mpsc::channel::<DaemonEvent>();
    spawn_hotkey_listener(daemon_cfg.hotkey, daemon_tx);

    let (session_done_tx, session_done_rx) = mpsc::channel::<Result<(), AppError>>();
    let mut active_recording: Option<ActiveRecording> = None;

    loop {
        while let Ok(result) = session_done_rx.try_recv() {
            active_recording = None;

            if let Err(err) = result {
                err.print();
            }
        }

        match daemon_rx.recv_timeout(Duration::from_millis(LISTENER_POLL_INTERVAL_MS)) {
            Ok(DaemonEvent::Trigger) => {
                handle_trigger(&mut active_recording, &session_done_tx);
            }
            Ok(DaemonEvent::ListenerFailed) => return Err(AppError::DaemonListenerUnavailable),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(AppError::DaemonListenerUnavailable);
            }
        }
    }
}

fn handle_trigger(
    active_recording: &mut Option<ActiveRecording>,
    session_done_tx: &mpsc::Sender<Result<(), AppError>>,
) {
    if let Some(active) = active_recording.as_mut() {
        if !active.stop_requested {
            let _ = active.stop_tx.send(());
            active.stop_requested = true;
        }

        return;
    }

    let app_config = match config::load_defaults() {
        Ok(config) => config,
        Err(err) => {
            err.print();
            return;
        }
    };

    let daemon_cfg = match daemon_config::load() {
        Ok(config) => config,
        Err(err) => {
            err.print();
            return;
        }
    };

    let (stop_tx, stop_rx) = mpsc::channel();
    let done_tx = session_done_tx.clone();

    println!("OK RECORDING_STARTED");

    thread::spawn(move || {
        let result = run_session(app_config, daemon_cfg, stop_rx);
        let _ = done_tx.send(result);
    });

    *active_recording = Some(ActiveRecording {
        stop_tx,
        stop_requested: false,
    });
}

fn run_session(
    config: config::AppConfig,
    daemon_config: DaemonConfig,
    stop_rx: mpsc::Receiver<()>,
) -> Result<(), AppError> {
    let captured = audio::record_until_stop(config.max_seconds, stop_rx)?;
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
    output::emit_daemon(&transcript, daemon_config.output);

    Ok(())
}

fn spawn_hotkey_listener(hotkey: DaemonHotkey, tx: mpsc::Sender<DaemonEvent>) {
    thread::spawn(move || {
        let matcher = Arc::new(Mutex::new(HotkeyMatcher::new(hotkey)));
        let matcher_for_callback = Arc::clone(&matcher);
        let tx_for_callback = tx.clone();

        let result = listen(move |event| {
            let Some((kind, key)) = map_event(event.event_type) else {
                return;
            };

            let should_trigger = match matcher_for_callback.lock() {
                Ok(mut matcher) => matcher.on_event(kind, key),
                Err(_) => false,
            };

            if should_trigger {
                let _ = tx_for_callback.send(DaemonEvent::Trigger);
            }
        });

        if result.is_err() {
            let _ = tx.send(DaemonEvent::ListenerFailed);
        }
    });
}

fn map_event(event: EventType) -> Option<(HotkeyEventKind, HotkeyKey)> {
    match event {
        EventType::KeyPress(key) => Some((HotkeyEventKind::Press, map_key(key))),
        EventType::KeyRelease(key) => Some((HotkeyEventKind::Release, map_key(key))),
        _ => None,
    }
}

fn map_key(key: Key) -> HotkeyKey {
    match key {
        Key::AltGr => HotkeyKey::RightOption,
        Key::MetaLeft | Key::MetaRight => HotkeyKey::Command,
        Key::Space => HotkeyKey::Space,
        Key::Function => HotkeyKey::Function,
        _ => HotkeyKey::Other,
    }
}

#[cfg(test)]
mod tests {
    use rdev::{EventType, Key};

    use super::{HotkeyEventKind, HotkeyKey, map_event, map_key};

    #[test]
    fn map_key_maps_supported_keys() {
        assert_eq!(map_key(Key::AltGr), HotkeyKey::RightOption);
        assert_eq!(map_key(Key::MetaLeft), HotkeyKey::Command);
        assert_eq!(map_key(Key::MetaRight), HotkeyKey::Command);
        assert_eq!(map_key(Key::Space), HotkeyKey::Space);
        assert_eq!(map_key(Key::Function), HotkeyKey::Function);
    }

    #[test]
    fn map_event_ignores_non_keyboard_events() {
        let mapped = map_event(EventType::MouseMove { x: 1.0, y: 1.0 });
        assert!(mapped.is_none());
    }

    #[test]
    fn map_event_maps_key_press_and_release() {
        let press = map_event(EventType::KeyPress(Key::Space));
        let release = map_event(EventType::KeyRelease(Key::Space));

        assert_eq!(press, Some((HotkeyEventKind::Press, HotkeyKey::Space)));
        assert_eq!(release, Some((HotkeyEventKind::Release, HotkeyKey::Space)));
    }
}
