use std::io::{self, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use rdev::{EventType, Key, simulate};

use crate::error::AppError;

const CLIPBOARD_FAILED_WARNING: &str =
    "WARN OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.";
const AUTOPASTE_FAILED_WARNING: &str =
    "WARN OUTPUT_AUTOPASTE_FAILED: transcript copied but auto-paste failed.";

pub fn emit_daemon(transcript: &str) -> Result<(), AppError> {
    let mut stdout = io::stdout();
    emit_daemon_with(
        transcript,
        copy_to_clipboard,
        send_autopaste_shortcut,
        &mut stdout,
    )
    .map(|_| ())
    .map_err(|_| AppError::OutputWriteFailed)
}

fn copy_to_clipboard(text: &str) -> bool {
    copy_with_arboard(text).is_ok() || copy_with_pbcopy(text).is_ok()
}

fn send_autopaste_shortcut() -> bool {
    send_key_shortcut(&[
        EventType::KeyPress(Key::MetaLeft),
        EventType::KeyPress(Key::KeyV),
        EventType::KeyRelease(Key::KeyV),
        EventType::KeyRelease(Key::MetaLeft),
    ])
}

fn send_key_shortcut(events: &[EventType]) -> bool {
    for event in events {
        if simulate(event).is_err() {
            return false;
        }

        // macOS can drop synthetic events sent too quickly.
        thread::sleep(Duration::from_millis(20));
    }

    true
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

fn emit_clipboard_status<W, F>(
    transcript: &str,
    copy: F,
    writer: &mut W,
) -> io::Result<ClipboardOutcome>
where
    W: Write,
    F: Fn(&str) -> bool,
{
    if copy(transcript) {
        writeln!(writer, "OK COPIED_TO_CLIPBOARD")?;
        Ok(ClipboardOutcome::Copied)
    } else {
        writeln!(writer, "{CLIPBOARD_FAILED_WARNING}")?;
        Ok(ClipboardOutcome::Failed)
    }
}

fn emit_daemon_with<W, C, P>(
    transcript: &str,
    copy: C,
    autopaste: P,
    writer: &mut W,
) -> io::Result<(ClipboardOutcome, AutopasteOutcome)>
where
    W: Write,
    C: Fn(&str) -> bool,
    P: Fn() -> bool,
{
    let clipboard_outcome = emit_clipboard_status(transcript, copy, writer)?;

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
        emit_daemon_with,
    };

    #[test]
    fn daemon_copies_and_autopastes_when_copy_works() {
        let mut out = Vec::new();
        let (clipboard, autopaste) = emit_daemon_with("hello", |_| true, || true, &mut out)
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
        let (clipboard, autopaste) = emit_daemon_with("hello", |_| true, || false, &mut out)
            .expect("daemon output should succeed");

        assert_eq!(clipboard, ClipboardOutcome::Copied);
        assert_eq!(autopaste, AutopasteOutcome::Failed);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            format!("OK COPIED_TO_CLIPBOARD\n{AUTOPASTE_FAILED_WARNING}\n")
        );
    }

    #[test]
    fn daemon_skips_autopaste_when_copy_fails() {
        let mut out = Vec::new();
        let (clipboard, autopaste) = emit_daemon_with("hello", |_| false, || true, &mut out)
            .expect("daemon output should succeed");

        assert_eq!(clipboard, ClipboardOutcome::Failed);
        assert_eq!(autopaste, AutopasteOutcome::Skipped);
        assert_eq!(
            String::from_utf8(out).unwrap_or_default(),
            format!("{CLIPBOARD_FAILED_WARNING}\n")
        );
    }
}
