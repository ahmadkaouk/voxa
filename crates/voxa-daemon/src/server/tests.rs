use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::json;
use voxa_core::app::SessionRuntime;
use voxa_core::infra::{InfraError, OutputResult, OutputSink, Recorder, Transcriber};
use voxa_core::ipc::ServerEnvelope;

use super::{
    run_with_runtime, run_with_runtime_and_max_recording_seconds,
    run_with_runtime_and_shared_api_keys,
};

fn temp_socket_path(name: &str) -> PathBuf {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("current time should be after epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("voxa-{name}-{pid}-{nanos}.sock"))
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
    let handle = thread::spawn(move || {
        run_with_runtime(path, running_for_thread, SessionRuntime::default())
    });
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

fn start_server_with_runtime_and_max_recording_seconds(
    path: PathBuf,
    runtime: SessionRuntime,
    max_recording_seconds: u64,
) -> (Arc<AtomicBool>, thread::JoinHandle<std::io::Result<()>>) {
    let running = Arc::new(AtomicBool::new(true));
    let running_for_thread = Arc::clone(&running);
    let handle = thread::spawn(move || {
        run_with_runtime_and_max_recording_seconds(
            path,
            running_for_thread,
            runtime,
            max_recording_seconds,
        )
    });
    (running, handle)
}

fn start_server_with_runtime_and_shared_api_keys(
    path: PathBuf,
    runtime: SessionRuntime,
    shared_api_keys: Arc<std::sync::Mutex<Option<String>>>,
) -> (Arc<AtomicBool>, thread::JoinHandle<std::io::Result<()>>) {
    let running = Arc::new(AtomicBool::new(true));
    let running_for_thread = Arc::clone(&running);
    let handle = thread::spawn(move || {
        run_with_runtime_and_shared_api_keys(path, running_for_thread, runtime, shared_api_keys)
    });
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
fn stop_recording_returns_transcript_text() {
    let path = temp_socket_path("stop-text");
    let runtime = runtime_with_fixed_transcript("hello from test");
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

    let stop = send_request(
        &mut stream,
        &mut reader,
        "2",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop["accepted"], true);
    assert_eq!(stop["text"], "hello from test");

    stop_server(&path, running, handle);
}

#[test]
fn cancel_recording_discards_audio_and_allows_another_recording() {
    let path = temp_socket_path("cancel");
    let probe = Arc::new(CancellationProbe::default());
    let (running, handle) =
        start_server_with_runtime(path.clone(), cancellation_probe_runtime(&probe, false));
    wait_for_socket(&path);

    let (mut subscriber, mut events) = connect_and_handshake(&path);
    let _ = send_request(&mut subscriber, &mut events, "sub", "subscribe", json!({}));
    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "start",
        "start_recording",
        json!({"origin":"hotkey_hold"}),
    );
    let recording = send_request(&mut stream, &mut reader, "before", "get_state", json!({}));
    assert!(probe.recording.load(Ordering::SeqCst));

    let cancelled = send_request(
        &mut stream,
        &mut reader,
        "cancel",
        "cancel_recording",
        json!({}),
    );
    assert_eq!(cancelled, json!({"accepted":true, "cancelled":true}));
    assert!(!probe.recording.load(Ordering::SeqCst));
    assert_eq!(probe.stops.load(Ordering::SeqCst), 1);
    assert_eq!(probe.transcriptions.load(Ordering::SeqCst), 0);
    assert_eq!(probe.outputs.load(Ordering::SeqCst), 0);

    let mut saw_cancelled = false;
    loop {
        let ServerEnvelope::Event(event) = read_server_envelope(&mut events) else {
            panic!("subscriber should receive an event");
        };
        assert!(!matches!(
            event.name.as_str(),
            "recording_stopped"
                | "transcribing_started"
                | "transcription_ready"
                | "output_completed"
        ));
        if event.name == "recording_cancelled" {
            assert_eq!(event.data["session_id"], recording["session"]);
            saw_cancelled = true;
        }
        if event.name == "state_changed" {
            assert!(!matches!(
                event.data["state"].as_str(),
                Some("transcribing" | "outputting")
            ));
            if event.data["state"] == "idle" {
                assert!(saw_cancelled);
                break;
            }
        }
    }

    let idle = send_request(&mut stream, &mut reader, "idle", "get_state", json!({}));
    assert_eq!(idle["state"], "idle");
    assert!(idle["session"].is_null());
    assert!(idle["recording_origin"].is_null());
    assert!(idle["last_error"].is_null());
    let repeated = send_request(
        &mut stream,
        &mut reader,
        "repeat",
        "cancel_recording",
        json!({}),
    );
    assert_eq!(repeated, json!({"accepted":true, "cancelled":false}));
    let release = send_request(
        &mut stream,
        &mut reader,
        "release",
        "stop_recording",
        json!({"reason":"hotkey_hold_release"}),
    );
    assert_eq!(release, json!({"accepted":true}));
    let after_noops = send_request(&mut stream, &mut reader, "noops", "get_state", json!({}));
    assert_eq!(after_noops["event_seq"], idle["event_seq"]);
    assert_eq!(probe.stops.load(Ordering::SeqCst), 1);

    let _ = send_request(
        &mut stream,
        &mut reader,
        "restart",
        "start_recording",
        json!({"origin":"manual"}),
    );
    assert!(probe.recording.load(Ordering::SeqCst));
    let stopped = send_request(
        &mut stream,
        &mut reader,
        "stop",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stopped["text"], "new recording");
    assert_eq!(probe.stops.load(Ordering::SeqCst), 2);
    assert_eq!(probe.transcriptions.load(Ordering::SeqCst), 1);
    stop_server(&path, running, handle);
}

#[test]
fn cancel_recording_does_not_interrupt_inflight_transcription() {
    let path = temp_socket_path("cancel-busy");
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let runtime = SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(BlockingTranscriber {
            started_tx,
            release_rx,
        }),
        Box::new(TestOutput),
    );
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);
    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "start",
        "start_recording",
        json!({}),
    );

    let stop_path = path.clone();
    let stop_handle = thread::spawn(move || {
        let (mut stream, mut reader) = connect_and_handshake(&stop_path);
        send_request(
            &mut stream,
            &mut reader,
            "stop",
            "stop_recording",
            json!({}),
        )
    });
    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("transcription should start");
    let before = send_request(&mut stream, &mut reader, "before", "get_state", json!({}));
    assert_eq!(before["state"], "transcribing");
    let cancelled = send_request(
        &mut stream,
        &mut reader,
        "cancel",
        "cancel_recording",
        json!({}),
    );
    assert_eq!(cancelled, json!({"accepted":true, "cancelled":false}));
    let after = send_request(&mut stream, &mut reader, "after", "get_state", json!({}));
    assert_eq!(after["state"], "transcribing");
    assert_eq!(after["session"], before["session"]);
    assert_eq!(after["event_seq"], before["event_seq"]);

    release_tx
        .send(())
        .expect("transcription should be released");
    let stopped = stop_handle.join().expect("stop request should finish");
    assert_eq!(stopped["text"], "slow transcript");
    let idle = send_request(&mut stream, &mut reader, "idle", "get_state", json!({}));
    assert_eq!(idle["state"], "idle");
    stop_server(&path, running, handle);
}

