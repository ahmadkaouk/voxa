use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_voico"))
        .env("OPENAI_API_KEY", "test-key")
        .env_remove("VOICO_MODEL")
        .env_remove("VOICO_LANGUAGE")
        .env_remove("VOICO_MAX_SECONDS")
        .env_remove("VOICO_OUTPUT")
        .args(args)
        .output()
        .expect("failed to execute voico")
}

#[test]
fn invalid_model_is_rejected_at_parse_time() {
    let output = run(&["toggle", "--model", "foo"]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("invalid value 'foo'"));
    assert!(stderr.contains("gpt-4o-mini-transcribe"));
    assert!(stderr.contains("gpt-4o-transcribe"));
}

#[test]
fn invalid_max_seconds_is_rejected_at_parse_time() {
    let output = run(&["toggle", "--max-seconds", "0"]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("--max-seconds"));
    assert!(stderr.contains("0"));
    assert!(!stderr.contains("CFG_INVALID_MAX_SECONDS"));
}

#[test]
fn stdout_output_skips_clipboard_success_line() {
    let output = run(&["toggle", "--output", "stdout"]);
    let stdout = String::from_utf8_lossy(&output.stdout);

    assert_eq!(output.status.code(), Some(0));
    assert!(stdout.contains("OK TRANSCRIPTION_READY"));
    assert!(!stdout.contains("OK COPIED_TO_CLIPBOARD"));
}

#[test]
fn clipboard_output_emits_clipboard_success_line() {
    let output = run(&["toggle", "--output", "clipboard"]);
    let stdout = String::from_utf8_lossy(&output.stdout);

    assert_eq!(output.status.code(), Some(0));
    assert!(stdout.contains("OK TRANSCRIPTION_READY"));
    assert!(stdout.contains("OK COPIED_TO_CLIPBOARD"));
}

#[test]
fn hold_command_uses_shared_execution_behavior() {
    let output = run(&["hold", "--output", "stdout"]);
    let stdout = String::from_utf8_lossy(&output.stdout);

    assert_eq!(output.status.code(), Some(0));
    assert!(stdout.contains("OK TRANSCRIPTION_READY"));
    assert!(!stdout.contains("OK COPIED_TO_CLIPBOARD"));
}
