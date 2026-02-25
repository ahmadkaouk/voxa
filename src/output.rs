use std::io::{self, Write};
use std::process::{Command, Stdio};

use crate::cli::OutputTarget;

const CLIPBOARD_FAILED_WARNING: &str =
    "WARN OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.";

pub fn emit(transcript: &str, target: OutputTarget) {
    let mut stdout = io::stdout();
    let _ = emit_with(transcript, target, copy_to_clipboard, &mut stdout);
}

fn emit_with<W, F>(
    transcript: &str,
    target: OutputTarget,
    copy: F,
    writer: &mut W,
) -> io::Result<ClipboardOutcome>
where
    W: Write,
    F: Fn(&str) -> bool,
{
    writeln!(writer, "{transcript}")?;

    if !matches!(target, OutputTarget::Clipboard) {
        return Ok(ClipboardOutcome::Skipped);
    }

    if copy(transcript) {
        writeln!(writer, "OK COPIED_TO_CLIPBOARD")?;
        Ok(ClipboardOutcome::Copied)
    } else {
        writeln!(writer, "{CLIPBOARD_FAILED_WARNING}")?;
        Ok(ClipboardOutcome::Failed)
    }
}

fn copy_to_clipboard(text: &str) -> bool {
    copy_with_arboard(text).is_ok() || copy_with_pbcopy(text).is_ok()
}

fn copy_with_arboard(text: &str) -> Result<(), ()> {
    let mut clipboard = arboard::Clipboard::new().map_err(|_| ())?;
    clipboard.set_text(text.to_owned()).map_err(|_| ())
}

fn copy_with_pbcopy(text: &str) -> Result<(), ()> {
    let mut child = Command::new("pbcopy")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|_| ())?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).map_err(|_| ())?;
    } else {
        return Err(());
    }

    let status = child.wait().map_err(|_| ())?;
    if status.success() { Ok(()) } else { Err(()) }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum ClipboardOutcome {
    Skipped,
    Copied,
    Failed,
}

#[cfg(test)]
mod tests {
    use super::{CLIPBOARD_FAILED_WARNING, ClipboardOutcome, emit_with};
    use crate::cli::OutputTarget;

    #[test]
    fn stdout_target_prints_transcript_only() {
        let mut out = Vec::new();
        let result = emit_with("hello", OutputTarget::Stdout, |_| true, &mut out)
            .expect("output emit should succeed");

        assert_eq!(result, ClipboardOutcome::Skipped);
        assert_eq!(String::from_utf8(out).unwrap_or_default(), "hello\n");
    }

    #[test]
    fn clipboard_target_prints_success_when_copy_works() {
        let mut out = Vec::new();
        let result = emit_with("hello", OutputTarget::Clipboard, |_| true, &mut out)
            .expect("output emit should succeed");

        assert_eq!(result, ClipboardOutcome::Copied);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            "hello\nOK COPIED_TO_CLIPBOARD\n"
        );
    }

    #[test]
    fn clipboard_target_prints_warning_when_copy_fails() {
        let mut out = Vec::new();
        let result = emit_with("hello", OutputTarget::Clipboard, |_| false, &mut out)
            .expect("output emit should succeed");

        assert_eq!(result, ClipboardOutcome::Failed);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            format!("hello\n{CLIPBOARD_FAILED_WARNING}\n")
        );
    }

    #[test]
    fn empty_transcript_is_still_emitted() {
        let mut out = Vec::new();
        let result = emit_with("", OutputTarget::Stdout, |_| true, &mut out)
            .expect("output emit should succeed");

        assert_eq!(result, ClipboardOutcome::Skipped);
        assert_eq!(String::from_utf8(out).unwrap_or_default(), "\n");
    }
}
