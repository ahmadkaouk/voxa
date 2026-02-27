use std::env;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use reqwest::blocking::{Client, multipart};
use serde::Deserialize;
use voico_core::infra::{
    InfraError, NullOutputSink, OutputResult, OutputSink, Recorder, Transcriber,
};

use crate::secrets::{ApiKeyStore, build_api_key_store};

const TARGET_SAMPLE_RATE: u32 = 16_000;
const PBCOPY_PATH: &str = "/usr/bin/pbcopy";
const OUTPUT_MODE_CLIPBOARD_AUTOPASTE: &str = "clipboard_autopaste";
const OUTPUT_MODE_CLIPBOARD_ONLY: &str = "clipboard_only";
const OUTPUT_MODE_NONE: &str = "none";
const TRANSCRIPTIONS_URL: &str = "https://api.openai.com/v1/audio/transcriptions";
const REQUEST_TIMEOUT_SECS: u64 = 60;

pub(crate) fn build_runtime_for_output_mode(
    output_mode: &str,
    model: &str,
    api_key_source: &str,
) -> voico_core::app::SessionRuntime {
    let output = build_output_sink(output_mode);
    let transcriber = build_transcriber(model, api_key_source);

    voico_core::app::SessionRuntime::new(Box::new(MicRecorder::default()), transcriber, output)
}

#[derive(Default)]
struct MicRecorder {
    active: Option<ActiveRecording>,
}

struct ActiveRecording {
    stop_tx: mpsc::Sender<()>,
    result_rx: mpsc::Receiver<Result<Vec<u8>, InfraError>>,
    worker: thread::JoinHandle<()>,
}

impl Recorder for MicRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        if self.active.is_some() {
            return Ok(());
        }

        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (result_tx, result_rx) = mpsc::channel::<Result<Vec<u8>, InfraError>>();
        let worker = thread::spawn(move || {
            let result = record_until_stop(stop_rx);
            let _ = result_tx.send(result);
        });

        self.active = Some(ActiveRecording {
            stop_tx,
            result_rx,
            worker,
        });
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
        let active = self.active.take().ok_or(InfraError::AudioCaptureFailed)?;
        let _ = active.stop_tx.send(());
        let result = active
            .result_rx
            .recv()
            .unwrap_or(Err(InfraError::AudioCaptureFailed));
        let _ = active.worker.join();
        result
    }
}

fn record_until_stop(stop_rx: mpsc::Receiver<()>) -> Result<Vec<u8>, InfraError> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or(InfraError::AudioCaptureFailed)?;
    let supported_config = device
        .default_input_config()
        .map_err(|_| InfraError::AudioCaptureFailed)?;

    let sample_format = supported_config.sample_format();
    let config: cpal::StreamConfig = supported_config.into();
    let channels = config.channels;
    let sample_rate = config.sample_rate.0;

    let samples = Arc::new(Mutex::new(Vec::new()));
    let callback_error = Arc::new(Mutex::new(None::<InfraError>));
    let stream = build_stream(
        &device,
        &config,
        sample_format,
        Arc::clone(&samples),
        Arc::clone(&callback_error),
    )?;

    stream.play().map_err(|_| InfraError::AudioCaptureFailed)?;

    loop {
        if let Some(err) = take_callback_error(&callback_error)? {
            return Err(err);
        }

        match stop_rx.recv_timeout(Duration::from_millis(20)) {
            Ok(_) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    drop(stream);

    if let Some(err) = take_callback_error(&callback_error)? {
        return Err(err);
    }

    let captured = samples
        .lock()
        .map_err(|_| InfraError::AudioCaptureFailed)?
        .clone();
    normalize_to_wav(&captured, channels, sample_rate)
}

fn build_stream(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sample_format: cpal::SampleFormat,
    samples: Arc<Mutex<Vec<f32>>>,
    callback_error: Arc<Mutex<Option<InfraError>>>,
) -> Result<cpal::Stream, InfraError> {
    match sample_format {
        cpal::SampleFormat::F32 => {
            build_typed_stream(device, config, samples, callback_error, |sample: f32| {
                sample.clamp(-1.0, 1.0)
            })
        }
        cpal::SampleFormat::I16 => {
            build_typed_stream(device, config, samples, callback_error, |sample: i16| {
                (sample as f32 / i16::MAX as f32).clamp(-1.0, 1.0)
            })
        }
        cpal::SampleFormat::U16 => {
            build_typed_stream(device, config, samples, callback_error, |sample: u16| {
                ((sample as f32 / u16::MAX as f32) * 2.0 - 1.0).clamp(-1.0, 1.0)
            })
        }
        _ => Err(InfraError::AudioCaptureFailed),
    }
}

fn build_typed_stream<T, F>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    samples: Arc<Mutex<Vec<f32>>>,
    callback_error: Arc<Mutex<Option<InfraError>>>,
    normalize: F,
) -> Result<cpal::Stream, InfraError>
where
    T: cpal::SizedSample + Copy,
    F: Fn(T) -> f32 + Send + 'static,
{
    let samples_for_data = Arc::clone(&samples);
    let callback_error_for_data = Arc::clone(&callback_error);
    let callback_error_for_err = Arc::clone(&callback_error);

    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                push_samples(
                    data,
                    &samples_for_data,
                    &callback_error_for_data,
                    &normalize,
                )
            },
            move |_err| {
                store_callback_error(&callback_error_for_err, InfraError::AudioCaptureFailed)
            },
            None,
        )
        .map_err(|_| InfraError::AudioCaptureFailed)
}

