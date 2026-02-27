#[derive(Debug, Clone, Eq, PartialEq)]
pub enum InfraError {
    AudioCaptureFailed,
    ApiAuthFailed,
    ApiRateLimited,
    ApiRequestFailed,
    ApiNetworkFailed,
    ApiResponseInvalid,
    ApiEmptyTranscript,
    OutputFailed,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum HotkeyEvent {
    TogglePressed,
    HoldPressed,
    HoldReleased,
}

#[derive(Debug, Clone, Eq, PartialEq, Default)]
pub struct OutputResult {
    pub clipboard: bool,
    pub autopaste: bool,
}

pub trait Recorder: Send {
    fn start(&mut self) -> Result<(), InfraError>;
    fn stop(&mut self) -> Result<Vec<u8>, InfraError>;
}

pub trait Transcriber: Send {
    fn transcribe(&mut self, audio: Vec<u8>) -> Result<String, InfraError>;
}

pub trait OutputSink: Send {
    fn output(&mut self, text: &str) -> Result<OutputResult, InfraError>;
}

pub trait HotkeySource: Send {
    fn next_event(&mut self) -> Result<HotkeyEvent, InfraError>;
}

#[derive(Debug, Default)]
pub struct NullRecorder {
    is_recording: bool,
}

impl Recorder for NullRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        self.is_recording = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
        self.is_recording = false;
        Ok(Vec::new())
    }
}

#[derive(Debug, Default)]
pub struct NullTranscriber;

impl Transcriber for NullTranscriber {
    fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
        Ok(String::new())
    }
}

#[derive(Debug, Default)]
pub struct NullOutputSink;

impl OutputSink for NullOutputSink {
    fn output(&mut self, _text: &str) -> Result<OutputResult, InfraError> {
        Ok(OutputResult::default())
    }
}
