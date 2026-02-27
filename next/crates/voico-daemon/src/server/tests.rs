use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::json;
use voico_core::app::SessionRuntime;
use voico_core::infra::{InfraError, OutputResult, OutputSink, Recorder, Transcriber};
use voico_core::ipc::ServerEnvelope;

use super::{run, run_with_runtime};

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

fn start_server_with_runtime(
    path: PathBuf,
    runtime: SessionRuntime,
) -> (Arc<AtomicBool>, thread::JoinHandle<std::io::Result<()>>) {
    let running = Arc::new(AtomicBool::new(true));
    let running_for_thread = Arc::clone(&running);
    let handle = thread::spawn(move || run_with_runtime(path, running_for_thread, runtime));
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
fn redundant_start_and_stop_are_idempotent() {
    let path = temp_socket_path("idem");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);

    let _ = send_request(
        &mut stream,
        &mut reader,
        "1",
        "start_recording",
        json!({"origin":"manual"}),
    );
    let _ = send_request(
        &mut stream,
        &mut reader,
        "2",
        "start_recording",
        json!({"origin":"manual"}),
    );
    let state_after_redundant_start =
        send_request(&mut stream, &mut reader, "3", "get_state", json!({}));
    assert_eq!(state_after_redundant_start["state"], "recording");

    let _ = send_request(
        &mut stream,
        &mut reader,
        "4",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    let _ = send_request(
        &mut stream,
        &mut reader,
        "5",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    let state_after_redundant_stop =
        send_request(&mut stream, &mut reader, "6", "get_state", json!({}));
    assert_eq!(state_after_redundant_stop["state"], "idle");

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
fn set_config_rejects_unsupported_model_and_output_mode() {
    let path = temp_socket_path("cfg-values");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);

    let initial = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
    let initial_revision = initial["revision"].as_u64().unwrap_or(0);

    let model_error = send_request_expect_error(
        &mut stream,
        &mut reader,
        "2",
        "set_config",
        json!({
            "model": "unknown-model"
        }),
    );
    assert_eq!(model_error, "CONFIG_INVALID");

    let output_mode_error = send_request_expect_error(
        &mut stream,
        &mut reader,
        "3",
        "set_config",
        json!({
            "output_mode": "invalid_mode"
        }),
    );
    assert_eq!(output_mode_error, "CONFIG_INVALID");

    let after = send_request(&mut stream, &mut reader, "4", "get_config", json!({}));
    assert_eq!(after["model"], initial["model"]);
    assert_eq!(after["output_mode"], initial["output_mode"]);
    assert_eq!(after["revision"].as_u64().unwrap_or(0), initial_revision);

    stop_server(&path, running, handle);
}

#[test]
fn malformed_request_returns_error_and_closes_connection() {
    let path = temp_socket_path("bad");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    stream
        .write_all(b"{not valid json\n")
        .expect("write should succeed");
    stream.flush().expect("flush should succeed");

    let envelope = read_server_envelope(&mut reader);
    match envelope {
        ServerEnvelope::Response(response) => {
            assert!(!response.ok, "malformed request should return error");
            let error = response.error.expect("error payload should be present");
            assert_eq!(error.code, "INVALID_REQUEST");
        }
        other => panic!("expected response envelope, got {:?}", other),
    }

    let mut line = String::new();
    let bytes = reader
        .read_line(&mut line)
        .expect("read_line should succeed after error response");
    assert_eq!(bytes, 0, "connection should close after malformed request");

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
            if saw_recording_state && event.name == "state_changed" && event.data["state"] == "idle"
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

struct TestRecorder;

impl Recorder for TestRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
        Ok(vec![1, 2, 3])
    }
}

struct FailingTranscriber;

impl Transcriber for FailingTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Err(InfraError::TranscriptionFailed)
    }
}

struct TestOutput;

impl OutputSink for TestOutput {
    fn output(&mut self, _text: &str) -> Result<OutputResult, InfraError> {
        Ok(OutputResult {
            clipboard: true,
            autopaste: false,
        })
    }
}

fn runtime_with_transcription_failure() -> SessionRuntime {
    SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(FailingTranscriber),
        Box::new(TestOutput),
    )
}

#[test]
fn daemon_stays_alive_after_transcription_failure() {
    let path = temp_socket_path("tx-fail");
    let runtime = runtime_with_transcription_failure();
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "1",
        "start_recording",
        json!({"origin":"manual"}),
    );

    let stop_error = send_request_expect_error(
        &mut stream,
        &mut reader,
        "2",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop_error, "API_REQUEST_FAILED");

    let state = send_request(&mut stream, &mut reader, "3", "get_state", json!({}));
    assert_eq!(state["state"], "error");

    let health = send_request(&mut stream, &mut reader, "4", "health", json!({}));
    assert_eq!(health["status"], "ok");

    stop_server(&path, running, handle);
}