fn push_samples<T, F>(
    data: &[T],
    samples: &Arc<Mutex<Vec<f32>>>,
    callback_error: &Arc<Mutex<Option<InfraError>>>,
    normalize: &F,
) where
    T: Copy,
    F: Fn(T) -> f32,
{
    let Ok(mut output) = samples.lock() else {
        store_callback_error(callback_error, InfraError::AudioCaptureFailed);
        return;
    };

    output.extend(data.iter().copied().map(normalize));
}

fn normalize_to_wav(
    samples: &[f32],
    channels: u16,
    source_sample_rate: u32,
) -> Result<Vec<u8>, InfraError> {
    if samples.is_empty() {
        return Err(InfraError::AudioCaptureFailed);
    }
    if channels == 0 || source_sample_rate == 0 {
        return Err(InfraError::AudioCaptureFailed);
    }

    let mono_samples = mix_to_mono(samples, channels);
    if mono_samples.is_empty() {
        return Err(InfraError::AudioCaptureFailed);
    }

    let resampled = resample_linear(&mono_samples, source_sample_rate, TARGET_SAMPLE_RATE);
    let pcm_samples = to_pcm16(&resampled);
    write_wav(&pcm_samples)
}

fn mix_to_mono(samples: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }

    let channels = channels as usize;
    let mut mono = Vec::with_capacity(samples.len() / channels);
    for frame in samples.chunks(channels) {
        let sum = frame.iter().copied().sum::<f32>();
        mono.push(sum / frame.len() as f32);
    }
    mono
}

fn resample_linear(samples: &[f32], source_rate: u32, target_rate: u32) -> Vec<f32> {
    if source_rate == target_rate || samples.len() <= 1 {
        return samples.to_vec();
    }

    let ratio = target_rate as f64 / source_rate as f64;
    let output_len = ((samples.len() as f64) * ratio).round().max(1.0) as usize;
    let mut output = Vec::with_capacity(output_len);

    for i in 0..output_len {
        let source_pos = (i as f64) / ratio;
        let base = source_pos.floor() as usize;
        let frac = (source_pos - base as f64) as f32;

        let a = samples[base.min(samples.len() - 1)];
        let b = samples[(base + 1).min(samples.len() - 1)];
        output.push(a + (b - a) * frac);
    }

    output
}

fn to_pcm16(samples: &[f32]) -> Vec<i16> {
    samples
        .iter()
        .map(|sample| (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16)
        .collect()
}

fn write_wav(samples: &[i16]) -> Result<Vec<u8>, InfraError> {
    let data_size = samples
        .len()
        .checked_mul(2)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or(InfraError::AudioCaptureFailed)?;
    let riff_size = 36u32
        .checked_add(data_size)
        .ok_or(InfraError::AudioCaptureFailed)?;
    let byte_rate = TARGET_SAMPLE_RATE
        .checked_mul(2)
        .ok_or(InfraError::AudioCaptureFailed)?;

    let mut wav = Vec::with_capacity(44 + data_size as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&TARGET_SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());

    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }

    Ok(wav)
}

