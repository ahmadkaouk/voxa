use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};
use voico_core::domain::{
    ApplyResult, DomainEvent, RecordingOrigin, RuntimeErrorCode, SessionMachine, SessionState,
};
use voico_core::ipc::{
    API_VERSION, ClientEnvelope, ConfigResult, ErrorPayload, EventEnvelope, HealthResult,
    IpcRuntimeState, RequestEnvelope, ResponseEnvelope, ServerEnvelope, StartOrigin,
    StartRecordingParams, StateResult, StopReason, StopRecordingParams, SubscribeParams,
};

const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);

pub fn run(socket_path: PathBuf, running: Arc<AtomicBool>) -> io::Result<()> {
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    if socket_path.exists() {
        fs::remove_file(&socket_path)?;
    }

    let listener = UnixListener::bind(&socket_path)?;
    listener.set_nonblocking(true)?;

    let shared = Arc::new(Mutex::new(SharedState::new()));
    let (event_tx, event_rx) = mpsc::channel::<EventEnvelope>();
    let shared_for_dispatcher = Arc::clone(&shared);
    thread::spawn(move || run_event_dispatcher(event_rx, shared_for_dispatcher));

    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                let shared = Arc::clone(&shared);
                let event_tx = event_tx.clone();
                thread::spawn(move || {
                    let _ = handle_client(stream, shared, event_tx);
                });
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(err) => {
                let _ = fs::remove_file(&socket_path);
                return Err(err);
            }
        }
    }

    let _ = fs::remove_file(&socket_path);
    Ok(())
}

fn handle_client(
    writer: UnixStream,
    shared: Arc<Mutex<SharedState>>,
    event_tx: mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
    writer.set_nonblocking(false)?;
    let read_stream = writer.try_clone()?;
    let connection = ConnectionHandle::new(writer);
    let mut reader = BufReader::new(read_stream);
    let mut line = String::new();
    let mut hello_done = false;

    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line)?;
        if bytes_read == 0 {
            return Ok(());
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let message = serde_json::from_str::<ClientEnvelope>(trimmed);
        let Ok(message) = message else {
            if !hello_done {
                connection.send(ServerEnvelope::HelloError {
                    error: ErrorPayload {
                        code: "INVALID_REQUEST".to_owned(),
                        message: "Expected hello handshake".to_owned(),
                        details: None,
                    },
                })?;
                return Ok(());
            }
            continue;
        };

        if !hello_done {
            match message {
                ClientEnvelope::Hello(hello) if hello.api_version == API_VERSION => {
                    connection.send(ServerEnvelope::HelloOk {
                        api_version: API_VERSION.to_owned(),
                        daemon_version: voico_core::version().to_owned(),
                    })?;
                    hello_done = true;
                }
                ClientEnvelope::Hello(_) => {
                    connection.send(ServerEnvelope::HelloError {
                        error: ErrorPayload {
                            code: "API_VERSION_UNSUPPORTED".to_owned(),
                            message: "Unsupported API version".to_owned(),
                            details: None,
                        },
                    })?;
                    return Ok(());
                }
                _ => {
                    connection.send(ServerEnvelope::HelloError {
                        error: ErrorPayload {
                            code: "INVALID_REQUEST".to_owned(),
                            message: "Expected hello handshake".to_owned(),
                            details: None,
                        },
                    })?;
                    return Ok(());
                }
            }

            continue;
        }

        if let ClientEnvelope::Request(request) = message {
            handle_request(request, &connection, &shared, &event_tx)?;
        }
    }
}

