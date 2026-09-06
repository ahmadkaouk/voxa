//! Opt-in measurements using generated audio and a local HTTP server only.
use super::*;
use serde_json::json;
use std::time::Instant;

#[test]
#[ignore = "measurement only; run scripts/measure-baseline.sh explicitly"]
fn migration_fixture_baseline() {
    let output = std::env::var_os("VOXA_BASELINE_DIR")
        .expect("VOXA_BASELINE_DIR must name the measurement output directory");
    let output = std::path::PathBuf::from(output);
    std::fs::create_dir_all(&output).unwrap();
    const COUNT: usize = 30;
    const WARMUP: usize = 3;
    const RATE: u32 = 48_000;
    const SECONDS: usize = 10;
    let samples: Vec<f32> = (0..RATE as usize * SECONDS)
        .flat_map(|frame| {
            let value = (std::f32::consts::TAU * 440.0 * frame as f32 / RATE as f32).sin() * 0.1;
            [value, value]
        })
        .collect();
    let mut normalization_ms = Vec::new();
    let mut wav = Vec::new();
    for iteration in 0..COUNT + WARMUP {
        let start = Instant::now();
        wav = normalize_to_wav(&samples, 2, RATE).unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(wav.len(), 44 + 16_000 * SECONDS * 2);
        if iteration >= WARMUP {
            normalization_ms.push(elapsed);
        }
    }
    std::fs::write(output.join("fixture.wav"), &wav).unwrap();

    let mut server = mockito::Server::new();
    let response = server
        .mock("POST", "/v1/audio/transcriptions")
        .match_header("authorization", "Bearer fixture-only")
        .with_header("content-type", "application/json")
        .with_chunked_body(|writer| {
            thread::sleep(Duration::from_millis(50));
            writer.write_all(br#"{"text":"fixture transcript"}"#)
        })
        .expect(COUNT + WARMUP)
        .create();
    let keys = crate::secrets::in_memory_api_key_store();
    keys.set_api_key("fixture-only").unwrap();
    let mut transcriber = OpenAiTranscriber::new(
        "gpt-transcribe",
        keys,
        format!("{}/v1/audio/transcriptions", server.url()),
    )
    .unwrap();
    let mut loopback_transcription_ms = Vec::new();
    for iteration in 0..COUNT + WARMUP {
        // Match production ownership: audio is already available before timing upload.
        let audio = wav.clone();
        let start = Instant::now();
        let text = transcriber.transcribe(audio).unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        assert_eq!(text, "fixture transcript");
        if iteration >= WARMUP {
            loopback_transcription_ms.push(elapsed);
        }
    }
    response.assert();
    let report = json!({
        "schema_version": 1,
        "kind": "source_fixture",
        "build": if cfg!(debug_assertions) { "debug" } else { "release" },
        "clock": "std::time::Instant",
        "warmup_samples_excluded": WARMUP,
        "sample_count": COUNT,
        "fixture": { "seconds": SECONDS, "input_rate": RATE, "input_channels": 2,
            "frequency_hz": 440, "amplitude": 0.1, "wav_bytes": wav.len(),
            "description": "synthetic tone; not a microphone or speech-quality measurement" },
        "response_delay_ms": 50,
        "metrics_ms": { "normalization": normalization_ms,
            "loopback_upload_and_response": loopback_transcription_ms },
        "limitations": ["No microphone or user audio", "In-memory dummy credential",
            "Local HTTP only; includes response delay and host scheduling, not provider latency",
            "No Swift UI or IPC path in these measurements"]
    });
    std::fs::write(
        output.join("fixture-metrics.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
}
