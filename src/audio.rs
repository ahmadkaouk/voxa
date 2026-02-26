use std::io;
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::error::AppError;

const TARGET_SAMPLE_RATE: u32 = 16_000;

#[derive(Debug, Clone)]
pub struct CapturedAudio {
    pub wav_bytes: Vec<u8>,
    pub max_duration_reached: bool,
}

pub fn record_toggle(max_seconds: u32) -> Result<CapturedAudio, AppError> {
    let stop_rx = spawn_stop_listener();
    record_until_stop(max_seconds, stop_rx)
}

pub fn record_until_stop(
    max_seconds: u32,
    stop_rx: mpsc::Receiver<()>,
) -> Result<CapturedAudio, AppError> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or(AppError::AudioDeviceUnavailable)?;
    let supported_config = device
        .default_input_config()
        .map_err(map_default_config_error)?;

    let sample_format = supported_config.sample_format();
    let config: cpal::StreamConfig = supported_config.into();
    let channels = config.channels;
    let sample_rate = config.sample_rate.0;

    let samples = Arc::new(Mutex::new(Vec::new()));
    let callback_error = Arc::new(Mutex::new(None::<AppError>));

    let stream = build_stream(
        &device,
        &config,
        sample_format,
        Arc::clone(&samples),
        Arc::clone(&callback_error),
    )?;
    stream.play().map_err(map_play_stream_error)?;

    let deadline = Instant::now() + Duration::from_secs(max_seconds as u64);
    let mut max_duration_reached = false;

    loop {
        if let Some(err) = take_callback_error(&callback_error)? {
            return Err(err);
        }

        if stop_rx.try_recv().is_ok() {
            break;
        }

        if Instant::now() >= deadline {
            max_duration_reached = true;
            break;
        }

        thread::sleep(Duration::from_millis(20));
    }

    drop(stream);

    if let Some(err) = take_callback_error(&callback_error)? {
        return Err(err);
    }

    let captured = samples
        .lock()
        .map_err(|_| AppError::AudioCaptureFailed)?
        .clone();
    let wav_bytes = normalize_to_wav(&captured, channels, sample_rate)?;

    Ok(CapturedAudio {
        wav_bytes,
        max_duration_reached,
    })
}

fn spawn_stop_listener() -> mpsc::Receiver<()> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let mut line = String::new();
        if let Ok(read) = io::stdin().read_line(&mut line) {
            if read > 0 {
                let _ = tx.send(());
            }
        }
    });

    rx
}

fn build_stream(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sample_format: cpal::SampleFormat,
    samples: Arc<Mutex<Vec<f32>>>,
    callback_error: Arc<Mutex<Option<AppError>>>,
) -> Result<cpal::Stream, AppError> {
    match sample_format {
        cpal::SampleFormat::F32 => {
            let samples_for_data = Arc::clone(&samples);
            let callback_error_for_data = Arc::clone(&callback_error);
            let callback_error_for_err = Arc::clone(&callback_error);
            device
                .build_input_stream(
                    config,
                    move |data: &[f32], _| {
                        push_f32_samples(data, &samples_for_data, &callback_error_for_data)
                    },
                    move |err| {
                        store_callback_error(
                            &callback_error_for_err,
                            map_stream_error_message(&err.to_string()),
                        )
                    },
                    None,
                )
                .map_err(map_build_stream_error)
        }
        cpal::SampleFormat::I16 => {
            let samples_for_data = Arc::clone(&samples);
            let callback_error_for_data = Arc::clone(&callback_error);
            let callback_error_for_err = Arc::clone(&callback_error);
            device
                .build_input_stream(
                    config,
                    move |data: &[i16], _| {
                        push_i16_samples(data, &samples_for_data, &callback_error_for_data)
                    },
                    move |err| {
                        store_callback_error(
                            &callback_error_for_err,
                            map_stream_error_message(&err.to_string()),
                        )
                    },
                    None,
                )
                .map_err(map_build_stream_error)
        }
        cpal::SampleFormat::U16 => {
            let samples_for_data = Arc::clone(&samples);
            let callback_error_for_data = Arc::clone(&callback_error);
            let callback_error_for_err = Arc::clone(&callback_error);
            device
                .build_input_stream(
                    config,
                    move |data: &[u16], _| {
                        push_u16_samples(data, &samples_for_data, &callback_error_for_data)
                    },
                    move |err| {
                        store_callback_error(
                            &callback_error_for_err,
                            map_stream_error_message(&err.to_string()),
                        )
                    },
                    None,
                )
                .map_err(map_build_stream_error)
        }
        _ => Err(AppError::AudioCaptureFailed),
    }
}

fn push_f32_samples(
    data: &[f32],
    samples: &Arc<Mutex<Vec<f32>>>,
    callback_error: &Arc<Mutex<Option<AppError>>>,
) {
    let Ok(mut output) = samples.lock() else {
        store_callback_error(callback_error, AppError::AudioCaptureFailed);
        return;
    };

    output.extend(data.iter().map(|sample| sample.clamp(-1.0, 1.0)));
}

