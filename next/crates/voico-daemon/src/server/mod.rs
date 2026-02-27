mod connection;
mod state;

#[cfg(test)]
mod tests;

use std::fs;
use std::io::{self, BufRead, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

use serde_json::Value;
use voico_core::ipc::{
    API_VERSION, ClientEnvelope, ErrorPayload, EventEnvelope, HealthResult, RequestEnvelope,
    ResponseEnvelope, ServerEnvelope, SetApiKeyParams, StartOrigin, StartRecordingParams,
    StopRecordingParams, SubscribeParams,
};

use self::connection::ConnectionHandle;
use self::state::{SetConfigParams, SharedState};

const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);

pub fn run(socket_path: PathBuf, running: Arc<AtomicBool>) -> io::Result<()> {
    let state = SharedState::from_disk()?;
    run_with_state(socket_path, running, state)
}

#[cfg(test)]
fn run_with_runtime(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    runtime: voico_core::app::SessionRuntime,
) -> io::Result<()> {
    let state = SharedState::with_runtime(runtime);
    run_with_state(socket_path, running, state)
}

#[cfg(test)]
fn run_with_runtime_and_shared_api_keys(
    socket_path: PathBuf,
    running: Arc<AtomicBool>,
    runtime: voico_core::app::SessionRuntime,
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
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    ensure_socket_available(&socket_path)?;

    let listener = UnixListener::bind(&socket_path)?;
    listener.set_nonblocking(true)?;

    let shared = Arc::new(Mutex::new(state));
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

fn ensure_socket_available(socket_path: &Path) -> io::Result<()> {
    if !socket_path.exists() {
        return Ok(());
    }

    match UnixStream::connect(socket_path) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "voico-daemon is already running",
        )),
        Err(err) if err.kind() == io::ErrorKind::ConnectionRefused => fs::remove_file(socket_path),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => fs::remove_file(socket_path),
    }
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
                    uptime_ms: state.uptime_ms(),
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
            let reason = params.reason.unwrap_or(voico_core::ipc::StopReason::Manual);

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
        "get_api_key_status" => {
            let result = {
                let state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                state.api_key_status()
            };

            match result {
                Ok(value) => {
                    let payload = json_value(value)?;
                    connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                        &request.id,
                        payload,
                    )))
                }
                Err(error) => write_response_error(connection, &request.id, error),
            }
        }
        "set_api_key" => {
            let params = request.parse_params::<SetApiKeyParams>();
            let params = match params {
                Ok(params) => params,
                Err(error) => return write_response_error(connection, &request.id, error),
            };

            let result = {
                let state = shared
                    .lock()
                    .map_err(|_| io::Error::other("state poisoned"))?;
                state.set_api_key(params)
            };

            match result {
                Ok(value) => connection.send(ServerEnvelope::Response(ResponseEnvelope::ok(
                    &request.id,
                    value,
                ))),
                Err(error) => write_response_error(connection, &request.id, error),
            }
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

        state.notify_subscribers(&envelope);
    }
}

fn json_value<T: serde::Serialize>(value: T) -> io::Result<Value> {
    serde_json::to_value(value).map_err(|_| io::Error::other("failed to encode json"))
}
