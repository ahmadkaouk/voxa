use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use std::{env, fs};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use voico_core::app::SessionRuntime;
use voico_core::domain::{
    ApplyResult, DomainEvent, RecordingOrigin, RuntimeErrorCode, SessionMachine, SessionState,
};
use voico_core::ipc::{
    ApiKeyStatusResult, ConfigResult, ErrorPayload, EventEnvelope, IpcRuntimeState, ServerEnvelope,
    SetApiKeyParams, StartOrigin, StateResult, StopReason,
};

use super::connection::ConnectionHandle;
use crate::adapters::build_runtime_for_output_mode;
use crate::secrets::{ApiKeyStore, build_api_key_store};
#[cfg(test)]
use crate::secrets::{in_memory_api_key_store, in_memory_api_key_store_with_shared};

#[derive(Debug, Clone, Serialize)]
struct DaemonConfig {
    toggle_hotkey: String,
    hold_hotkey: String,
    model: String,
    output_mode: String,
    max_recording_seconds: u64,
    api_key_source: String,
    revision: u64,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            toggle_hotkey: "right_option".to_owned(),
            hold_hotkey: "fn".to_owned(),
            model: "gpt-4o-mini-transcribe".to_owned(),
            output_mode: "clipboard_autopaste".to_owned(),
            max_recording_seconds: 300,
            api_key_source: "keychain".to_owned(),
            revision: 1,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct SetConfigParams {
    #[serde(default)]
    toggle_hotkey: Option<String>,
    #[serde(default)]
    hold_hotkey: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    output_mode: Option<String>,
    #[serde(default)]
    max_recording_seconds: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
struct ConfigFile {
    #[serde(default)]
    toggle_hotkey: Option<String>,
    #[serde(default)]
    hold_hotkey: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    output_mode: Option<String>,
    #[serde(default)]
    max_recording_seconds: Option<u64>,
    #[serde(default)]
    api_key_source: Option<String>,
    #[serde(default)]
    revision: Option<u64>,
}

pub(super) struct SharedState {
    machine: SessionMachine,
    session_counter: u64,
    session_id: Option<String>,
    event_seq: u64,
    outbox: Vec<EventEnvelope>,
    started_at: Instant,
    recording_deadline: Option<Instant>,
    subscribers: Vec<ConnectionHandle>,
    config: DaemonConfig,
    runtime: SessionRuntime,
    config_path: Option<PathBuf>,
    api_keys: Box<dyn ApiKeyStore>,
}

impl SharedState {
    pub(super) fn from_disk() -> io::Result<Self> {
        let config_path = default_config_path()?;
        let config = load_config_from_disk(&config_path);
        let runtime = build_runtime_for_output_mode(
            &config.output_mode,
            &config.model,
            &config.api_key_source,
        );
        let api_keys = build_api_key_store(&config.api_key_source);
        Ok(Self::with_config_and_runtime(
            config,
            runtime,
            Some(config_path),
            api_keys,
        ))
    }

    #[cfg(test)]
    pub(super) fn with_runtime(runtime: SessionRuntime) -> Self {
        Self::with_config_and_runtime(
            DaemonConfig::default(),
            runtime,
            None,
            in_memory_api_key_store(),
        )
    }

    #[cfg(test)]
    pub(super) fn with_runtime_and_max_recording_seconds(
        runtime: SessionRuntime,
        max_recording_seconds: u64,
    ) -> Self {
        let mut config = DaemonConfig::default();
        config.max_recording_seconds = max_recording_seconds.max(1);
        Self::with_config_and_runtime(config, runtime, None, in_memory_api_key_store())
    }

    #[cfg(test)]
    pub(super) fn with_runtime_and_shared_api_keys(
        runtime: SessionRuntime,
        shared: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    ) -> Self {
        Self::with_config_and_runtime(
            DaemonConfig::default(),
            runtime,
            None,
            in_memory_api_key_store_with_shared(shared),
        )
    }

    fn with_config_and_runtime(
        config: DaemonConfig,
        runtime: SessionRuntime,
        config_path: Option<PathBuf>,
        api_keys: Box<dyn ApiKeyStore>,
    ) -> Self {
        Self {
            machine: SessionMachine::new(),
            session_counter: 0,
            session_id: None,
            event_seq: 0,
            outbox: Vec::new(),
            started_at: Instant::now(),
            recording_deadline: None,
            subscribers: Vec::new(),
            config,
            runtime,
            config_path,
            api_keys,
        }
    }

    pub(super) fn uptime_ms(&self) -> u64 {
        self.started_at.elapsed().as_millis() as u64
    }

    pub(super) fn state_result(&self) -> StateResult {
        let state = match self.machine.state() {
            SessionState::Idle => IpcRuntimeState::Idle,
            SessionState::Recording(_) => IpcRuntimeState::Recording,
            SessionState::Transcribing => IpcRuntimeState::Transcribing,
            SessionState::Outputting => IpcRuntimeState::Outputting,
            SessionState::Error => IpcRuntimeState::Error,
        };

        let recording_origin = match self.machine.state() {
            SessionState::Recording(recording) => Some(match recording.origin {
                RecordingOrigin::Manual => StartOrigin::Manual,
                RecordingOrigin::Toggle => StartOrigin::HotkeyToggle,
                RecordingOrigin::Hold => StartOrigin::HotkeyHold,
            }),
            _ => None,
        };

        let last_error = self.machine.last_error().map(runtime_error_code_to_string);

        StateResult {
            state,
            session: self.session_id.clone(),
            recording_origin,
            is_busy: !matches!(self.machine.state(), SessionState::Idle),
            last_error,
            config_revision: self.config.revision,
            event_seq: self.event_seq,
        }
    }

    pub(super) fn config_result(&self) -> ConfigResult {
        ConfigResult {
            toggle_hotkey: self.config.toggle_hotkey.clone(),
            hold_hotkey: self.config.hold_hotkey.clone(),
            model: self.config.model.clone(),
            output_mode: self.config.output_mode.clone(),
            max_recording_seconds: self.config.max_recording_seconds,
            api_key_source: self.config.api_key_source.clone(),
            revision: self.config.revision,
        }
    }

    pub(super) fn subscribe(&mut self, connection: ConnectionHandle) -> Value {
        self.subscribers.push(connection);
        json!({
            "subscribed": true,
            "current_seq": self.event_seq
        })
    }

    pub(super) fn notify_subscribers(&mut self, envelope: &ServerEnvelope) {
        let mut index = 0;
        while index < self.subscribers.len() {
            if self.subscribers[index].send(envelope.clone()).is_err() {
                self.subscribers.swap_remove(index);
            } else {
                index += 1;
            }
        }
    }

    pub(super) fn set_config(&mut self, params: SetConfigParams) -> Result<Value, ErrorPayload> {
        let mut next_config = self.config.clone();

        if let Some(toggle_hotkey) = params.toggle_hotkey {
            next_config.toggle_hotkey = toggle_hotkey;
        }
        if let Some(hold_hotkey) = params.hold_hotkey {
            next_config.hold_hotkey = hold_hotkey;
        }
        if let Some(model) = params.model {
            next_config.model = model;
        }
        if let Some(output_mode) = params.output_mode {
            next_config.output_mode = output_mode;
        }
        if let Some(max_recording_seconds) = params.max_recording_seconds {
            if max_recording_seconds == 0 {
                return Err(ErrorPayload {
                    code: "CONFIG_INVALID".to_owned(),
                    message: "max_recording_seconds must be greater than 0".to_owned(),
                    details: None,
                });
            }
            next_config.max_recording_seconds = max_recording_seconds;
        }

        if next_config.toggle_hotkey == next_config.hold_hotkey {
            return Err(ErrorPayload {
                code: "CONFIG_HOTKEY_CONFLICT".to_owned(),
                message: "toggle_hotkey and hold_hotkey cannot be the same".to_owned(),
                details: None,
            });
        }

        if !is_valid_model(&next_config.model) {
            return Err(ErrorPayload {
                code: "CONFIG_INVALID".to_owned(),
                message: "model is not supported".to_owned(),
                details: None,
            });
        }

        if !is_valid_output_mode(&next_config.output_mode) {
            return Err(ErrorPayload {
                code: "CONFIG_INVALID".to_owned(),
                message: "output_mode is not supported".to_owned(),
                details: None,
            });
        }

        next_config.revision = self.config.revision + 1;
        if let Some(path) = self.config_path.as_deref() {
            persist_config_to_disk(path, &next_config).map_err(|_| ErrorPayload {
                code: "INTERNAL_ERROR".to_owned(),
                message: "Failed to persist config".to_owned(),
                details: None,
            })?;
        }
        self.runtime = build_runtime_for_output_mode(
            &next_config.output_mode,
            &next_config.model,
            &next_config.api_key_source,
        );
        self.config = next_config;
        Ok(json!({ "revision": self.config.revision }))
    }

    pub(super) fn api_key_status(&self) -> Result<ApiKeyStatusResult, ErrorPayload> {
        let is_set = self
            .api_keys
            .get_api_key()
            .map_err(|_| ErrorPayload {
                code: "INTERNAL_ERROR".to_owned(),
                message: "Failed to read API key".to_owned(),
                details: None,
            })?
            .is_some();

        Ok(ApiKeyStatusResult {
            source: self.config.api_key_source.clone(),
            is_set,
        })
    }

    pub(super) fn set_api_key(&self, params: SetApiKeyParams) -> Result<Value, ErrorPayload> {
        let api_key = params.api_key.trim();
        if api_key.is_empty() {
            return Err(ErrorPayload {
                code: "INVALID_PARAMS".to_owned(),
                message: "api_key cannot be empty".to_owned(),
                details: None,
            });
        }

        self.api_keys
            .set_api_key(api_key)
            .map_err(|_| ErrorPayload {
                code: "INTERNAL_ERROR".to_owned(),
                message: "Failed to store API key".to_owned(),
                details: None,
            })?;

        Ok(json!({
            "stored": true,
            "source": self.config.api_key_source.clone()
        }))
    }

    pub(super) fn start_recording(&mut self, origin: StartOrigin) -> Result<Value, ErrorPayload> {
        if !matches!(self.machine.state(), SessionState::Idle) {
            return Ok(json!({ "accepted": true }));
        }

        let event = match origin {
            StartOrigin::Manual => DomainEvent::ManualPressed,
            StartOrigin::HotkeyToggle => DomainEvent::TogglePressed,
            StartOrigin::HotkeyHold => DomainEvent::HoldPressed,
        };

        let result = self.machine.apply(event);
        match result {
            Ok(ApplyResult::Transitioned) => {
                self.session_counter += 1;
                self.session_id = Some(format!("s-{}", self.session_counter));

                if let Err(code) = self.runtime.start_recording() {
                    let _ = self.machine.apply(DomainEvent::RecordingFailed);
                    self.machine.set_last_error(code);
                    self.session_id = None;
                    self.recording_deadline = None;
                    self.emit_state_changed();
                    return Err(runtime_error_payload(code, "Failed to start recording"));
                }

                self.recording_deadline =
                    Some(Instant::now() + Duration::from_secs(self.config.max_recording_seconds));
                self.emit_state_changed();
                self.emit_event(
                    "recording_started",
                    json!({
                        "session_id": self.session_id,
                        "origin": origin
                    }),
                );
                Ok(json!({ "accepted": true }))
            }
            Ok(ApplyResult::Noop) => Ok(json!({ "accepted": true })),
            Err(_) => Err(ErrorPayload {
                code: "INVALID_STATE_TRANSITION".to_owned(),
                message: "Invalid start_recording transition".to_owned(),
                details: None,
            }),
        }
    }

    pub(super) fn stop_recording(&mut self, reason: StopReason) -> Result<Value, ErrorPayload> {
        if !matches!(self.machine.state(), SessionState::Recording(_)) {
            return Ok(json!({ "accepted": true }));
        }
        self.recording_deadline = None;

        let stop_event = match reason {
            StopReason::Manual | StopReason::HotkeyToggle => DomainEvent::TogglePressed,
            StopReason::HotkeyHoldRelease => DomainEvent::HoldReleased,
            StopReason::MaxDuration => DomainEvent::MaxDurationReached,
        };

        let _ = self.machine.apply(stop_event).map_err(|_| ErrorPayload {
            code: "INVALID_STATE_TRANSITION".to_owned(),
            message: "Invalid stop request transition".to_owned(),
            details: None,
        })?;

        let audio = match self.runtime.stop_recording() {
            Ok(audio) => audio,
            Err(code) => {
                let _ = self.machine.apply(DomainEvent::RecordingFailed);
                self.machine.set_last_error(code);
                self.session_id = None;
                self.emit_state_changed();
                return Err(runtime_error_payload(code, "Failed to stop audio capture"));
            }
        };

        let _ = self
            .machine
            .apply(DomainEvent::RecordingStopped)
            .map_err(|_| ErrorPayload {
                code: "INVALID_STATE_TRANSITION".to_owned(),
                message: "Could not move to transcribing state".to_owned(),
                details: None,
            })?;

        self.emit_event(
            "recording_stopped",
            json!({
                "session_id": self.session_id,
                "reason": reason
            }),
        );
        self.emit_state_changed();
        self.emit_event(
            "transcribing_started",
            json!({
                "session_id": self.session_id
            }),
        );

        let text = match self.runtime.transcribe(audio) {
            Ok(text) => text,
            Err(code) => {
                let _ = self.machine.apply(DomainEvent::TranscriptionFailed);
                self.machine.set_last_error(code);
                self.session_id = None;
                self.emit_state_changed();
                return Err(runtime_error_payload(code, "Transcription failed"));
            }
        };

        let _ = self
            .machine
            .apply(DomainEvent::TranscriptionSucceeded)
            .map_err(|_| ErrorPayload {
                code: "INVALID_STATE_TRANSITION".to_owned(),
                message: "Could not move to outputting state".to_owned(),
                details: None,
            })?;

        let text_length = text.chars().count();
        self.emit_event(
            "transcription_ready",
            json!({
                "session_id": self.session_id,
                "text": text.clone(),
                "text_length": text_length
            }),
        );
        self.emit_state_changed();

        let _ = self
            .machine
            .apply(DomainEvent::OutputCompleted)
            .map_err(|_| ErrorPayload {
                code: "INVALID_STATE_TRANSITION".to_owned(),
                message: "Could not complete output transition".to_owned(),
                details: None,
            })?;
        self.session_id = None;
        self.emit_state_changed();

        Ok(json!({
            "accepted": true,
            "text": text
        }))
    }

    pub(super) fn enforce_max_duration_if_needed(&mut self) {
        if !matches!(self.machine.state(), SessionState::Recording(_)) {
            self.recording_deadline = None;
            return;
        }

        let Some(deadline) = self.recording_deadline else {
            return;
        };
        if Instant::now() < deadline {
            return;
        }

        let _ = self.stop_recording(StopReason::MaxDuration);
    }

    fn emit_state_changed(&mut self) {
        let state = self.state_result();
        if let Ok(data) = serde_json::to_value(state) {
            self.emit_event("state_changed", data);
        }
    }

    fn emit_event(&mut self, name: &str, data: Value) {
        self.event_seq += 1;
        self.outbox.push(EventEnvelope {
            name: name.to_owned(),
            seq: self.event_seq,
            data,
        });
    }

    pub(super) fn drain_outbox(&mut self) -> Vec<EventEnvelope> {
        std::mem::take(&mut self.outbox)
    }
}

fn runtime_error_code_to_string(code: RuntimeErrorCode) -> String {
    match code {
        RuntimeErrorCode::AudioCaptureFailed => "AUDIO_CAPTURE_FAILED".to_owned(),
        RuntimeErrorCode::ApiAuthFailed => "API_AUTH_FAILED".to_owned(),
        RuntimeErrorCode::ApiRateLimited => "API_RATE_LIMITED".to_owned(),
        RuntimeErrorCode::ApiRequestFailed => "API_REQUEST_FAILED".to_owned(),
        RuntimeErrorCode::ApiNetworkFailed => "API_NETWORK_FAILED".to_owned(),
        RuntimeErrorCode::ApiResponseInvalid => "API_RESPONSE_INVALID".to_owned(),
        RuntimeErrorCode::ApiEmptyTranscript => "API_EMPTY_TRANSCRIPT".to_owned(),
        RuntimeErrorCode::OutputFailed => "OUTPUT_FAILED".to_owned(),
    }
}

fn runtime_error_payload(code: RuntimeErrorCode, message: &str) -> ErrorPayload {
    ErrorPayload {
        code: runtime_error_code_to_string(code),
        message: message.to_owned(),
        details: None,
    }
}

fn is_valid_model(model: &str) -> bool {
    matches!(model, "gpt-4o-mini-transcribe" | "gpt-4o-transcribe")
}

fn is_valid_output_mode(mode: &str) -> bool {
    matches!(mode, "clipboard_autopaste" | "clipboard_only" | "none")
}

fn default_config_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VOICO_V2_CONFIG_PATH") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("HOME is not set"))?;

    Ok(home.join("Library/Application Support/voico-v2/config.toml"))
}

fn load_config_from_disk(path: &Path) -> DaemonConfig {
    let mut config = DaemonConfig::default();

    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return config,
        Err(_) => return config,
    };