fn push_i16_samples(
    data: &[i16],
    samples: &Arc<Mutex<Vec<f32>>>,
    callback_error: &Arc<Mutex<Option<AppError>>>,
) {
    let Ok(mut output) = samples.lock() else {
        store_callback_error(callback_error, AppError::AudioCaptureFailed);
        return;
    };

    output.extend(
        data.iter()
            .map(|sample| *sample as f32 / i16::MAX as f32)
            .map(|sample| sample.clamp(-1.0, 1.0)),
    );
}

fn push_u16_samples(
    data: &[u16],
    samples: &Arc<Mutex<Vec<f32>>>,
    callback_error: &Arc<Mutex<Option<AppError>>>,
) {
    let Ok(mut output) = samples.lock() else {
        store_callback_error(callback_error, AppError::AudioCaptureFailed);
        return;
    };

    output.extend(data.iter().map(|sample| {
        let normalized = (*sample as f32 / u16::MAX as f32) * 2.0 - 1.0;
        normalized.clamp(-1.0, 1.0)
    }));
}

fn normalize_to_wav(
    samples: &[f32],
    channels: u16,
    source_sample_rate: u32,
) -> Result<Vec<u8>, AppError> {
    if samples.is_empty() {
        return Err(AppError::AudioEmptyBuffer);
    }

    if channels == 0 || source_sample_rate == 0 {
        return Err(AppError::AudioCaptureFailed);
    }

    let mono_samples = mix_to_mono(samples, channels);
    if mono_samples.is_empty() {
        return Err(AppError::AudioEmptyBuffer);
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

fn write_wav(samples: &[i16]) -> Result<Vec<u8>, AppError> {
    let data_size = samples
        .len()
        .checked_mul(2)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or(AppError::AudioCaptureFailed)?;
    let riff_size = 36u32
        .checked_add(data_size)
        .ok_or(AppError::AudioCaptureFailed)?;
    let byte_rate = TARGET_SAMPLE_RATE
        .checked_mul(2)
        .ok_or(AppError::AudioCaptureFailed)?;

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
    callback_error: &Arc<Mutex<Option<AppError>>>,
) -> Result<Option<AppError>, AppError> {
    callback_error
        .lock()
        .map_err(|_| AppError::AudioCaptureFailed)
        .map(|mut value| value.take())
}

fn store_callback_error(callback_error: &Arc<Mutex<Option<AppError>>>, error: AppError) {
    if let Ok(mut value) = callback_error.lock() {
        if value.is_none() {
            *value = Some(error);
        }
    }
}

fn map_default_config_error(error: cpal::DefaultStreamConfigError) -> AppError {
    if is_permission_error(&error.to_string()) {
        AppError::AudioPermissionDenied
    } else {
        AppError::AudioDeviceUnavailable
    }
}

fn map_build_stream_error(error: cpal::BuildStreamError) -> AppError {
    if is_permission_error(&error.to_string()) {
        AppError::AudioPermissionDenied
    } else {
        AppError::AudioDeviceUnavailable
    }
}

fn map_play_stream_error(error: cpal::PlayStreamError) -> AppError {
    if is_permission_error(&error.to_string()) {
        AppError::AudioPermissionDenied
    } else {
        AppError::AudioCaptureFailed
    }
}

fn map_stream_error_message(message: &str) -> AppError {
    if is_permission_error(message) {
        AppError::AudioPermissionDenied
    } else {
        AppError::AudioCaptureFailed
    }
}

fn is_permission_error(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("permission")
        || message.contains("not permitted")
        || message.contains("denied")
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::{TARGET_SAMPLE_RATE, normalize_to_wav};

    #[test]
    fn normalize_to_wav_rejects_empty_audio() {
        let result = normalize_to_wav(&[], 1, 16_000);

        assert!(result.is_err());
    }

    #[test]
    fn normalize_to_wav_sets_expected_format() {
        let input = vec![0.0_f32; 480];
        let wav_bytes = normalize_to_wav(&input, 1, 48_000).expect("normalize failed");

        let reader = hound::WavReader::new(Cursor::new(wav_bytes)).expect("wav parse failed");
        let spec = reader.spec();

        assert_eq!(spec.channels, 1);
        assert_eq!(spec.sample_rate, TARGET_SAMPLE_RATE);
        assert_eq!(spec.bits_per_sample, 16);
    }

    #[test]
    fn normalize_to_wav_mixes_stereo_to_mono() {
        let input = vec![1.0_f32, -1.0, 0.5, 0.5];
        let wav_bytes = normalize_to_wav(&input, 2, 16_000).expect("normalize failed");

        let mut reader = hound::WavReader::new(Cursor::new(wav_bytes)).expect("wav parse failed");
        let samples = reader
            .samples::<i16>()
            .collect::<Result<Vec<_>, _>>()
            .expect("sample parse failed");

        assert!(samples.len() >= 2);
        assert_eq!(samples[0], 0);
        assert!(samples[1] > 16_000);
    }
}