#[test]
fn cancel_recording_reports_capture_failure_without_transcription() {
    let path = temp_socket_path("cancel-failure");
    let probe = Arc::new(CancellationProbe::default());
    let (running, handle) =
        start_server_with_runtime(path.clone(), cancellation_probe_runtime(&probe, true));
    wait_for_socket(&path);
    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "start",
        "start_recording",
        json!({}),
    );
    let error = send_request_expect_error(
        &mut stream,
        &mut reader,
        "cancel",
        "cancel_recording",
        json!({}),
    );
    assert_eq!(error, "AUDIO_CAPTURE_FAILED");
    let state = send_request(&mut stream, &mut reader, "state", "get_state", json!({}));
    assert_eq!(state["state"], "error");
    assert!(state["session"].is_null());
    assert_eq!(probe.transcriptions.load(Ordering::SeqCst), 0);
    assert_eq!(probe.outputs.load(Ordering::SeqCst), 0);
    stop_server(&path, running, handle);
}

#[test]
fn daemon_remains_responsive_and_dispatches_events_while_transcribing() {
    let path = temp_socket_path("responsive");
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let runtime = SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(BlockingTranscriber {
            started_tx,
            release_rx,
        }),
        Box::new(TestOutput),
    );
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
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

    let stop_path = path.clone();
    let stop_handle = thread::spawn(move || {
        let (mut stream, mut reader) = connect_and_handshake(&stop_path);
        send_request(
            &mut stream,
            &mut reader,
            "3",
            "stop_recording",
            json!({"reason":"manual"}),
        )
    });

    started_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("transcription should start");

    let (mut observer_stream, mut observer_reader) = connect_and_handshake(&path);
    let health = send_request(
        &mut observer_stream,
        &mut observer_reader,
        "4",
        "health",
        json!({}),
    );
    assert_eq!(health["status"], "ok");
    let state = send_request(
        &mut observer_stream,
        &mut observer_reader,
        "5",
        "get_state",
        json!({}),
    );
    assert_eq!(state["state"], "transcribing");
    let config_error = send_request_expect_error(
        &mut observer_stream,
        &mut observer_reader,
        "6",
        "set_config",
        json!({"max_recording_seconds":120}),
    );
    assert_eq!(config_error, "CONFIG_BUSY");

    let mut saw_transcribing_event = false;
    for _ in 0..12 {
        if let ServerEnvelope::Event(event) = read_server_envelope(&mut subscriber_reader) {
            if event.name == "transcribing_started"
                || (event.name == "state_changed" && event.data["state"] == "transcribing")
            {
                saw_transcribing_event = true;
                break;
            }
        }
    }
    assert!(
        saw_transcribing_event,
        "transcribing events should be dispatched before transcription finishes"
    );

    release_tx
        .send(())
        .expect("blocked transcription should be released");
    let stop = stop_handle.join().expect("stop request thread should join");
    assert_eq!(stop["text"], "slow transcript");

    stop_server(&path, running, handle);
}