fn handle_request(
    request: RequestEnvelope,
    connection: &ConnectionHandle,
    shared: &Arc<Mutex<SharedState>>,
    event_tx: &mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
    match request.method.as_str() {
        "health" => {
            let result = {
                let state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                HealthResult {
                    status: "ok".to_owned(),
                    uptime_ms: state.started_at.elapsed().as_millis() as u64,
                }
            };

            let payload = json_value(result)?;
            connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                &request.id,
                payload,
            )))
        }
        "get_state" => {
            let result = {
                let state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                state.state_result()
            };

            let payload = json_value(result)?;
            connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                &request.id,
                payload,
            )))
        }
        "start_recording" => {
            let params = request.parse_params::<StartRecordingParams>();
            let params = match params {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            let origin = params.origin.unwrap_or(StartOrigin::Manual);

            let result = {
                let mut state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                let result = state.start_recording(origin);
                dispatch_outbox(&mut state, event_tx)?;
                result
            };

            match result {
                Ok(value) => connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                    &request.id,
                    value,
                ))),
                Err(error) => write_response_error(connection, &request.id, error),
            }
        }
        "stop_recording" => {
            let params = request.parse_params::<StopRecordingParams>();
            let params = match params {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            let reason = params.reason.unwrap_or(StopReason::Manual);

            let result = {
                let mut state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                let result = state.stop_recording(reason);
                dispatch_outbox(&mut state, event_tx)?;
                result
            };

            match result {
                Ok(value) => connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                    &request.id,
                    value,
                ))),
                Err(error) => write_response_error(connection, &request.id, error),
            }
        }
        "get_config" => {
            let result = {
                let state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                state.config_result()
            };

            let payload = json_value(result)?;
            connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                &request.id,
                payload,
            )))
        }
        "set_config" => {
            let params = request.parse_params::<SetConfigParams>();
            let params = match params {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };

            let result = {
                let mut state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                let result = state.set_config(params);
                dispatch_outbox(&mut state, event_tx)?;
                result
            };

            match result {
                Ok(value) => connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                    &request.id,
                    value,
                ))),
                Err(error) => write_response_error(connection, &request.id, error),
            }
        }
        "subscribe" => {
            let params = request.parse_params::<SubscribeParams>();
            if let Err(error) = params {
                return write_response_error(connection, &request.id, error);
            }

            let response = {
                let mut state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                state.subscribe(connection.clone())
            };

            connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                &request.id,
                response,
            )))
        }
        _ => connection.send(ServerEnvelope::Response(ResponseEnvelope::err(
            &request.id,
            "UNKNOWN_METHOD",
            "Unknown method",
        ))),
    }
}

fn write_response_error(
    connection: &ConnectionHandle,
    request_id: &str,
    error: ErrorPayload,
) -> io::Result<()> {
    connection.send(ServerEnvelope::Response(ResponseEnvelope {
        id: request_id.to_owned(),
        ok: false,
        result: None,
        error: Some(error),
    }))
}

fn dispatch_outbox(
    state: &mut SharedState,
    event_tx: &mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
    for event in state.drain_outbox() {
        event_tx
            .send(event)
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "event dispatcher closed"))?;
    }
    Ok(())
}

fn run_event_dispatcher(event_rx: mpsc::Receiver<EventEnvelope>, shared: Arc<Mutex<SharedState>>) {
    while let Ok(event) = event_rx.recv() {
        let envelope = ServerEnvelope::Event(event);

        let mut state = match shared.lock() {
            Ok(state) => state,
            Err(_) => return,
        };

        let mut index = 0;
        while index < state.subscribers.len() {
            if state.subscribers[index].send(envelope.clone()).is_err() {
                state.subscribers.swap_remove(index);
            } else {
                index += 1;
            }
        }
    }
}

#[derive(Clone)]
struct ConnectionHandle {
    tx: mpsc::Sender<ServerEnvelope>,
}

impl ConnectionHandle {
    fn new(mut stream: UnixStream) -> Self {
        let (tx, rx) = mpsc::channel::<ServerEnvelope>();
        thread::spawn(move || {
            while let Ok(envelope) = rx.recv() {
                if write_envelope(&mut stream, &envelope).is_err() {
                    break;
                }
            }
        });

        Self { tx }
    }

    fn send(&self, envelope: ServerEnvelope) -> io::Result<()> {
        self.tx
            .send(envelope)
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "connection closed"))
    }
}

