#[derive(Debug, Clone, Copy)]
pub enum AppError {
    ApiKeyMissing,
    InvalidModel,
    InvalidLanguage,
    InvalidMaxSeconds,
    InvalidOutput,
    DaemonConfigPathUnavailable,
    DaemonConfigReadFailed,
    DaemonConfigWriteFailed,
    DaemonConfigInvalid,
    DaemonListenerUnavailable,
    ServiceInstallFailed,
    ServiceUninstallFailed,
    ServiceStatusFailed,
    InputModeUnsupported,
    AudioDeviceUnavailable,
    AudioPermissionDenied,
    AudioCaptureFailed,
    AudioEmptyBuffer,
    ApiAuthFailed,
    ApiRateLimited,
    ApiRequestFailed,
    ApiNetworkFailed,
    ApiResponseInvalid,
    ApiEmptyTranscript,
}

impl AppError {
    pub fn exit_code(self) -> i32 {
        match self {
            Self::ApiAuthFailed
            | Self::ApiRateLimited
            | Self::ApiRequestFailed
            | Self::ApiNetworkFailed
            | Self::ApiResponseInvalid
            | Self::ApiEmptyTranscript => 2,
            _ => 1,
        }
    }

    pub fn print(self) {
        match self {
            Self::ApiKeyMissing => {
                eprintln!("ERROR OPENAI_API_KEY_MISSING: OPENAI_API_KEY is required.");
                eprintln!("Set OPENAI_API_KEY in your environment or .env file.");
            }
            Self::InvalidModel => {
                eprintln!("ERROR MODEL_INVALID: model value is invalid.");
                eprintln!("Use gpt-4o-mini-transcribe or gpt-4o-transcribe.");
            }
            Self::InvalidLanguage => {
                eprintln!("ERROR LANGUAGE_INVALID: language must be auto, en, or fr.");
                eprintln!("Run voico --help for valid options.");
            }
            Self::InvalidMaxSeconds => {
                eprintln!("ERROR MAX_SECONDS_INVALID: max-seconds must be > 0.");
                eprintln!("Use --max-seconds <positive integer>.");
            }
            Self::InvalidOutput => {
                eprintln!("ERROR OUTPUT_INVALID: output must be clipboard or stdout.");
                eprintln!("Use --output <clipboard|stdout>.");
            }
            Self::DaemonConfigPathUnavailable => {
                eprintln!("ERROR DAEMON_CONFIG_PATH_UNAVAILABLE: could not resolve HOME path.");
                eprintln!("Set HOME and retry.");
            }
            Self::DaemonConfigReadFailed => {
                eprintln!("ERROR DAEMON_CONFIG_READ_FAILED: failed to read daemon configuration.");
                eprintln!("Run voico config show or recreate the config file.");
            }
            Self::DaemonConfigWriteFailed => {
                eprintln!(
                    "ERROR DAEMON_CONFIG_WRITE_FAILED: failed to write daemon configuration."
                );
                eprintln!("Check file permissions and retry.");
            }
            Self::DaemonConfigInvalid => {
                eprintln!("ERROR DAEMON_CONFIG_INVALID: daemon config values are invalid.");
                eprintln!("Run voico config set hotkey right_option to reset values.");
            }
            Self::DaemonListenerUnavailable => {
                eprintln!("ERROR DAEMON_LISTENER_UNAVAILABLE: global hotkey listener failed.");
                eprintln!(
                    "Allow Accessibility permissions for voico/terminal in System Settings > Privacy & Security > Accessibility."
                );
            }
            Self::ServiceInstallFailed => {
                eprintln!("ERROR SERVICE_INSTALL_FAILED: failed to install LaunchAgent.");
                eprintln!("Run voico service install again and check launchctl output.");
            }
            Self::ServiceUninstallFailed => {
                eprintln!("ERROR SERVICE_UNINSTALL_FAILED: failed to uninstall LaunchAgent.");
                eprintln!("Run voico service uninstall again.");
            }
            Self::ServiceStatusFailed => {
                eprintln!("ERROR SERVICE_STATUS_FAILED: failed to inspect LaunchAgent status.");
                eprintln!("Verify launchctl is available and retry.");
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
            Self::ApiAuthFailed => {
                eprintln!("ERROR API_AUTH_FAILED: authentication failed with STT provider.");
                eprintln!("Verify OPENAI_API_KEY and retry.");
            }
            Self::ApiRateLimited => {
                eprintln!("ERROR API_RATE_LIMITED: request was rate-limited.");
                eprintln!("Wait and retry.");
            }
            Self::ApiRequestFailed => {
                eprintln!("ERROR API_REQUEST_FAILED: transcription request failed.");
                eprintln!("Check model/language/options and retry.");
            }
            Self::ApiNetworkFailed => {
                eprintln!("ERROR API_NETWORK_FAILED: network error during transcription.");
                eprintln!("Check internet connection and retry.");
            }
            Self::ApiResponseInvalid => {
                eprintln!("ERROR API_RESPONSE_INVALID: provider response could not be parsed.");
                eprintln!("Retry; if persistent, switch model and re-test.");
            }
            Self::ApiEmptyTranscript => {
                eprintln!("ERROR API_EMPTY_TRANSCRIPT: transcript is empty.");
                eprintln!("Retry in a quieter environment or speak longer before stopping.");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::AppError;

    #[test]
    fn provider_errors_use_exit_code_two() {
        let provider_errors = [
            AppError::ApiAuthFailed,
            AppError::ApiRateLimited,
            AppError::ApiRequestFailed,
            AppError::ApiNetworkFailed,
            AppError::ApiResponseInvalid,
            AppError::ApiEmptyTranscript,
        ];

        for error in provider_errors {
            assert_eq!(error.exit_code(), 2);
        }
    }

    #[test]
    fn non_provider_errors_use_exit_code_one() {
        let non_provider_errors = [
            AppError::ApiKeyMissing,
            AppError::InvalidModel,
            AppError::InvalidLanguage,
            AppError::InvalidMaxSeconds,
            AppError::InvalidOutput,
            AppError::DaemonConfigPathUnavailable,
            AppError::DaemonConfigReadFailed,
            AppError::DaemonConfigWriteFailed,
            AppError::DaemonConfigInvalid,
            AppError::DaemonListenerUnavailable,
            AppError::ServiceInstallFailed,
            AppError::ServiceUninstallFailed,
            AppError::ServiceStatusFailed,
            AppError::InputModeUnsupported,
            AppError::AudioDeviceUnavailable,
            AppError::AudioPermissionDenied,
            AppError::AudioCaptureFailed,
            AppError::AudioEmptyBuffer,
        ];

        for error in non_provider_errors {
            assert_eq!(error.exit_code(), 1);
        }
    }
}