#[test]
fn hold_release_does_not_stop_toggle_recording() {
    let path = temp_socket_path("stray-hold");
    let runtime = runtime_with_fixed_transcript("still recording");
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "1",
        "start_recording",
        json!({"origin":"hotkey_toggle"}),
    );
    let stray_stop = send_request(
        &mut stream,
        &mut reader,
        "2",
        "stop_recording",
        json!({"reason":"hotkey_hold_release"}),
    );
    assert_eq!(stray_stop["accepted"], true);
    assert!(stray_stop.get("text").is_none());

    let state = send_request(&mut stream, &mut reader, "3", "get_state", json!({}));
    assert_eq!(state["state"], "recording");

    let stop = send_request(
        &mut stream,
        &mut reader,
        "4",
        "stop_recording",
        json!({"reason":"hotkey_toggle"}),
    );
    assert_eq!(stop["text"], "still recording");

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
fn non_runtime_config_change_preserves_injected_runtime() {
    let path = temp_socket_path("cfg-runtime");
    let runtime = runtime_with_fixed_transcript("runtime preserved");
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream,
        &mut reader,
        "1",
        "set_config",
        json!({"max_recording_seconds":120}),
    );
    let _ = send_request(
        &mut stream,
        &mut reader,
        "2",
        "start_recording",
        json!({"origin":"manual"}),
    );
    let stop = send_request(
        &mut stream,
        &mut reader,
        "3",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop["text"], "runtime preserved");

    stop_server(&path, running, handle);
}

