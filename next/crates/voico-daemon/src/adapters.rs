use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use voico_core::infra::{
    InfraError, NullOutputSink, NullRecorder, NullTranscriber, OutputResult, OutputSink,
};

const PBCOPY_PATH: &str = "/usr/bin/pbcopy";
const OUTPUT_MODE_CLIPBOARD_AUTOPASTE: &str = "clipboard_autopaste";
const OUTPUT_MODE_CLIPBOARD_ONLY: &str = "clipboard_only";
const OUTPUT_MODE_NONE: &str = "none";

pub(crate) fn build_runtime_for_output_mode(output_mode: &str) -> voico_core::app::SessionRuntime {
    let output = build_output_sink(output_mode);

    voico_core::app::SessionRuntime::new(
        Box::new(NullRecorder::default()),
        Box::new(NullTranscriber),
        output,
    )
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
