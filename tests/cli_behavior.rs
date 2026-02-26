use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

fn run(args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_voico"));
    command
        .args(args)
        .env_remove("OPENAI_API_KEY")
        .env_remove("VOICO_MODEL");

    command.output().expect("failed to execute voico")
}

fn run_with_home(args: &[&str], home: &std::path::Path) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_voico"));
    command
        .args(args)
        .env("HOME", home)
        .env_remove("OPENAI_API_KEY")
        .env_remove("VOICO_MODEL");

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
    assert!(stdout.contains("toggle_hotkey = right_option"));
    assert!(stdout.contains("hold_hotkey = fn"));

    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn config_set_hotkeys_persist_settings() {
    let home = temp_home("config-hotkeys");
    std::fs::create_dir_all(&home).expect("failed to create temp home");

    let set_toggle = run_with_home(&["config", "set", "toggle-hotkey", "cmd_space"], &home);
    assert_eq!(set_toggle.status.code(), Some(0));

    let set_hold = run_with_home(&["config", "set", "hold-hotkey", "fn"], &home);
    assert_eq!(set_hold.status.code(), Some(0));

    let show = run_with_home(&["config", "show"], &home);
    let stdout = String::from_utf8_lossy(&show.stdout);
    assert_eq!(show.status.code(), Some(0));
    assert!(stdout.contains("toggle_hotkey = cmd_space"));
    assert!(stdout.contains("hold_hotkey = fn"));

    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn config_set_rejects_conflicting_hotkeys() {
    let home = temp_home("config-conflict");
    std::fs::create_dir_all(&home).expect("failed to create temp home");

    let conflict = run_with_home(&["config", "set", "hold-hotkey", "right_option"], &home);
    let stderr = String::from_utf8_lossy(&conflict.stderr);

    assert_eq!(conflict.status.code(), Some(1));
    assert!(stderr.contains("ERROR DAEMON_CONFIG_HOTKEY_CONFLICT"));

    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn legacy_mode_and_hotkey_set_commands_are_rejected() {
    let old_hotkey = run(&["config", "set", "hotkey", "right_option"]);
    let old_hotkey_stderr = String::from_utf8_lossy(&old_hotkey.stderr);
    assert_eq!(old_hotkey.status.code(), Some(1));
    assert!(old_hotkey_stderr.contains("unrecognized subcommand"));

    let old_mode = run(&["config", "set", "mode", "toggle"]);
    let old_mode_stderr = String::from_utf8_lossy(&old_mode.stderr);
    assert_eq!(old_mode.status.code(), Some(1));
    assert!(old_mode_stderr.contains("unrecognized subcommand"));
}
