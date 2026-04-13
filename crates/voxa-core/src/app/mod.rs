use crate::domain::RuntimeErrorCode;
use crate::infra::{
    InfraError, NullOutputSink, NullRecorder, NullTranscriber, OutputResult, OutputSink, Recorder,
    Transcriber,
};

pub struct SessionRuntime {
    recorder: Box<dyn Recorder>,
    transcriber: Box<dyn Transcriber>,
    output: Box<dyn OutputSink>,
}

impl SessionRuntime {
    pub fn new(
        recorder: Box<dyn Recorder>,
        transcriber: Box<dyn Transcriber>,
        output: Box<dyn OutputSink>,
    ) -> Self {
        Self {
            recorder,
            transcriber,
            output,
        }
    }

    pub fn start_recording(&mut self) -> Result<(), RuntimeErrorCode> {
        self.recorder.start().map_err(map_infra_error)
    }

    pub fn stop_recording(&mut self) -> Result<Vec<u8>, RuntimeErrorCode> {
        self.recorder.stop().map_err(map_infra_error)
    }

    pub fn current_recording_level(&self) -> Option<f32> {
        self.recorder.current_level()
    }

    pub fn transcribe(&mut self, audio: Vec<u8>) -> Result<String, RuntimeErrorCode> {
        self.transcriber.transcribe(audio).map_err(map_infra_error)
    }

    pub fn output_text(&mut self, text: &str) -> Result<OutputResult, RuntimeErrorCode> {
        self.output.output(text).map_err(map_infra_error)
    }
}

impl Default for SessionRuntime {
    fn default() -> Self {
        Self::new(
            Box::new(NullRecorder::default()),
            Box::new(NullTranscriber),
            Box::new(NullOutputSink),
        )
    }
}

fn map_infra_error(error: InfraError) -> RuntimeErrorCode {
    match error {
        InfraError::AudioCaptureFailed => RuntimeErrorCode::AudioCaptureFailed,
        InfraError::ApiAuthFailed => RuntimeErrorCode::ApiAuthFailed,
        InfraError::ApiRateLimited => RuntimeErrorCode::ApiRateLimited,
        InfraError::ApiRequestFailed => RuntimeErrorCode::ApiRequestFailed,
        InfraError::ApiNetworkFailed => RuntimeErrorCode::ApiNetworkFailed,
        InfraError::ApiResponseInvalid => RuntimeErrorCode::ApiResponseInvalid,
        InfraError::ApiEmptyTranscript => RuntimeErrorCode::ApiEmptyTranscript,
        InfraError::OutputFailed => RuntimeErrorCode::OutputFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::SessionRuntime;
    use crate::domain::RuntimeErrorCode;
    use crate::infra::{InfraError, OutputResult, OutputSink, Recorder, Transcriber};

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

    struct FailingOutput;

    impl OutputSink for FailingOutput {
        fn output(&mut self, _text: &str) -> Result<OutputResult, InfraError> {
            Err(InfraError::OutputFailed)
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

    struct OutputOk;

    impl OutputSink for OutputOk {
        fn output(&mut self, text: &str) -> Result<OutputResult, InfraError> {
            Ok(OutputResult {
                clipboard: !text.is_empty(),
                autopaste: false,
            })
        }
    }

    #[test]
    fn maps_recorder_failures() {
        let mut runtime = SessionRuntime::new(
            Box::new(FailingRecorder),
            Box::new(TranscriberOk),
            Box::new(OutputOk),
        );

        let result = runtime.start_recording();
        assert_eq!(result, Err(RuntimeErrorCode::AudioCaptureFailed));
    }

    #[test]
    fn maps_transcriber_failures() {
        let mut runtime = SessionRuntime::new(
            Box::new(RecorderOk),
            Box::new(FailingTranscriber),
            Box::new(OutputOk),
        );

        let audio = runtime.stop_recording().expect("stop should succeed");
        let result = runtime.transcribe(audio);
        assert_eq!(result, Err(RuntimeErrorCode::ApiRequestFailed));
    }

    #[test]
    fn maps_output_failures() {
        let mut runtime = SessionRuntime::new(
            Box::new(RecorderOk),
            Box::new(TranscriberOk),
            Box::new(FailingOutput),
        );

        let result = runtime.output_text("hello");
        assert_eq!(result, Err(RuntimeErrorCode::OutputFailed));
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
        let output = runtime
            .output_text(&text)
            .expect("default output should succeed");

        assert!(!output.clipboard);
        assert!(!output.autopaste);
    }
}
