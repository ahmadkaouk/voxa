use crate::domain::RuntimeErrorCode;
use crate::infra::{InfraError, NullRecorder, NullTranscriber, Recorder, Transcriber};

pub struct SessionRuntime {
    recorder: Box<dyn Recorder>,
    transcriber: Box<dyn Transcriber>,
}

impl SessionRuntime {
    pub fn new(recorder: Box<dyn Recorder>, transcriber: Box<dyn Transcriber>) -> Self {
        Self {
            recorder,
            transcriber,
        }
    }

    pub fn start_recording(&mut self) -> Result<(), RuntimeErrorCode> {
        self.recorder.start().map_err(RuntimeErrorCode::from)
    }

    pub fn stop_recording(&mut self) -> Result<Vec<u8>, RuntimeErrorCode> {
        self.recorder.stop().map_err(RuntimeErrorCode::from)
    }

    pub fn cancel_recording(&mut self) -> Result<(), RuntimeErrorCode> {
        self.recorder.cancel().map_err(RuntimeErrorCode::from)
    }

    pub fn current_recording_level(&self) -> Option<f32> {
        self.recorder.current_level()
    }

    pub fn transcribe(&mut self, audio: Vec<u8>) -> Result<String, RuntimeErrorCode> {
        self.transcriber
            .transcribe(audio)
            .map_err(RuntimeErrorCode::from)
    }

    pub fn poll_recording_error(&mut self) -> Option<RuntimeErrorCode> {
        self.recorder.poll_error().map(RuntimeErrorCode::from)
    }
}

impl Default for SessionRuntime {
    fn default() -> Self {
        Self::new(Box::new(NullRecorder), Box::new(NullTranscriber))
    }
}

impl From<InfraError> for RuntimeErrorCode {
    fn from(error: InfraError) -> Self {
        match error {
            InfraError::AudioCaptureFailed => RuntimeErrorCode::AudioCaptureFailed,
            InfraError::ApiAuthFailed => RuntimeErrorCode::ApiAuthFailed,
            InfraError::ApiRateLimited => RuntimeErrorCode::ApiRateLimited,
            InfraError::ApiRequestFailed => RuntimeErrorCode::ApiRequestFailed,
            InfraError::ApiNetworkFailed => RuntimeErrorCode::ApiNetworkFailed,
            InfraError::ApiResponseInvalid => RuntimeErrorCode::ApiResponseInvalid,
            InfraError::ApiEmptyTranscript => RuntimeErrorCode::ApiEmptyTranscript,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SessionRuntime;
    use crate::domain::RuntimeErrorCode;
    use crate::infra::{InfraError, Recorder, Transcriber};

    struct FailingRecorder;

    impl Recorder for FailingRecorder {
        fn start(&mut self) -> Result<(), InfraError> {
            Err(InfraError::AudioCaptureFailed)
        }

        fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
            Ok(Vec::new())
        }
    }

    struct FailingTranscriber;

    impl Transcriber for FailingTranscriber {
        fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
            Err(InfraError::ApiRequestFailed)
        }
    }

    struct RecorderOk;

    impl Recorder for RecorderOk {
        fn start(&mut self) -> Result<(), InfraError> {
            Ok(())
        }

        fn stop(&mut self) -> Result<Vec<u8>, InfraError> {
            Ok(vec![1, 2, 3])
        }
    }

    struct TranscriberOk;

    impl Transcriber for TranscriberOk {
        fn transcribe(&mut self, _audio: Vec<u8>) -> Result<String, InfraError> {
            Ok("hello".to_owned())
        }
    }

    #[test]
    fn maps_recorder_failures() {
        let mut runtime = SessionRuntime::new(Box::new(FailingRecorder), Box::new(TranscriberOk));

        let result = runtime.start_recording();
        assert_eq!(result, Err(RuntimeErrorCode::AudioCaptureFailed));
    }

    #[test]
    fn maps_transcriber_failures() {
        let mut runtime = SessionRuntime::new(Box::new(RecorderOk), Box::new(FailingTranscriber));

        let audio = runtime.stop_recording().expect("stop should succeed");
        let result = runtime.transcribe(audio);
        assert_eq!(result, Err(RuntimeErrorCode::ApiRequestFailed));
    }

    #[test]
    fn default_runtime_roundtrip_succeeds() {
        let mut runtime = SessionRuntime::default();

        runtime
            .start_recording()
            .expect("default recorder start should succeed");
        let audio = runtime
            .stop_recording()
            .expect("default recorder stop should succeed");
        let text = runtime
            .transcribe(audio)
            .expect("default transcriber should succeed");
        assert!(text.is_empty());
    }
}