#[test]
fn set_config_is_rejected_while_recording_without_disrupting_session() {
    let path = temp_socket_path("config-busy");
    let runtime = runtime_with_fixed_transcript("session survived");
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    let before = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
    let _ = send_request(
        &mut stream,
        &mut reader,
        "2",
        "start_recording",
        json!({"origin":"manual"}),
    );
    let error = send_request_expect_error(
        &mut stream,
        &mut reader,
        "3",
        "set_config",
        json!({"max_recording_seconds":120}),
    );
    assert_eq!(error, "CONFIG_BUSY");

    let after = send_request(&mut stream, &mut reader, "4", "get_config", json!({}));
    assert_eq!(after, before);
    let stop = send_request(
        &mut stream,
        &mut reader,
        "5",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop["text"], "session survived");

    stop_server(&path, running, handle);
}

#[test]
fn set_config_failure_does_not_mutate_existing_config() {
    let path = temp_socket_path("cfg");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);

    let initial = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
    assert_eq!(initial["toggle_hotkey"], "option_f");
    assert_eq!(initial["hold_hotkey"], "option_g");
    let initial_revision = initial["revision"].as_u64().unwrap_or(0);

    let error_code = send_request_expect_error(
        &mut stream,
        &mut reader,
        "2",
        "set_config",
        json!({
            "hold_hotkey": "option_f"
        }),
    );
    assert_eq!(error_code, "CONFIG_HOTKEY_CONFLICT");

    let after = send_request(&mut stream, &mut reader, "3", "get_config", json!({}));
    assert_eq!(after["toggle_hotkey"], "option_f");
    assert_eq!(after["hold_hotkey"], "option_g");
    assert_eq!(after["revision"].as_u64().unwrap_or(0), initial_revision);

    stop_server(&path, running, handle);
}

#[test]
fn set_config_rejects_unsupported_model_and_output_mode() {
    let path = temp_socket_path("cfg-values");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);

    send_request(
        &mut stream,
        &mut reader,
        "set-model",
        "set_config",
        json!({ "model": "gpt-transcribe" }),
    );
    let initial = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
    assert_eq!(initial["model"], "gpt-transcribe");
    let initial_revision = initial["revision"].as_u64().unwrap_or(0);

    for model in [
        "unknown-model",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
    ] {
        let model_error = send_request_expect_error(
            &mut stream,
            &mut reader,
            "2",
            "set_config",
            json!({ "model": model }),
        );
        assert_eq!(model_error, "CONFIG_INVALID");
    }

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
fn set_config_rejects_out_of_range_max_recording_seconds_with_stable_error() {
    let path = temp_socket_path("cfg-max");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);
    let initial = send_request(&mut stream, &mut reader, "1", "get_config", json!({}));
    let initial_revision = initial["revision"].as_u64().unwrap_or(0);

    for (id, value) in [("2", 0), ("3", 3_601)] {
        let error_code = send_request_expect_error(
            &mut stream,
            &mut reader,
            id,
            "set_config",
            json!({
                "max_recording_seconds": value
            }),
        );
        assert_eq!(error_code, "CONFIG_INVALID");
    }

    let after = send_request(&mut stream, &mut reader, "4", "get_config", json!({}));
    assert_eq!(
        after["max_recording_seconds"],
        initial["max_recording_seconds"]
    );
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

