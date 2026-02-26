use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use rdev::{EventType, Key, listen};

use crate::audio;
use crate::config;
use crate::daemon_config::{self, DaemonConfig, DaemonHotkey, DaemonMode};
use crate::error::AppError;
use crate::hotkey::{HotkeyEventKind, HotkeyKey, HotkeyMatcher, HotkeySignal};
use crate::output;
use crate::stt;

const LISTENER_POLL_INTERVAL_MS: u64 = 100;
const MIN_TOGGLE_RECORDING_MS: u128 = 350;
const DAEMON_LOCK_FILE_NAME: &str = "daemon.lock";

enum DaemonEvent {
    StartRecording,
    StopRecording,
    ListenerFailed,
}

struct ActiveRecording {
    stop_tx: mpsc::Sender<()>,
    stop_requested: bool,
    started_at: Instant,
}

pub fn run() -> Result<(), AppError> {
    let _daemon_lock = acquire_daemon_lock()?;
    let daemon_cfg = daemon_config::load()?;

    println!("OK DAEMON_STARTED");
    println!("hotkey = {}", daemon_cfg.hotkey.as_str());
    println!("mode = {}", daemon_cfg.mode.as_str());
    println!("output = {}", daemon_cfg.output.as_str());

    let (daemon_tx, daemon_rx) = mpsc::channel::<DaemonEvent>();
    spawn_hotkey_listener(daemon_cfg.hotkey, daemon_cfg.mode, daemon_tx);

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
            Ok(DaemonEvent::ListenerFailed) => return Err(AppError::DaemonListenerUnavailable),
            Ok(event) => handle_daemon_event(
                event,
                daemon_cfg.mode,
                &mut active_recording,
                &session_done_tx,
            ),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(AppError::DaemonListenerUnavailable);
            }
        }
    }
}

fn acquire_daemon_lock() -> Result<DaemonLock, AppError> {
    let lock_path = daemon_lock_path()?;
    acquire_daemon_lock_at_path(&lock_path)
}

fn daemon_lock_path() -> Result<PathBuf, AppError> {
    let config_path = daemon_config::config_path()?;
    let Some(config_dir) = config_path.parent() else {
        return Err(AppError::DaemonConfigPathUnavailable);
    };

    Ok(config_dir.join(DAEMON_LOCK_FILE_NAME))
}

fn acquire_daemon_lock_at_path(path: &Path) -> Result<DaemonLock, AppError> {
    let Some(parent) = path.parent() else {
        return Err(AppError::DaemonConfigPathUnavailable);
    };

    fs::create_dir_all(parent).map_err(|_| AppError::DaemonConfigWriteFailed)?;

    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|_| AppError::DaemonConfigWriteFailed)?;

    match try_lock_exclusive(&file) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
            return Err(AppError::DaemonAlreadyRunning);
        }
        Err(_) => return Err(AppError::DaemonConfigWriteFailed),
    }

    // Keep current owner PID for observability/debugging.
    file.set_len(0)
        .map_err(|_| AppError::DaemonConfigWriteFailed)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|_| AppError::DaemonConfigWriteFailed)?;
    writeln!(file, "{}", std::process::id()).map_err(|_| AppError::DaemonConfigWriteFailed)?;
    file.sync_all()
        .map_err(|_| AppError::DaemonConfigWriteFailed)?;

    Ok(DaemonLock { file })
}

