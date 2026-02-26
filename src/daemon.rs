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
use crate::daemon_config::{ConfigStore, DaemonHotkey};
use crate::error::AppError;
use crate::hotkey::{HotkeyEventKind, HotkeyKey, HotkeyMatcher, HotkeySignal};
use crate::output;
use crate::stt;

const LISTENER_POLL_INTERVAL_MS: u64 = 100;
const MIN_TOGGLE_RECORDING_MS: u128 = 350;
const DAEMON_LOCK_FILE_NAME: &str = "daemon.lock";

enum DaemonEvent {
    ToggleActivated,
    HoldActivated,
    HoldDeactivated,
    ListenerFailed,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum RecordingOrigin {
    Toggle,
    Hold,
}

struct ActiveRecording {
    stop_tx: mpsc::Sender<()>,
    stop_requested: bool,
    started_at: Instant,
    origin: RecordingOrigin,
}

enum RecordingState {
    Idle,
    Recording(ActiveRecording),
}

struct DaemonRunner {
    recording_state: RecordingState,
    session_done_tx: mpsc::Sender<Result<(), AppError>>,
}

pub fn run() -> Result<(), AppError> {
    let _daemon_lock = acquire_daemon_lock()?;
    let daemon_cfg = ConfigStore::new()?.load()?;

    println!("OK DAEMON_STARTED");
    println!("toggle_hotkey = {}", daemon_cfg.toggle_hotkey.as_str());
    println!("hold_hotkey = {}", daemon_cfg.hold_hotkey.as_str());

    let (daemon_tx, daemon_rx) = mpsc::channel::<DaemonEvent>();
    spawn_hotkey_listener(daemon_cfg.toggle_hotkey, daemon_cfg.hold_hotkey, daemon_tx);

    let (session_done_tx, session_done_rx) = mpsc::channel::<Result<(), AppError>>();
    let mut runner = DaemonRunner::new(session_done_tx);

    loop {
        while let Ok(result) = session_done_rx.try_recv() {
            runner.on_session_done(result);
        }

        match daemon_rx.recv_timeout(Duration::from_millis(LISTENER_POLL_INTERVAL_MS)) {
            Ok(DaemonEvent::ListenerFailed) => return Err(AppError::DaemonListenerUnavailable),
            Ok(event) => runner.handle_event(event),
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
    let store = ConfigStore::new()?;
    let config_path = store.path();
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

impl DaemonRunner {
    fn new(session_done_tx: mpsc::Sender<Result<(), AppError>>) -> Self {
        Self {
            recording_state: RecordingState::Idle,
            session_done_tx,
        }
    }

    fn on_session_done(&mut self, result: Result<(), AppError>) {
        self.recording_state = RecordingState::Idle;
        if let Err(err) = result {
            err.print();
        }
    }

    fn handle_event(&mut self, event: DaemonEvent) {
        match self.action_for_event(event) {
            RunnerAction::None => {}
            RunnerAction::Start(origin) => self.start_recording(origin),
            RunnerAction::Stop => self.on_stop_recording(),
        }
    }

    fn action_for_event(&self, event: DaemonEvent) -> RunnerAction {
        match event {
            DaemonEvent::ToggleActivated => match &self.recording_state {
                RecordingState::Idle => RunnerAction::Start(RecordingOrigin::Toggle),
                RecordingState::Recording(active)
                    if !active.stop_requested
                        && active.started_at.elapsed().as_millis() >= MIN_TOGGLE_RECORDING_MS =>
                {
                    RunnerAction::Stop
                }
                _ => RunnerAction::None,
            },
            DaemonEvent::HoldActivated => match &self.recording_state {
                RecordingState::Idle => RunnerAction::Start(RecordingOrigin::Hold),
                RecordingState::Recording(_) => RunnerAction::None,
            },
            DaemonEvent::HoldDeactivated => match &self.recording_state {
                RecordingState::Recording(active)
                    if !active.stop_requested && active.origin == RecordingOrigin::Hold =>
                {
                    RunnerAction::Stop
                }
                _ => RunnerAction::None,
            },
            DaemonEvent::ListenerFailed => RunnerAction::None,
        }
    }

    fn start_recording(&mut self, origin: RecordingOrigin) {
        if matches!(self.recording_state, RecordingState::Recording(_)) {
            return;
        }

        let app_config = match config::load_defaults() {
            Ok(config) => config,
            Err(err) => {
                err.print();
                return;
            }
        };

        let (stop_tx, stop_rx) = mpsc::channel();
        let done_tx = self.session_done_tx.clone();

        println!("OK RECORDING_STARTED");

        thread::spawn(move || {
            let result = run_session(app_config, stop_rx);
            let _ = done_tx.send(result);
        });

        self.recording_state = RecordingState::Recording(ActiveRecording {
            stop_tx,
            stop_requested: false,
            started_at: Instant::now(),
            origin,
        });
    }

    fn on_stop_recording(&mut self) {
        let RecordingState::Recording(active) = &mut self.recording_state else {
            return;
        };

        if !active.stop_requested {
            let _ = active.stop_tx.send(());
            active.stop_requested = true;
        }
    }
}

enum RunnerAction {
    None,
    Start(RecordingOrigin),
    Stop,
}

fn run_session(config: config::AppConfig, stop_rx: mpsc::Receiver<()>) -> Result<(), AppError> {
    let captured = audio::record_until_stop(stop_rx)?;
    println!("OK RECORDING_STOPPED");

    if captured.max_duration_reached {
        println!(
            "WARN AUDIO_MAX_DURATION_REACHED: recording reached max duration and was stopped."
        );
    }

    let stt_client = stt::SttClient::new(&config.api_key, config.model)?;
    let transcript = stt_client.transcribe(&captured.wav_bytes)?;

    println!("OK TRANSCRIPTION_READY");
    output::emit_daemon(&transcript)?;

    Ok(())
}

fn spawn_hotkey_listener(
    toggle_hotkey: DaemonHotkey,
    hold_hotkey: DaemonHotkey,
    tx: mpsc::Sender<DaemonEvent>,
) {
    thread::spawn(move || {
        let toggle_matcher = Arc::new(Mutex::new(HotkeyMatcher::new(toggle_hotkey)));
        let hold_matcher = Arc::new(Mutex::new(HotkeyMatcher::new(hold_hotkey)));
        let tx_for_callback = tx.clone();

        let result = listen(move |event| {
            let Some((kind, key)) = map_event(event.event_type) else {
                return;
            };

            let toggle_signal = match toggle_matcher.lock() {
                Ok(mut matcher) => matcher.on_event(kind, key),
                Err(_) => None,
            };
            let hold_signal = match hold_matcher.lock() {
                Ok(mut matcher) => matcher.on_event(kind, key),
                Err(_) => None,
            };

            let mapped_event = match (toggle_signal, hold_signal) {
                (Some(HotkeySignal::Activated), _) => Some(DaemonEvent::ToggleActivated),
                (_, Some(HotkeySignal::Activated)) => Some(DaemonEvent::HoldActivated),
                (_, Some(HotkeySignal::Deactivated)) => Some(DaemonEvent::HoldDeactivated),
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
    use std::sync::mpsc;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use rdev::{EventType, Key};

    use super::{
        ActiveRecording, DaemonEvent, DaemonRunner, HotkeyEventKind, HotkeyKey,
        MIN_TOGGLE_RECORDING_MS, RecordingOrigin, RecordingState, RunnerAction,
        acquire_daemon_lock_at_path, map_event, map_key,
    };
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

    fn idle_runner() -> DaemonRunner {
        let (done_tx, _done_rx) = mpsc::channel();
        DaemonRunner::new(done_tx)
    }

    fn runner_with_active_recording(
        origin: RecordingOrigin,
        started_ms_ago: u64,
    ) -> (DaemonRunner, mpsc::Receiver<()>) {
        let (done_tx, _done_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();

        let runner = DaemonRunner {
            recording_state: RecordingState::Recording(ActiveRecording {
                stop_tx,
                stop_requested: false,
                started_at: Instant::now() - Duration::from_millis(started_ms_ago),
                origin,
            }),
            session_done_tx: done_tx,
        };

        (runner, stop_rx)
    }

    #[test]
    fn toggle_activation_starts_when_idle() {
        let runner = idle_runner();

        let action = runner.action_for_event(DaemonEvent::ToggleActivated);
        assert!(matches!(
            action,
            RunnerAction::Start(RecordingOrigin::Toggle)
        ));
    }

    #[test]
    fn hold_activation_starts_when_idle() {
        let runner = idle_runner();

        let action = runner.action_for_event(DaemonEvent::HoldActivated);
        assert!(matches!(action, RunnerAction::Start(RecordingOrigin::Hold)));
    }

    #[test]
    fn hold_release_stops_hold_started_recording() {
        let (mut runner, stop_rx) = runner_with_active_recording(RecordingOrigin::Hold, 0);

        runner.handle_event(DaemonEvent::HoldDeactivated);

        assert!(stop_rx.recv_timeout(Duration::from_millis(25)).is_ok());
    }

    #[test]
    fn hold_release_ignored_for_toggle_started_recording() {
        let (mut runner, stop_rx) = runner_with_active_recording(RecordingOrigin::Toggle, 0);

        runner.handle_event(DaemonEvent::HoldDeactivated);

        assert!(matches!(
            stop_rx.recv_timeout(Duration::from_millis(25)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
    }

    #[test]
    fn toggle_activation_stops_hold_started_recording_after_debounce() {
        let (mut runner, stop_rx) = runner_with_active_recording(
            RecordingOrigin::Hold,
            (MIN_TOGGLE_RECORDING_MS + 1) as u64,
        );

        runner.handle_event(DaemonEvent::ToggleActivated);

        assert!(stop_rx.recv_timeout(Duration::from_millis(25)).is_ok());
    }

    #[test]
    fn toggle_activation_respects_debounce_threshold() {
        let (runner, _stop_rx) = runner_with_active_recording(RecordingOrigin::Toggle, 0);

        let action = runner.action_for_event(DaemonEvent::ToggleActivated);
        assert!(matches!(action, RunnerAction::None));
    }
}