#[test]
fn subscriber_replays_ordered_gap_after_response() {
    let path = temp_socket_path("subscribe-replay");
    let runtime = runtime_with_fixed_transcript("replayed transcript");
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut subscriber_stream, mut subscriber_reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut subscriber_stream,
        &mut subscriber_reader,
        "1",
        "subscribe",
        json!({}),
    );

    // This observer gives the test a deterministic signal that the dispatcher
    // has published every event into the replay buffer before reconnecting.
    let (mut observer_stream, mut observer_reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut observer_stream,
        &mut observer_reader,
        "2",
        "subscribe",
        json!({}),
    );

    let (mut control_stream, mut control_reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut control_stream,
        &mut control_reader,
        "3",
        "start_recording",
        json!({"origin":"manual"}),
    );

    let last_seen_seq = loop {
        match read_server_envelope(&mut subscriber_reader) {
            ServerEnvelope::Event(event) if event.name == "recording_started" => break event.seq,
            ServerEnvelope::Event(_) => {}
            other => panic!("expected live event before disconnect, got {:?}", other),
        }
    };
    assert!(last_seen_seq > 0);
    drop(subscriber_reader);
    drop(subscriber_stream);

    let stop = send_request(
        &mut control_stream,
        &mut control_reader,
        "4",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop["text"], "replayed transcript");

    let state = send_request(
        &mut control_stream,
        &mut control_reader,
        "5",
        "get_state",
        json!({}),
    );
    let current_seq = state["event_seq"]
        .as_u64()
        .expect("state should include numeric event_seq");

    let mut observer_seq = 0;
    while observer_seq < current_seq {
        match read_server_envelope(&mut observer_reader) {
            ServerEnvelope::Event(event) => {
                assert_eq!(event.seq, observer_seq + 1);
                observer_seq = event.seq;
            }
            other => panic!("expected observer event, got {:?}", other),
        }
    }

    let (mut replay_stream, mut replay_reader) = connect_and_handshake(&path);
    send_json(
        &mut replay_stream,
        json!({
            "type": "request",
            "id": "6",
            "method": "subscribe",
            "params": {"from_seq": last_seen_seq}
        }),
    );

    let first = read_server_envelope(&mut replay_reader);
    match first {
        ServerEnvelope::Response(response) => {
            assert_eq!(response.id, "6");
            assert!(response.ok);
            assert_eq!(
                response.result.expect("subscribe result")["current_seq"],
                current_seq
            );
        }
        other => panic!("subscribe response must precede replay, got {:?}", other),
    }

    let mut saw_transcription_ready = false;
    for expected_seq in (last_seen_seq + 1)..=current_seq {
        match read_server_envelope(&mut replay_reader) {
            ServerEnvelope::Event(event) => {
                assert_eq!(
                    event.seq, expected_seq,
                    "replayed events must be contiguous"
                );
                if event.name == "transcription_ready" {
                    assert_eq!(event.data["text"], "replayed transcript");
                    saw_transcription_ready = true;
                }
            }
            other => panic!("expected replayed event, got {:?}", other),
        }
    }
    assert!(
        saw_transcription_ready,
        "the disconnect gap should replay transcription_ready"
    );

    stop_server(&path, running, handle);
}

