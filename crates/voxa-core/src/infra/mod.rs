#[derive(Debug, Clone, Eq, PartialEq)]
pub enum InfraError {
    AudioCaptureFailed,
    ApiAuthFailed,
    ApiRateLimited,
    ApiRequestFailed,
    ApiNetworkFailed,
    ApiResponseInvalid,
    ApiEmptyTranscript,
}

pub trait Recorder: Send {
    fn start(&mut self) -> Result<(), InfraError>;
    fn stop(&mut self) -> Result<Vec<u8>, InfraError>;
    fn cancel(&mut self) -> Result<(), InfraError> {
        self.stop().map(drop)
    }
    fn current_level(&self) -> Option<f32> {
        None
    }
    /// Poll for a capture worker failure without waiting for the worker.
    fn poll_error(&mut self) -> Option<InfraError> {
        None
    }
}

pub trait Transcriber: Send {
    fn transcribe(&mut self, audio: Vec<u8>) -> Result<String, InfraError>;
}

#[derive(Debug, Default)]
pub struct NullRecorder;

impl Recorder for NullRecorder {
    fn start(&mut self) -> Result<(), InfraError> {
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
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