    let parsed = match toml::from_str::<ConfigFile>(&contents) {
        Ok(parsed) => parsed,
        Err(_) => return config,
    };

    if let Some(toggle_hotkey) = parsed.toggle_hotkey {
        config.toggle_hotkey = toggle_hotkey;
    }
    if let Some(hold_hotkey) = parsed.hold_hotkey {
        config.hold_hotkey = hold_hotkey;
    }
    if let Some(model) = parsed.model {
        config.model = model;
    }
    if let Some(output_mode) = parsed.output_mode {
        config.output_mode = output_mode;
    }
    if let Some(max_recording_seconds) = parsed.max_recording_seconds {
        if max_recording_seconds == 0 {
            return DaemonConfig::default();
        }
        config.max_recording_seconds = max_recording_seconds;
    }
    if let Some(api_key_source) = parsed.api_key_source {
        config.api_key_source = api_key_source;
    }
    if let Some(revision) = parsed.revision {
        config.revision = revision.max(1);
    }

    if config.toggle_hotkey == config.hold_hotkey
        || !is_valid_model(&config.model)
        || !is_valid_output_mode(&config.output_mode)
    {
        return DaemonConfig::default();
    }

    config
}

fn persist_config_to_disk(path: &Path, config: &DaemonConfig) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let serialized =
        toml::to_string_pretty(config).map_err(|_| io::Error::other("failed to encode config"))?;
    let temp_path = path.with_extension("tmp");
    fs::write(&temp_path, serialized)?;
    fs::rename(temp_path, path)
}