#[test]
fn subscribe_without_positive_from_seq_does_not_replay_history() {
    let path = temp_socket_path("subscribe-from-now");
    let runtime = runtime_with_fixed_transcript("first transcript");
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
    wait_for_socket(&path);

    let (mut observer_stream, mut observer_reader) = connect_and_handshake(&path);
    let _ = send_request(
        &mut observer_stream,
        &mut observer_reader,
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
    let state = send_request(
        &mut control_stream,
        &mut control_reader,
        "4",
        "get_state",
        json!({}),
    );
    let history_seq = state["event_seq"]
        .as_u64()
        .expect("state should include numeric event_seq");

    let mut observer_seq = 0;
    while observer_seq < history_seq {
        match read_server_envelope(&mut observer_reader) {
            ServerEnvelope::Event(event) => observer_seq = event.seq,
            other => panic!("expected observer event, got {:?}", other),
        }
    }

    let (mut omitted_stream, mut omitted_reader) = connect_and_handshake(&path);
    let omitted = send_request(
        &mut omitted_stream,
        &mut omitted_reader,
        "5",
        "subscribe",
        json!({}),
    );
    assert_eq!(omitted["current_seq"], history_seq);

    let (mut zero_stream, mut zero_reader) = connect_and_handshake(&path);
    let zero = send_request(
        &mut zero_stream,
        &mut zero_reader,
        "6",
        "subscribe",
        json!({"from_seq": 0}),
    );
    assert_eq!(zero["current_seq"], history_seq);

    let (mut stale_stream, mut stale_reader) = connect_and_handshake(&path);
    let stale = send_request(
        &mut stale_stream,
        &mut stale_reader,
        "stale",
        "subscribe",
        json!({"from_seq": history_seq + 100}),
    );
    assert_eq!(stale["current_seq"], history_seq);
    for expected_seq in 1..=history_seq {
        match read_server_envelope(&mut stale_reader) {
            ServerEnvelope::Event(event) => assert_eq!(event.seq, expected_seq),
            other => panic!("expected new-epoch replay, got {:?}", other),
        }
    }

    let _ = send_request(
        &mut control_stream,
        &mut control_reader,
        "7",
        "start_recording",
        json!({"origin":"manual"}),
    );
    for reader in [&mut omitted_reader, &mut zero_reader] {
        match read_server_envelope(reader) {
            ServerEnvelope::Event(event) => {
                assert_eq!(
                    event.seq,
                    history_seq + 1,
                    "omitted and zero from_seq must start with the next live event"
                );
            }
            other => panic!("expected next live event, got {:?}", other),
        }
    }

    let _ = send_request(
        &mut control_stream,
        &mut control_reader,
        "8",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    stop_server(&path, running, handle);
}

#[test]
fn max_duration_enforcement_auto_stops_recording() {
    let path = temp_socket_path("max-duration");
    let (running, handle) = start_server_with_runtime_and_max_recording_seconds(
        path.clone(),
        SessionRuntime::default(),
        1,
    );
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

    let mut saw_recording_state = false;
    let mut saw_max_duration_stop = false;
    let mut saw_idle_state = false;

    for _ in 0..16 {
        let envelope = read_server_envelope(&mut subscriber_reader);
        if let ServerEnvelope::Event(event) = envelope {
            if event.name == "state_changed" && event.data["state"] == "recording" {
                saw_recording_state = true;
            }
            if event.name == "recording_stopped" && event.data["reason"] == "max_duration" {
                saw_max_duration_stop = true;
            }
            if saw_max_duration_stop
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
        saw_max_duration_stop,
        "subscriber should see stop reason max_duration"
    );
    assert!(
        saw_idle_state,
        "subscriber should eventually see idle state after max duration stop"
    );

    stop_server(&path, running, handle);
}

#[derive(Default)]
struct CancellationProbe {
    recording: AtomicBool,
    stops: AtomicUsize,
    transcriptions: AtomicUsize,
    outputs: AtomicUsize,
}

struct CancellationProbeRecorder {
    probe: Arc<CancellationProbe>,
    fail_stop: bool,
}

impl Recorder for CancellationProbeRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        if self.probe.recording.swap(true, Ordering::SeqCst) {
            return Err(InfraError::AudioCaptureFailed);
        }
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
        self.probe.stops.fetch_add(1, Ordering::SeqCst);
        if !self.probe.recording.swap(false, Ordering::SeqCst) || self.fail_stop {
            return Err(InfraError::AudioCaptureFailed);
        }
        Ok(vec![1, 2, 3])
    }
}

struct CancellationProbeTranscriber(Arc<CancellationProbe>);

impl Transcriber for CancellationProbeTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        self.0.transcriptions.fetch_add(1, Ordering::SeqCst);
        Ok("new recording".to_owned())
    }
}

struct CancellationProbeOutput(Arc<CancellationProbe>);

