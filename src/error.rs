#[derive(Debug, Clone, Copy)]
pub enum AppError {
    ApiKeyMissing,
    InvalidModel,
    InvalidLanguage,
    InvalidMaxSeconds,
    InvalidOutput,
    InputModeUnsupported,
    AudioDeviceUnavailable,
    AudioPermissionDenied,
    AudioCaptureFailed,
    AudioEmptyBuffer,
}

impl AppError {
    pub fn print(self) {
        match self {
            Self::ApiKeyMissing => {
                eprintln!("ERROR CONFIG_API_KEY_MISSING: OPENAI_API_KEY is required.");
                eprintln!("Set OPENAI_API_KEY in your environment or .env file.");
            }
            Self::InvalidModel => {
                eprintln!("ERROR CONFIG_INVALID_MODEL: model value is invalid.");
                eprintln!("Use gpt-4o-mini-transcribe or gpt-4o-transcribe.");
            }
            Self::InvalidLanguage => {
                eprintln!("ERROR CONFIG_INVALID_LANGUAGE: language must be auto, en, or fr.");
                eprintln!("Run voico --help for valid options.");
            }
            Self::InvalidMaxSeconds => {
                eprintln!("ERROR CONFIG_INVALID_MAX_SECONDS: max-seconds must be > 0.");
                eprintln!("Use --max-seconds <positive integer>.");
            }
            Self::InvalidOutput => {
                eprintln!("ERROR CONFIG_INVALID_OUTPUT: output must be clipboard or stdout.");
                eprintln!("Use --output <clipboard|stdout>.");
            }
            Self::InputModeUnsupported => {
                eprintln!(
                    "ERROR INPUT_MODE_UNSUPPORTED: hold mode is not supported in this terminal."
                );
                eprintln!("Use voico toggle instead.");
            }
            Self::AudioDeviceUnavailable => {
                eprintln!("ERROR AUDIO_DEVICE_UNAVAILABLE: microphone input is unavailable.");
                eprintln!("Check input device and retry.");
            }
            Self::AudioPermissionDenied => {
                eprintln!("ERROR AUDIO_PERMISSION_DENIED: microphone permission denied.");
                eprintln!(
                    "Allow microphone access for your terminal app in System Settings > Privacy & Security > Microphone."
                );
            }
            Self::AudioCaptureFailed => {
                eprintln!("ERROR AUDIO_CAPTURE_FAILED: failed while capturing audio.");
                eprintln!("Check microphone device status and retry.");
            }
            Self::AudioEmptyBuffer => {
                eprintln!("ERROR AUDIO_EMPTY_BUFFER: no audio captured.");
                eprintln!("Speak after recording starts and retry.");
            }
        }
    }
}