fn write_envelope(stream: &mut UnixStream, envelope: &ServerEnvelope) -> io::Result<()> {
    let serialized = serde_json::to_string(envelope)
        .map_err(|_| io::Error::other("failed to serialize message"))?;
    stream.write_all(serialized.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
}

fn json_value<T: serde::Serialize>(value: T) -> io::Result<Value> {
    serde_json::to_value(value).map_err(|_| io::Error::other("failed to encode json"))
}

#[derive(Debug, Clone)]
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
struct SetConfigParams {
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

struct SharedState {
    machine: SessionMachine,
    session_counter: u64,
    session_id: Option<String>,
    event_seq: u64,
    outbox: Vec<EventEnvelope>,
    started_at: Instant,
    subscribers: Vec<ConnectionHandle>,
    config: DaemonConfig,
}

impl SharedState {
    fn new() -> Self {
        Self {
            machine: SessionMachine::new(),
            session_counter: 0,
            session_id: None,
            event_seq: 0,
            outbox: Vec::new(),
            started_at: Instant::now(),
            subscribers: Vec::new(),
            config: DaemonConfig::default(),
        }
    }

    fn state_result(&self) -> StateResult {
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

    fn config_result(&self) -> ConfigResult {
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

    fn subscribe(&mut self, connection: ConnectionHandle) -> Value {
        self.subscribers.push(connection);
        json!({
            "subscribed": true,
            "current_seq": self.event_seq
        })
    }

    fn set_config(&mut self, params: SetConfigParams) -> Result<Value, ErrorPayload> {
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

        next_config.revision = self.config.revision + 1;
        self.config = next_config;
        Ok(json!({ "revision": self.config.revision }))
    }

    fn start_recording(&mut self, origin: StartOrigin) -> Result<Value, ErrorPayload> {
        if !matches!(self.machine.state(), SessionState::Idle) {
            return Err(ErrorPayload {
                code: "RECORDING_ALREADY_ACTIVE".to_owned(),
                message: "A recording session is already active".to_owned(),
                details: None,
            });
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

    fn stop_recording(&mut self, reason: StopReason) -> Result<Value, ErrorPayload> {
        if !matches!(self.machine.state(), SessionState::Recording(_)) {
            return Err(ErrorPayload {
                code: "RECORDING_NOT_ACTIVE".to_owned(),
                message: "No active recording to stop".to_owned(),
                details: None,
            });
        }

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

        let _ = self
            .machine
            .apply(DomainEvent::TranscriptionSucceeded)
            .map_err(|_| ErrorPayload {
                code: "INVALID_STATE_TRANSITION".to_owned(),
                message: "Could not move to outputting state".to_owned(),
                details: None,
            })?;

        self.emit_event(
            "transcription_ready",
            json!({
                "session_id": self.session_id,
                "text_length": 0
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

        self.emit_event(
            "output_done",
            json!({
                "session_id": self.session_id,
                "clipboard": false,
                "autopaste": false
            }),
        );
        self.session_id = None;
        self.emit_state_changed();

        Ok(json!({ "accepted": true }))
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

    fn drain_outbox(&mut self) -> Vec<EventEnvelope> {
        std::mem::take(&mut self.outbox)
    }
}

fn runtime_error_code_to_string(code: RuntimeErrorCode) -> String {
    match code {
        RuntimeErrorCode::AudioCaptureFailed => "AUDIO_CAPTURE_FAILED".to_owned(),
        RuntimeErrorCode::TranscriptionFailed => "API_REQUEST_FAILED".to_owned(),
        RuntimeErrorCode::OutputFailed => "OUTPUT_FAILED".to_owned(),
    }
}
#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use serde_json::json;
    use voico_core::ipc::ServerEnvelope;

    use super::run;

    fn temp_socket_path(name: &str) -> PathBuf {
        let pid = std::process::id();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("current time should be after epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("voico-v2-{name}-{pid}-{nanos}.sock"))
    }

    fn wait_for_socket(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if path.exists() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }

        panic!("socket was not created in time");
    }

    fn start_server(path: PathBuf) -> (Arc<AtomicBool>, thread::JoinHandle<std::io::Result<()>>) {
        let running = Arc::new(AtomicBool::new(true));
        let running_for_thread = Arc::clone(&running);
        let handle = thread::spawn(move || run(path, running_for_thread));
        (running, handle)
    }

    fn stop_server(
        path: &Path,
        running: Arc<AtomicBool>,
        handle: thread::JoinHandle<std::io::Result<()>>,
    ) {
        running.store(false, Ordering::SeqCst);
        let join_result = handle.join().expect("server thread should join");
        assert!(join_result.is_ok(), "server should stop cleanly");
        let _ = std::fs::remove_file(path);
    }

    fn connect_and_handshake(path: &Path) -> (UnixStream, BufReader<UnixStream>) {
        let mut stream = UnixStream::connect(path).expect("client should connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("read timeout should set");

        let mut reader = BufReader::new(stream.try_clone().expect("clone should succeed"));
        send_json(
            &mut stream,
            json!({
                "type": "hello",
                "api_version": "1.0",
                "client": "test",
                "client_version": "0.0.0"
            }),
        );
        let hello = read_server_envelope(&mut reader);
        match hello {
            ServerEnvelope::HelloOk { .. } => {}
            other => panic!("expected hello_ok, got {:?}", other),
        }

        (stream, reader)
    }

    fn send_json(stream: &mut UnixStream, value: serde_json::Value) {
        let serialized = serde_json::to_string(&value).expect("json should serialize");
        stream
            .write_all(serialized.as_bytes())
            .expect("write should succeed");
        stream
            .write_all(b"\n")
            .expect("newline write should succeed");
        stream.flush().expect("flush should succeed");
    }

    fn read_server_envelope(reader: &mut BufReader<UnixStream>) -> ServerEnvelope {
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .expect("read_line should succeed for server response");
        serde_json::from_str(line.trim()).expect("response should be valid server envelope")
    }

    fn send_request(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        id: &str,
        method: &str,
        params: serde_json::Value,
    ) -> serde_json::Value {
        send_json(
            stream,
            json!({
                "type": "request",
                "id": id,
                "method": method,
                "params": params
            }),
        );
        let envelope = read_server_envelope(reader);
        match envelope {
            ServerEnvelope::Response(response) => {
                assert!(response.ok, "request {method} should succeed");
                response
                    .result
                    .expect("successful response should include result")
            }
            other => panic!("expected response envelope, got {:?}", other),
        }
    }

    fn send_request_expect_error(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        id: &str,
        method: &str,
        params: serde_json::Value,
    ) -> String {
        send_json(
            stream,
            json!({
                "type": "request",
                "id": id,
                "method": method,
                "params": params
            }),
        );
        let envelope = read_server_envelope(reader);
        match envelope {
            ServerEnvelope::Response(response) => {
                assert!(!response.ok, "request {method} should fail");
                response
                    .error
                    .expect("failed response should include error")
                    .code
            }
            other => panic!("expected response envelope, got {:?}", other),
        }
    }

    #[test]
    fn daemon_handles_basic_start_stop_flow() {
        let path = temp_socket_path("basic-flow");
        let (running, handle) = start_server(path.clone());
        wait_for_socket(&path);

        let (mut stream, mut reader) = connect_and_handshake(&path);
        let state = send_request(&mut stream, &mut reader, "1", "get_state", json!({}));
        assert_eq!(state["state"], "idle");

        let _ = send_request(
            &mut stream,
            &mut reader,
            "2",
            "start_recording",
            json!({"origin":"manual"}),
        );
        let state_after_start = send_request(&mut stream, &mut reader, "3", "get_state", json!({}));
        assert_eq!(state_after_start["state"], "recording");

        let _ = send_request(
            &mut stream,
            &mut reader,
            "4",
            "stop_recording",
            json!({"reason":"manual"}),
        );
        let state_after_stop = send_request(&mut stream, &mut reader, "5", "get_state", json!({}));
        assert_eq!(state_after_stop["state"], "idle");

        stop_server(&path, running, handle);
    }

    #[test]
    fn set_config_failure_does_not_mutate_existing_config() {
        let path = temp_socket_path("cfg");
        let (running, handle) = start_server(path.clone());
        wait_for_socket(&path);

        let (mut stream, mut reader) = connect_and_handshake(&path);

        let initial = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
        assert_eq!(initial["toggle_hotkey"], "right_option");
        assert_eq!(initial["hold_hotkey"], "fn");
        let initial_revision = initial["revision"].as_u64().unwrap_or(0);

        let error_code = send_request_expect_error(
            &mut stream,
            &mut reader,
            "2",
            "set_config",
            json!({
                "hold_hotkey": "right_option"
            }),
        );
        assert_eq!(error_code, "CONFIG_HOTKEY_CONFLICT");

        let after = send_request(&mut stream, &mut reader, "3", "get_config", json!({}));
        assert_eq!(after["toggle_hotkey"], "right_option");
        assert_eq!(after["hold_hotkey"], "fn");
        assert_eq!(after["revision"].as_u64().unwrap_or(0), initial_revision);

        stop_server(&path, running, handle);
    }

    #[test]
    fn subscriber_receives_ordered_events() {
        let path = temp_socket_path("subscribe-flow");
        let (running, handle) = start_server(path.clone());
        wait_for_socket(&path);

        let (mut subscriber_stream, mut subscriber_reader) = connect_and_handshake(&path);
        let _ = send_request(
            &mut subscriber_stream,
            &mut subscriber_reader,
            "1",
            "subscribe",
            json!({}),
        );

        let (mut control_stream, mut control_reader) = connect_and_handshake(&path);
        let _ = send_request(
            &mut control_stream,
            &mut control_reader,
            "2",
            "start_recording",
            json!({"origin":"manual"}),
        );
        let _ = send_request(
            &mut control_stream,
            &mut control_reader,
            "3",
            "stop_recording",
            json!({"reason":"manual"}),
        );

        let mut last_seq = 0_u64;
        let mut saw_recording_state = false;
        let mut saw_idle_state = false;

        for _ in 0..16 {
            let envelope = read_server_envelope(&mut subscriber_reader);
            if let ServerEnvelope::Event(event) = envelope {
                assert!(event.seq > last_seq, "event seq should be increasing");
                last_seq = event.seq;

                if event.name == "state_changed" && event.data["state"] == "recording" {
                    saw_recording_state = true;
                }
                if saw_recording_state
                    && event.name == "state_changed"
                    && event.data["state"] == "idle"
                {
                    saw_idle_state = true;
                    break;
                }
            }
        }

        assert!(saw_recording_state, "subscriber should see recording state");
        assert!(
            saw_idle_state,
            "subscriber should eventually see idle state"
        );

        stop_server(&path, running, handle);
    }
}
