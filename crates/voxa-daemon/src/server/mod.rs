mod connection;
mod socket;
mod state;

#[cfg(test)]
mod tests;

use std::io::{self, BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError, mpsc};
use std::thread;
use std::time::Duration;

use serde_json::Value;
use voxa_core::ipc::{
    API_VERSION, ClientEnvelope, ErrorPayload, EventEnvelope, HealthResult, RequestEnvelope,
    ResponseEnvelope, ServerEnvelope, SetApiKeyParams, StartOrigin, StartRecordingParams,
    StopRecordingParams, SubscribeParams,
};

use self::connection::ConnectionHandle;
use self::state::{
    CaptureAction, CaptureCommand, PendingTranscription, SessionAction, SetConfigParams,
    SharedState,
};

const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const MAX_DURATION_POLL_INTERVAL: Duration = Duration::from_millis(100);

struct ServerState {
    state: Mutex<SharedState>,
    // Capture commands take this lock before state. Read-only IPC never takes it.
    capture: Mutex<()>,
}

impl ServerState {
    fn lock(&self) -> io::Result<MutexGuard<'_, SharedState>> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("state poisoned"))
    }
}

pub fn run(socket_path: PathBuf, running: Arc<AtomicBool>) -> io::Result<()> {
    let state = SharedState::from_disk()?;
    run_with_state(socket_path, running, state)
}

#[cfg(test)]
fn run_with_runtime(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    runtime: voxa_core::app::SessionRuntime,
) -> io::Result<()> {
    let state = SharedState::with_runtime(runtime);
    run_with_state(socket_path, running, state)
}

#[cfg(test)]
fn run_with_runtime_and_max_recording_seconds(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    runtime: voxa_core::app::SessionRuntime,
    max_recording_seconds: u64,
) -> io::Result<()> {
    let state = SharedState::with_runtime_and_max_recording_seconds(runtime, max_recording_seconds);
    run_with_state(socket_path, running, state)
}

#[cfg(test)]
fn run_with_runtime_and_shared_api_keys(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    runtime: voxa_core::app::SessionRuntime,
    shared: Arc<Mutex<Option<String>>>,
) -> io::Result<()> {
    let state = SharedState::with_runtime_and_shared_api_keys(runtime, shared);
    run_with_state(socket_path, running, state)
}

fn run_with_state(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    state: SharedState,
) -> io::Result<()> {
    let socket = socket::BoundSocket::bind(socket_path)?;

    let shared = Arc::new(ServerState {
        state: Mutex::new(state),
        capture: Mutex::new(()),
    });
    let (event_tx, event_rx) = mpsc::channel::<EventEnvelope>();
    let shared_for_dispatcher = Arc::clone(&shared);
    thread::spawn(move || run_event_dispatcher(event_rx, shared_for_dispatcher));
    let shared_for_watchdog = Arc::clone(&shared);
    let running_for_watchdog = Arc::clone(&running);
    let event_tx_for_watchdog = event_tx.clone();
    thread::spawn(move || {
        run_max_duration_watchdog(
            running_for_watchdog,
            shared_for_watchdog,
            event_tx_for_watchdog,
        )
    });

    while running.load(Ordering::SeqCst) {
        match socket.listener.accept() {
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
                return Err(err);
            }
        }
    }

    Ok(())
}

fn handle_client(
    writer: UnixStream,
    shared: Arc<ServerState>,
    event_tx: mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
    writer.set_nonblocking(false)?;
    let read_stream = writer.try_clone()?;
    let connection = ConnectionHandle::new(writer)?;
    let result = read_client_messages(read_stream, &connection, &shared, &event_tx);
    if let Ok(mut state) = shared.lock() {
        state.unsubscribe(&connection);
    }
    connection.close();
    result
}