impl OutputSink for CancellationProbeOutput {
    fn output(&mut self, _text: &str) -> Result<OutputResult, InfraError> {
        self.0.outputs.fetch_add(1, Ordering::SeqCst);
        Ok(OutputResult {
            clipboard: true,
            autopaste: false,
        })
    }
}

fn cancellation_probe_runtime(probe: &Arc<CancellationProbe>, fail_stop: bool) -> SessionRuntime {
    SessionRuntime::new(
        Box::new(CancellationProbeRecorder {
            probe: Arc::clone(probe),
            fail_stop,
        }),
        Box::new(CancellationProbeTranscriber(Arc::clone(probe))),
        Box::new(CancellationProbeOutput(Arc::clone(probe))),
    )
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

#[derive(Default)]
struct LevelRecorder {
    is_recording: bool,
}

impl Recorder for LevelRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        self.is_recording = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
        self.is_recording = false;
        Ok(vec![1, 2, 3])
    }

    fn current_level(&self) -> Option<f32> {
        Some(if self.is_recording { 0.75 } else { 0.0 })
    }
}

struct FailingTranscriber;

impl Transcriber for FailingTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Err(InfraError::ApiRequestFailed)
    }
}

struct BlockingTranscriber {
    started_tx: mpsc::Sender<()>,
    release_rx: mpsc::Receiver<()>,
}

impl Transcriber for BlockingTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        self.started_tx
            .send(())
            .map_err(|_| InfraError::ApiRequestFailed)?;
        self.release_rx
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| InfraError::ApiRequestFailed)?;
        Ok("slow transcript".to_owned())
    }
}

struct EmptyTranscriber;

impl Transcriber for EmptyTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Err(InfraError::ApiEmptyTranscript)
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

struct FixedTranscriber {
    text: String,
}

impl Transcriber for FixedTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Ok(self.text.clone())
    }
}

fn runtime_with_fixed_transcript(text: &str) -> SessionRuntime {
    SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(FixedTranscriber {
            text: text.to_owned(),
        }),
        Box::new(TestOutput),
    )
}

fn runtime_with_transcription_failure() -> SessionRuntime {
    SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(FailingTranscriber),
        Box::new(TestOutput),
    )
}

fn runtime_with_empty_transcript() -> SessionRuntime {
    SessionRuntime::new(
        Box::new(TestRecorder),
        Box::new(EmptyTranscriber),
        Box::new(TestOutput),
    )
}

fn runtime_with_fixed_audio_level() -> SessionRuntime {
    SessionRuntime::new(
        Box::new(LevelRecorder::default()),
        Box::new(FixedTranscriber {
            text: "hello".to_owned(),
        }),
        Box::new(TestOutput),
    )
}

