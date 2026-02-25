use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

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

fn run_with_home(args: &[&str], home: &std::path::Path) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_voico"));
    command
        .args(args)
        .env("HOME", home)
        .env_remove("OPENAI_API_KEY")
        .env_remove("VOICO_MODEL")
        .env_remove("VOICO_LANGUAGE")
        .env_remove("VOICO_MAX_SECONDS")
        .env_remove("VOICO_OUTPUT");

    command.output().expect("failed to execute voico")
}

fn temp_home(name: &str) -> std::path::PathBuf {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("current time should be after epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("voico-cli-{name}-{pid}-{nanos}"))
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
    assert!(!stderr.contains("MAX_SECONDS_INVALID"));
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
fn toggle_without_api_key_reports_missing_key_error() {
    let output = run(&["toggle"]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("ERROR OPENAI_API_KEY_MISSING"));
}

#[test]
fn help_returns_success() {
    let output = run(&["--help"]);

    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn config_show_uses_defaults_without_api_key() {
    let home = temp_home("config-show");
    std::fs::create_dir_all(&home).expect("failed to create temp home");

    let output = run_with_home(&["config", "show"], &home);
    let stdout = String::from_utf8_lossy(&output.stdout);

    assert_eq!(output.status.code(), Some(0));
    assert!(stdout.contains("hotkey = right_option"));
    assert!(stdout.contains("output = clipboard"));

    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn config_set_output_persists_setting() {
    let home = temp_home("config-set");
    std::fs::create_dir_all(&home).expect("failed to create temp home");

    let set_output = run_with_home(&["config", "set", "output", "autopaste"], &home);
    assert_eq!(set_output.status.code(), Some(0));

    let show = run_with_home(&["config", "show"], &home);
    let stdout = String::from_utf8_lossy(&show.stdout);
    assert_eq!(show.status.code(), Some(0));
    assert!(stdout.contains("output = autopaste"));

    let _ = std::fs::remove_dir_all(home);
}