fn read_client_messages(
    read_stream: UnixStream,
    connection: &ConnectionHandle,
    shared: &ServerState,
    event_tx: &mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
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
                    error: ErrorPayload::new("INVALID_REQUEST", "Expected hello handshake"),
                })?;
                return Ok(());
            }

            connection.send(ServerEnvelope::Response(ResponseEnvelope::err(
                "invalid",
                "INVALID_REQUEST",
                "Malformed request",
            )))?;
            return Ok(());
        };

        if !hello_done {
            match message {
                ClientEnvelope::Hello(hello) if hello.api_version == API_VERSION => {
                    connection.send(ServerEnvelope::HelloOk {
                        api_version: API_VERSION.to_owned(),
                        daemon_version: voxa_core::version().to_owned(),
                    })?;
                    hello_done = true;
                }
                ClientEnvelope::Hello(_) => {
                    connection.send(ServerEnvelope::HelloError {
                        error: ErrorPayload::new(
                            "API_VERSION_UNSUPPORTED",
                            "Unsupported API version",
                        ),
                    })?;
                    return Ok(());
                }
                _ => {
                    connection.send(ServerEnvelope::HelloError {
                        error: ErrorPayload::new("INVALID_REQUEST", "Expected hello handshake"),
                    })?;
                    return Ok(());
                }
            }

            continue;
        }

        if let ClientEnvelope::Request(request) = message {
            handle_request(request, connection, shared, event_tx)?;
        }
    }
}

