use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use voico_core::app::SessionRuntime;
use voico_core::infra::{
    InfraError, NullOutputSink, NullRecorder, NullTranscriber, OutputResult, OutputSink,
};

const PBCOPY_PATH: &str = "/usr/bin/pbcopy";

pub(crate) fn build_runtime() -> SessionRuntime {
    let output: Box<dyn OutputSink> = if Path::new(PBCOPY_PATH).exists() {
        Box::new(ClipboardOutputSink)
    } else {
        Box::new(NullOutputSink)
    };

    SessionRuntime::new(
        Box::new(NullRecorder::default()),
        Box::new(NullTranscriber),
        output,
    )
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
