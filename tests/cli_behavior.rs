use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_voico"));
    command
        .args(args)
        .env_remove("OPENAI_API_KEY")
        .env_remove("VOICO_MODEL")
        .env_remove("VOICO_LANGUAGE")
        .env_remove("VOICO_MAX_SECONDS")
        .env_remove("VOICO_OUTPUT");

    command.output().expect("failed to execute voico")
}

fn run_with_api_key(args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_voico"));
    command
        .args(args)
        .env("OPENAI_API_KEY", "dummy")
        .env_remove("VOICO_MODEL")
        .env_remove("VOICO_LANGUAGE")
        .env_remove("VOICO_MAX_SECONDS")
        .env_remove("VOICO_OUTPUT");

    command.output().expect("failed to execute voico")
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
    assert!(!stderr.contains("CONFIG_INVALID_MAX_SECONDS"));
}

#[test]
fn hold_command_reports_unsupported_mode() {
    let output = run_with_api_key(&["hold"]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("ERROR INPUT_MODE_UNSUPPORTED"));
    assert!(stderr.contains("Use voico toggle instead."));
}

#[test]
fn toggle_without_api_key_reports_config_error() {
    let output = run(&["toggle"]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("ERROR CONFIG_API_KEY_MISSING"));
}

#[test]
fn help_returns_success() {
    let output = run(&["--help"]);

    assert_eq!(output.status.code(), Some(0));
}