fn handle_request(
    request: RequestEnvelope,
    connection: &ConnectionHandle,
    shared: &ServerState,
    event_tx: &mpsc::Sender<EventEnvelope>,
) -> io::Result<()> {
    match request.method.as_str() {
        "health" => {
            let result = HealthResult {
                status: "ok".to_owned(),
                uptime_ms: shared.lock()?.uptime_ms(),
            };
            write_response(connection, &request.id, Ok(result))
        }
        "get_state" => {
            let result = shared.lock()?.state_result();
            write_response(connection, &request.id, Ok(result))
        }
        "get_config" => {
            let result = shared.lock()?.config_result();
            write_response(connection, &request.id, Ok(result))
        }
        "start_recording" | "stop_recording" | "cancel_recording" => {
            let command = match request.method.as_str() {
                "start_recording" => request
                    .parse_params::<StartRecordingParams>()
                    .map(|params| {
                        CaptureCommand::Start(params.origin.unwrap_or(StartOrigin::Manual))
                    }),
                "stop_recording" => request.parse_params::<StopRecordingParams>().map(|params| {
                    CaptureCommand::Stop(
                        params.reason.unwrap_or(voxa_core::ipc::StopReason::Manual),
                    )
                }),
                _ => Ok(CaptureCommand::Cancel),
            };
            let command = match command {
                Ok(command) => command,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            let action = {
                let _capture = shared
                    .capture
                    .lock()
                    .map_err(|_| io::Error::other("capture lock poisoned"))?;
                let action = {
                    let mut state = shared.lock()?;
                    let action = state.begin_capture(command);
                    dispatch_outbox(&mut state, event_tx)?;
                    action
                };
                complete_capture_action(shared, event_tx, action)?
            };
            // Stop/cancel ordering is decided before releasing the capture lock.
            // Transcription runs independently of subsequent capture commands.
            let result = complete_session_action(shared, event_tx, action)?;
            write_response(connection, &request.id, result)
        }
        "get_api_key_status" => {
            let access = shared.lock()?.api_key_access();
            write_response(connection, &request.id, access.api_key_status())
        }
        "set_api_key" => {
            let params = match request.parse_params::<SetApiKeyParams>() {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            let access = shared.lock()?.api_key_access();
            write_response(connection, &request.id, access.set_api_key(params))
        }
        "set_config" => {
            let params = match request.parse_params::<SetConfigParams>() {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            let result = shared.lock()?.set_config(params);
            write_response(connection, &request.id, result)
        }
        "subscribe" => {
            let params = match request.parse_params::<SubscribeParams>() {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };
            shared
                .lock()?
                .subscribe(connection.clone(), &request.id, params.from_seq)
        }
        _ => write_response_error(
            connection,
            &request.id,
            ErrorPayload::new("UNKNOWN_METHOD", "Unknown method"),
        ),
    }
}

fn write_response<T: serde::Serialize>(
    connection: &ConnectionHandle,
    request_id: &str,
    result: Result<T, ErrorPayload>,
) -> io::Result<()> {
    let result = match result {
        Ok(value) => Ok(json_value(value)?),
        Err(error) => Err(error),
    };
    connection.send(ServerEnvelope::Response(ResponseEnvelope::from_result(
        request_id, result,
    )))
}

fn write_response_error(
    connection: &ConnectionHandle,
    request_id: &str,
    error: ErrorPayload,
) -> io::Result<()> {
    write_response::<Value>(connection, request_id, Err(error))
}

fn complete_capture_action(
    shared: &ServerState,
    event_tx: &mpsc::Sender<EventEnvelope>,
    action: Result<CaptureAction, ErrorPayload>,
) -> io::Result<Result<SessionAction, ErrorPayload>> {
    match action {
        Ok(CaptureAction::Accepted(value)) => Ok(Ok(SessionAction::Accepted(value))),
        Ok(CaptureAction::Pending(pending)) => {
            let completed = pending.run();
            let mut state = shared.lock()?;
            let result = state.finish_capture(completed);
            dispatch_outbox(&mut state, event_tx)?;
            Ok(result)
        }
        Err(error) => Ok(Err(error)),
    }
}

fn complete_session_action(
    shared: &ServerState,
    event_tx: &mpsc::Sender<EventEnvelope>,
    action: Result<SessionAction, ErrorPayload>,
) -> io::Result<Result<Value, ErrorPayload>> {
    match action {
        Ok(SessionAction::Accepted(value)) => Ok(Ok(value)),
        Ok(SessionAction::Transcribe(pending)) => {
            complete_pending_transcription(shared, event_tx, pending)
        }
        Err(error) => Ok(Err(error)),
    }
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

fn complete_pending_transcription(
    shared: &ServerState,
    event_tx: &mpsc::Sender<EventEnvelope>,
    pending: PendingTranscription,
) -> io::Result<Result<Value, ErrorPayload>> {
    let completed = pending.run();
    let mut state = shared.lock()?;
    let result = state.finish_transcription(completed);
    dispatch_outbox(&mut state, event_tx)?;
    Ok(result)
}

fn run_event_dispatcher(event_rx: mpsc::Receiver<EventEnvelope>, shared: Arc<ServerState>) {
    while let Ok(event) = event_rx.recv() {
        let mut state = match shared.lock() {
            Ok(state) => state,
            Err(_) => return,
        };

        state.publish_event(event);
    }
}

fn run_max_duration_watchdog(
    running: Arc<AtomicBool>,
    shared: Arc<ServerState>,
    event_tx: mpsc::Sender<EventEnvelope>,
) {
    while running.load(Ordering::SeqCst) {
        if watchdog_tick(&shared, &event_tx).is_err() {
            return;
        }
        thread::sleep(MAX_DURATION_POLL_INTERVAL);
    }
}

fn watchdog_tick(shared: &ServerState, event_tx: &mpsc::Sender<EventEnvelope>) -> io::Result<()> {
    let action = {
        let _capture = match shared.capture.try_lock() {
            Ok(guard) => guard,
            Err(TryLockError::WouldBlock) => return Ok(()),
            Err(TryLockError::Poisoned(_)) => {
                return Err(io::Error::other("capture lock poisoned"));
            }
        };
        let pending = {
            let mut state = shared.lock()?;
            state.poll_capture_error();
            let pending = state.begin_max_duration_stop_if_needed();
            state.emit_audio_level_if_needed();
            dispatch_outbox(&mut state, event_tx)?;
            pending
        };
        match pending {
            Ok(Some(pending)) => {
                complete_capture_action(shared, event_tx, Ok(CaptureAction::Pending(pending)))?
            }
            // Capture failures already emitted a state_changed event.
            Ok(None) | Err(_) => return Ok(()),
        }
    };
    let _ = complete_session_action(shared, event_tx, action)?;
    Ok(())
}

fn json_value<T: serde::Serialize>(value: T) -> io::Result<Value> {
    serde_json::to_value(value).map_err(|_| io::Error::other("failed to encode json"))
}