#[test]
fn subscriber_receives_audio_level_events_while_recording() {
    let path = temp_socket_path("audio-level");
    let runtime = runtime_with_fixed_audio_level();
    let (running, handle) = start_server_with_runtime(path.clone(), runtime);
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

    let mut saw_audio_level = false;

    for _ in 0..20 {
        let envelope = read_server_envelope(&mut subscriber_reader);
        if let ServerEnvelope::Event(event) = envelope {
            if event.name == "audio_level" {
                let level = event.data["level"]
                    .as_f64()
                    .expect("audio level should be numeric");
                assert!(level > 0.7, "audio level should reflect recorder activity");
                saw_audio_level = true;
                break;
            }
        }
    }

    assert!(
        saw_audio_level,
        "subscriber should receive audio level events"
    );

    stop_server(&path, running, handle);
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

#[test]
fn empty_transcript_is_not_treated_as_error() {
    let path = temp_socket_path("empty-transcript");
    let runtime = runtime_with_empty_transcript();
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

    let stop = send_request(
        &mut stream,
        &mut reader,
        "2",
        "stop_recording",
        json!({"reason":"manual"}),
    );
    assert_eq!(stop["accepted"], true);
    assert_eq!(stop["text"], "");

    let state = send_request(&mut stream, &mut reader, "3", "get_state", json!({}));
    assert_eq!(state["state"], "idle");
    assert_eq!(state["last_error"], serde_json::Value::Null);

    stop_server(&path, running, handle);
}

#[test]
fn start_recording_recovers_from_error_state() {
    let path = temp_socket_path("recover");
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

    let restart = send_request(
        &mut stream,
        &mut reader,
        "4",
        "start_recording",
        json!({"origin":"manual"}),
    );
    assert_eq!(restart["accepted"], true);

    let recovered = send_request(&mut stream, &mut reader, "5", "get_state", json!({}));
    assert_eq!(recovered["state"], "recording");
    assert_eq!(recovered["last_error"], json!(null));

    stop_server(&path, running, handle);
}

#[test]
fn second_daemon_start_on_same_socket_is_rejected() {
    let path = temp_socket_path("single");
    let (running_first, handle_first) = start_server(path.clone());
    wait_for_socket(&path);

    let running_second = Arc::new(AtomicBool::new(true));
    let running_second_thread = Arc::clone(&running_second);
    let path_second = path.clone();
    let handle_second = thread::spawn(move || {
        run_with_runtime(
            path_second,
            running_second_thread,
            SessionRuntime::default(),
        )
    });

    let second_result = handle_second
        .join()
        .expect("second server thread should join");
    assert!(
        second_result.is_err(),
        "second daemon start should fail on occupied socket"
    );
    let error = second_result.expect_err("second start should produce io error");
    assert_eq!(error.kind(), std::io::ErrorKind::AddrInUse);

    stop_server(&path, running_first, handle_first);
}

#[test]
fn api_key_status_reflects_set_api_key() {
    let path = temp_socket_path("api-key");
    let (running, handle) = start_server(path.clone());
    wait_for_socket(&path);

    let (mut stream, mut reader) = connect_and_handshake(&path);

    let initial = send_request(
        &mut stream,
        &mut reader,
        "1",
        "get_api_key_status",
        json!({}),
    );
    assert_eq!(initial["is_set"], false);
    assert!(initial["hint"].is_null());

    let _ = send_request(
        &mut stream,
        &mut reader,
        "2",
        "set_api_key",
        json!({
            "api_key": "sk-test-value"
        }),
    );

    let after = send_request(
        &mut stream,
        &mut reader,
        "3",
        "get_api_key_status",
        json!({}),
    );
    assert_eq!(after["is_set"], true);
    assert_eq!(after["hint"], "sk-test-va...");

    stop_server(&path, running, handle);
}

#[test]
fn api_key_store_survives_daemon_restart_with_shared_store() {
    let shared_api_keys = Arc::new(std::sync::Mutex::new(None));
    let path = temp_socket_path("api-restart");

    let (running_first, handle_first) = start_server_with_runtime_and_shared_api_keys(
        path.clone(),
        SessionRuntime::default(),
        Arc::clone(&shared_api_keys),
    );
    wait_for_socket(&path);

    let (mut stream_first, mut reader_first) = connect_and_handshake(&path);
    let _ = send_request(
        &mut stream_first,
        &mut reader_first,
        "1",
        "set_api_key",
        json!({
            "api_key": "sk-persisted"
        }),
    );
    stop_server(&path, running_first, handle_first);

    let (running_second, handle_second) = start_server_with_runtime_and_shared_api_keys(
        path.clone(),
        SessionRuntime::default(),
        Arc::clone(&shared_api_keys),
    );
    wait_for_socket(&path);

    let (mut stream_second, mut reader_second) = connect_and_handshake(&path);
    let status = send_request(
        &mut stream_second,
        &mut reader_second,
        "2",
        "get_api_key_status",
        json!({}),
    );
    assert_eq!(status["is_set"], true);
    assert_eq!(status["hint"], "sk-persist...");

    stop_server(&path, running_second, handle_second);
}