fn take_callback_error(
    callback_error: &Arc<Mutex<Option<InfraError>>>,
) -> Result<Option<InfraError>, InfraError> {
    callback_error
        .lock()
        .map_err(|_| InfraError::AudioCaptureFailed)
        .map(|mut value| value.take())
}

fn store_callback_error(callback_error: &Arc<Mutex<Option<InfraError>>>, error: InfraError) {
    if let Ok(mut value) = callback_error.lock() {
        if value.is_none() {
            *value = Some(error);
        }
    }
}

fn build_output_sink(output_mode: &str) -> Box<dyn OutputSink> {
    match output_mode {
        OUTPUT_MODE_NONE => Box::new(NullOutputSink),
        OUTPUT_MODE_CLIPBOARD_ONLY | OUTPUT_MODE_CLIPBOARD_AUTOPASTE => {
            if Path::new(PBCOPY_PATH).exists() {
                Box::new(ClipboardOutputSink)
            } else {
                Box::new(NullOutputSink)
            }
        }
        _ => Box::new(NullOutputSink),
    }
}

struct ClipboardOutputSink;

impl OutputSink for ClipboardOutputSink {
    fn output(&mut self, text: &str) -> Result<OutputResult, InfraError> {
        let mut child = Command::new(PBCOPY_PATH)
            .stdin(Stdio::piped())
            .spawn()
            .map_err(|_| InfraError::OutputFailed)?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(text.as_bytes())
                .map_err(|_| InfraError::OutputFailed)?;
        }

        let status = child.wait().map_err(|_| InfraError::OutputFailed)?;
        if !status.success() {
            return Err(InfraError::OutputFailed);
        }

        Ok(OutputResult {
            clipboard: !text.is_empty(),
            autopaste: false,
        })
    }
}

fn build_transcriber(model: &str, api_key_source: &str) -> Box<dyn Transcriber> {
    let api_keys = build_api_key_store(api_key_source);
    match OpenAiTranscriber::new(model, api_keys, transcriptions_url()) {
        Ok(transcriber) => Box::new(transcriber),
        Err(_) => Box::new(FailingTranscriber),
    }
}

fn transcriptions_url() -> String {
    match env::var("VOICO_OPENAI_TRANSCRIPTIONS_URL") {
        Ok(url) if !url.trim().is_empty() => url.trim().to_owned(),
        _ => TRANSCRIPTIONS_URL.to_owned(),
    }
}

struct FailingTranscriber;

impl Transcriber for FailingTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Err(InfraError::TranscriptionFailed)
    }
}

#[derive(Debug, Deserialize)]
struct TranscriptionResponse {
    text: String,
}

struct OpenAiTranscriber {
    client: Client,
    model: String,
    api_keys: Box<dyn ApiKeyStore>,
    url: String,
}

impl OpenAiTranscriber {
    fn new(
        model: &str,
        api_keys: Box<dyn ApiKeyStore>,
        url: String,
    ) -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS))
                .build()?,
            model: model.to_owned(),
            api_keys,
            url,
        })
    }
}