fn try_lock_exclusive(file: &File) -> std::io::Result<()> {
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

struct DaemonLock {
    file: File,
}

impl Drop for DaemonLock {
    fn drop(&mut self) {
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn handle_daemon_event(
    event: DaemonEvent,
    mode: DaemonMode,
    active_recording: &mut Option<ActiveRecording>,
    session_done_tx: &mpsc::Sender<Result<(), AppError>>,
) {
    match event {
        DaemonEvent::StartRecording => {
            if let Some(active) = active_recording.as_mut() {
                if matches!(mode, DaemonMode::Toggle)
                    && !active.stop_requested
                    && active.started_at.elapsed().as_millis() >= MIN_TOGGLE_RECORDING_MS
                {
                    let _ = active.stop_tx.send(());
                    active.stop_requested = true;
                }
                return;
            }
        }
        DaemonEvent::StopRecording => {
            if let Some(active) = active_recording.as_mut() {
                if !active.stop_requested {
                    let _ = active.stop_tx.send(());
                    active.stop_requested = true;
                }
            }
            return;
        }
        DaemonEvent::ListenerFailed => return,
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
        started_at: Instant::now(),
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
    output::emit_daemon(&transcript, daemon_config.output)?;

    Ok(())
}

fn spawn_hotkey_listener(hotkey: DaemonHotkey, mode: DaemonMode, tx: mpsc::Sender<DaemonEvent>) {
    thread::spawn(move || {
        let matcher = Arc::new(Mutex::new(HotkeyMatcher::new(hotkey)));
        let matcher_for_callback = Arc::clone(&matcher);
        let tx_for_callback = tx.clone();

        let result = listen(move |event| {
            let Some((kind, key)) = map_event(event.event_type) else {
                return;
            };

            let signal = match matcher_for_callback.lock() {
                Ok(mut matcher) => matcher.on_event(kind, key),
                Err(_) => None,
            };

            let mapped_event = match (mode, signal) {
                (_, Some(HotkeySignal::Activated)) => Some(DaemonEvent::StartRecording),
                (DaemonMode::Hold, Some(HotkeySignal::Deactivated)) => {
                    Some(DaemonEvent::StopRecording)
                }
                _ => None,
            };

            if let Some(event) = mapped_event {
                let _ = tx_for_callback.send(event);
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
        Key::Alt | Key::AltGr => HotkeyKey::RightOption,
        Key::MetaLeft | Key::MetaRight => HotkeyKey::Command,
        Key::Space => HotkeyKey::Space,
        Key::Function => HotkeyKey::Function,
        _ => HotkeyKey::Other,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use rdev::{EventType, Key};

    use super::{HotkeyEventKind, HotkeyKey, acquire_daemon_lock_at_path, map_event, map_key};
    use crate::error::AppError;

    fn temp_lock_path(name: &str) -> PathBuf {
        let pid = std::process::id();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("current time should be after epoch")
            .as_nanos();

        std::env::temp_dir().join(format!("voico-{name}-{pid}-{nanos}.lock"))
    }

    #[test]
    fn map_key_maps_supported_keys() {
        assert_eq!(map_key(Key::Alt), HotkeyKey::RightOption);
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

    #[test]
    fn daemon_lock_first_acquisition_succeeds() {
        let lock_path = temp_lock_path("first-acquire");
        let lock = acquire_daemon_lock_at_path(&lock_path);

        assert!(lock.is_ok());
        drop(lock);
        let _ = fs::remove_file(lock_path);
    }

    #[test]
    fn daemon_lock_second_acquisition_fails_while_held() {
        let lock_path = temp_lock_path("second-fails");
        let first = acquire_daemon_lock_at_path(&lock_path).expect("first lock should succeed");
        let second = acquire_daemon_lock_at_path(&lock_path);

        assert!(matches!(second, Err(AppError::DaemonAlreadyRunning)));

        drop(first);
        let _ = fs::remove_file(lock_path);
    }

    #[test]
    fn daemon_lock_can_be_reacquired_after_drop() {
        let lock_path = temp_lock_path("reacquire");

        {
            let first = acquire_daemon_lock_at_path(&lock_path).expect("first lock should succeed");
            drop(first);
        }

        let second = acquire_daemon_lock_at_path(&lock_path);
        assert!(second.is_ok());
        drop(second);
        let _ = fs::remove_file(lock_path);
    }
}
