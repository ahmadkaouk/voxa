use std::io::{self, Write};
use std::process::{Command, Stdio};

use crate::cli::OutputTarget;
use crate::daemon_config::DaemonOutput;

const CLIPBOARD_FAILED_WARNING: &str =
    "WARN OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.";
const AUTOPASTE_FAILED_WARNING: &str =
    "WARN OUTPUT_AUTOPASTE_FAILED: transcript copied but auto-paste failed.";

pub fn emit(transcript: &str, target: OutputTarget) {
    let mut stdout = io::stdout();
    let _ = emit_with(transcript, target, copy_to_clipboard, &mut stdout);
}

pub fn emit_daemon(transcript: &str, target: DaemonOutput) {
    let mut stdout = io::stdout();
    let _ = emit_daemon_with(
        transcript,
        target,
        copy_to_clipboard,
        send_autopaste_shortcut,
        &mut stdout,
    );
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

fn send_autopaste_shortcut() -> bool {
    Command::new("osascript")
        .arg("-e")
        .arg("tell application \"System Events\" to keystroke \"v\" using command down")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
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

fn emit_daemon_with<W, C, P>(
    transcript: &str,
    target: DaemonOutput,
    copy: C,
    autopaste: P,
    writer: &mut W,
) -> io::Result<(ClipboardOutcome, AutopasteOutcome)>
where
    W: Write,
    C: Fn(&str) -> bool,
    P: Fn() -> bool,
{
    let clipboard_outcome = if copy(transcript) {
        writeln!(writer, "OK COPIED_TO_CLIPBOARD")?;
        ClipboardOutcome::Copied
    } else {
        writeln!(writer, "{CLIPBOARD_FAILED_WARNING}")?;
        ClipboardOutcome::Failed
    };

    if !matches!(target, DaemonOutput::Autopaste) {
        return Ok((clipboard_outcome, AutopasteOutcome::Skipped));
    }

    if !matches!(clipboard_outcome, ClipboardOutcome::Copied) {
        return Ok((clipboard_outcome, AutopasteOutcome::Skipped));
    }

    let autopaste_outcome = if autopaste() {
        writeln!(writer, "OK AUTOPASTE_SENT")?;
        AutopasteOutcome::Sent
    } else {
        writeln!(writer, "{AUTOPASTE_FAILED_WARNING}")?;
        AutopasteOutcome::Failed
    };

    Ok((clipboard_outcome, autopaste_outcome))
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum ClipboardOutcome {
    Skipped,
    Copied,
    Failed,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum AutopasteOutcome {
    Skipped,
    Sent,
    Failed,
}

#[cfg(test)]
mod tests {
    use super::{
        AUTOPASTE_FAILED_WARNING, AutopasteOutcome, CLIPBOARD_FAILED_WARNING, ClipboardOutcome,
        emit_daemon_with, emit_with,
    };
    use crate::cli::OutputTarget;
    use crate::daemon_config::DaemonOutput;

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

    #[test]
    fn daemon_clipboard_target_only_copies() {
        let mut out = Vec::new();
        let (clipboard, autopaste) = emit_daemon_with(
            "hello",
            DaemonOutput::Clipboard,
            |_| true,
            || true,
            &mut out,
        )
        .expect("daemon output should succeed");

        assert_eq!(clipboard, ClipboardOutcome::Copied);
        assert_eq!(autopaste, AutopasteOutcome::Skipped);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            "OK COPIED_TO_CLIPBOARD\n"
        );
    }

    #[test]
    fn daemon_autopaste_sends_shortcut_after_copy() {
        let mut out = Vec::new();
        let (clipboard, autopaste) = emit_daemon_with(
            "hello",
            DaemonOutput::Autopaste,
            |_| true,
            || true,
            &mut out,
        )
        .expect("daemon output should succeed");

        assert_eq!(clipboard, ClipboardOutcome::Copied);
        assert_eq!(autopaste, AutopasteOutcome::Sent);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            "OK COPIED_TO_CLIPBOARD\nOK AUTOPASTE_SENT\n"
        );
    }

    #[test]
    fn daemon_autopaste_warns_on_shortcut_failure() {
        let mut out = Vec::new();
        let (clipboard, autopaste) = emit_daemon_with(
            "hello",
            DaemonOutput::Autopaste,
            |_| true,
            || false,
            &mut out,
        )
        .expect("daemon output should succeed");

        assert_eq!(clipboard, ClipboardOutcome::Copied);
        assert_eq!(autopaste, AutopasteOutcome::Failed);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            format!("OK COPIED_TO_CLIPBOARD\n{AUTOPASTE_FAILED_WARNING}\n")
        );
    }
}