impl Transcriber for OpenAiTranscriber {
    fn transcribe(&mut self, audio: Vec<u8>) -> Result<String, InfraError> {
        if audio.is_empty() {
            return Err(InfraError::TranscriptionFailed);
        }

        let api_key = self
            .api_keys
            .get_api_key()
            .map_err(|_| InfraError::TranscriptionFailed)?
            .ok_or(InfraError::TranscriptionFailed)?;

        let form = multipart::Form::new()
            .text("model", self.model.clone())
            .part(
                "file",
                multipart::Part::bytes(audio)
                    .file_name("audio.wav")
                    .mime_str("audio/wav")
                    .map_err(|_| InfraError::TranscriptionFailed)?,
            );

        let response = self
            .client
            .post(&self.url)
            .bearer_auth(api_key)
            .multipart(form)
            .send()
            .map_err(|_| InfraError::TranscriptionFailed)?;

        if !response.status().is_success() {
            return Err(InfraError::TranscriptionFailed);
        }

        let parsed = response
            .json::<TranscriptionResponse>()
            .map_err(|_| InfraError::TranscriptionFailed)?;
        let transcript = parsed.text.trim();
        if transcript.is_empty() {
            return Err(InfraError::TranscriptionFailed);
        }

        Ok(transcript.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use std::io;

    use super::*;

    const WAV_HEADER_SIZE: usize = 44;

    struct FixedApiKeyStore {
        value: Option<String>,
    }

    impl ApiKeyStore for FixedApiKeyStore {
        fn get_api_key(&self) -> io::Result<Option<String>> {
            Ok(self.value.clone())
        }

        fn set_api_key(&self, _api_key: &str) -> io::Result<()> {
            Err(io::Error::other("read-only"))
        }
    }

    fn wav_bytes() -> Vec<u8> {
        vec![
            82, 73, 70, 70, 38, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0, 1, 0, 1,
            0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0, 100, 97, 116, 97, 2, 0, 0, 0, 0, 0,
        ]
    }

    fn test_transcriber(url: String, api_key: Option<&str>) -> OpenAiTranscriber {
        OpenAiTranscriber {
            client: Client::builder()
                .timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS))
                .build()
                .expect("client should build"),
            model: "gpt-4o-mini-transcribe".to_owned(),
            api_keys: Box::new(FixedApiKeyStore {
                value: api_key.map(|value| value.to_owned()),
            }),
            url,
        }
    }

    fn read_u16_le(bytes: &[u8], offset: usize) -> u16 {
        u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
    }

    fn read_u32_le(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ])
    }

    fn read_pcm16_samples(wav: &[u8]) -> Vec<i16> {
        wav[WAV_HEADER_SIZE..]
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
            .collect()
    }

    #[test]
    fn normalize_to_wav_rejects_empty_audio() {
        let result = normalize_to_wav(&[], 1, 16_000);
        assert_eq!(result, Err(InfraError::AudioCaptureFailed));
    }

    #[test]
    fn normalize_to_wav_sets_expected_header_fields() {
        let input = vec![0.0_f32; 480];
        let wav = normalize_to_wav(&input, 1, 48_000).expect("normalize failed");

        assert!(wav.len() >= WAV_HEADER_SIZE);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(read_u16_le(&wav, 22), 1);
        assert_eq!(read_u32_le(&wav, 24), TARGET_SAMPLE_RATE);
        assert_eq!(read_u16_le(&wav, 34), 16);
    }

    #[test]
    fn normalize_to_wav_mixes_stereo_to_mono() {
        let input = vec![1.0_f32, -1.0, 0.5, 0.5];
        let wav = normalize_to_wav(&input, 2, 16_000).expect("normalize failed");
        let samples = read_pcm16_samples(&wav);

        assert!(samples.len() >= 2);
        assert_eq!(samples[0], 0);
        assert!(samples[1] > 16_000);
    }

    #[test]
    fn openai_transcriber_returns_text_on_success() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .match_header("authorization", "Bearer test-key")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"text":"hello world"}"#)
            .create();

        let mut transcriber =
            test_transcriber(server.url() + "/v1/audio/transcriptions", Some("test-key"));
        let result = transcriber
            .transcribe(wav_bytes())
            .expect("transcription should succeed");
        mock.assert();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn openai_transcriber_fails_when_api_key_is_missing() {
        let mut transcriber = test_transcriber(
            "http://127.0.0.1:9/v1/audio/transcriptions".to_owned(),
            None,
        );
        let result = transcriber.transcribe(wav_bytes());
        assert_eq!(result, Err(InfraError::TranscriptionFailed));
    }

    #[test]
    fn openai_transcriber_maps_non_success_status_to_error() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(401)
            .create();

        let mut transcriber =
            test_transcriber(server.url() + "/v1/audio/transcriptions", Some("test-key"));
        let result = transcriber.transcribe(wav_bytes());
        assert_eq!(result, Err(InfraError::TranscriptionFailed));
    }
}
