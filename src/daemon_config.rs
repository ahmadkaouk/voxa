use std::env;
use std::fs;
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use toml::Value;

use crate::cli::{ConfigCommand, ConfigSetCommand};
use crate::error::AppError;

const CONFIG_DIR_RELATIVE: &str = "Library/Application Support/voico";
const CONFIG_FILE_NAME: &str = "config.toml";

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize, ValueEnum, Default)]
#[serde(rename_all = "snake_case")]
pub enum DaemonHotkey {
    #[default]
    #[value(name = "right_option")]
    RightOption,
    #[value(name = "cmd_space")]
    CmdSpace,
    #[value(name = "fn")]
    Fn,
}

impl DaemonHotkey {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RightOption => "right_option",
            Self::CmdSpace => "cmd_space",
            Self::Fn => "fn",
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
pub struct DaemonConfig {
    #[serde(default = "default_toggle_hotkey")]
    pub toggle_hotkey: DaemonHotkey,
    #[serde(default = "default_hold_hotkey")]
    pub hold_hotkey: DaemonHotkey,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            toggle_hotkey: default_toggle_hotkey(),
            hold_hotkey: default_hold_hotkey(),
        }
    }
}

impl DaemonConfig {
    fn validate(self) -> Result<Self, AppError> {
        if self.toggle_hotkey == self.hold_hotkey {
            return Err(AppError::DaemonConfigHotkeyConflict);
        }

        Ok(self)
    }
}

fn default_toggle_hotkey() -> DaemonHotkey {
    DaemonHotkey::RightOption
}

fn default_hold_hotkey() -> DaemonHotkey {
    DaemonHotkey::Fn
}

pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new() -> Result<Self, AppError> {
        Ok(Self {
            path: default_config_path()?,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<DaemonConfig, AppError> {
        load_from_path(&self.path)
    }

    pub fn save(&self, config: DaemonConfig) -> Result<(), AppError> {
        save_to_path(&self.path, config)
    }
}

pub fn run(command: ConfigCommand) -> Result<(), AppError> {
    match command {
        ConfigCommand::Show => run_show(),
        ConfigCommand::Set(args) => run_set(args.command),
    }
}

fn run_show() -> Result<(), AppError> {
    let store = ConfigStore::new()?;
    let config = store.load()?;

    println!("config_path = {}", store.path().display());
    println!("toggle_hotkey = {}", config.toggle_hotkey.as_str());
    println!("hold_hotkey = {}", config.hold_hotkey.as_str());

    Ok(())
}

fn run_set(command: ConfigSetCommand) -> Result<(), AppError> {
    let store = ConfigStore::new()?;
    let mut config = store.load()?;

    match command {
        ConfigSetCommand::ToggleHotkey { value } => {
            config.toggle_hotkey = value;
        }
        ConfigSetCommand::HoldHotkey { value } => {
            config.hold_hotkey = value;
        }
    }

    store.save(config.validate()?)?;
    println!("OK CONFIG_UPDATED");

    run_show()
}

fn default_config_path() -> Result<PathBuf, AppError> {
    Ok(config_dir()?.join(CONFIG_FILE_NAME))
}

fn config_dir() -> Result<PathBuf, AppError> {
    Ok(home_dir()?.join(CONFIG_DIR_RELATIVE))
}

fn home_dir() -> Result<PathBuf, AppError> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(AppError::DaemonConfigPathUnavailable)
}

fn load_from_path(path: &Path) -> Result<DaemonConfig, AppError> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(DaemonConfig::default()),
        Err(_) => return Err(AppError::DaemonConfigReadFailed),
    };

    let parsed: Value = toml::from_str(&raw).map_err(|_| AppError::DaemonConfigInvalid)?;
    let Some(table) = parsed.as_table() else {
        return Err(AppError::DaemonConfigInvalid);
    };

    let has_new_key = table.contains_key("toggle_hotkey") || table.contains_key("hold_hotkey");
    let has_legacy_key = table.contains_key("hotkey") || table.contains_key("mode");

    if has_legacy_key && !has_new_key {
        return Ok(DaemonConfig::default());
    }

    parsed
        .try_into::<DaemonConfig>()
        .map_err(|_| AppError::DaemonConfigInvalid)?
        .validate()
}

fn save_to_path(path: &Path, config: DaemonConfig) -> Result<(), AppError> {
    let config = config.validate()?;
    let Some(parent) = path.parent() else {
        return Err(AppError::DaemonConfigWriteFailed);
    };
    fs::create_dir_all(parent).map_err(|_| AppError::DaemonConfigWriteFailed)?;

    let serialized = toml::to_string(&config).map_err(|_| AppError::DaemonConfigWriteFailed)?;
    let temp_path = temp_config_write_path(parent);
    let mut temp_file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|_| AppError::DaemonConfigWriteFailed)?;

    if temp_file.write_all(serialized.as_bytes()).is_err() || temp_file.sync_all().is_err() {
        let _ = fs::remove_file(&temp_path);
        return Err(AppError::DaemonConfigWriteFailed);
    }
    drop(temp_file);

    if fs::rename(&temp_path, path).is_err() {
        let _ = fs::remove_file(&temp_path);
        return Err(AppError::DaemonConfigWriteFailed);
    }

    Ok(())
}

fn temp_config_write_path(parent: &Path) -> PathBuf {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    parent.join(format!(".{CONFIG_FILE_NAME}.{pid}.{nanos}.tmp"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{DaemonConfig, DaemonHotkey, load_from_path, save_to_path};
    use crate::error::AppError;

    fn temp_config_path(name: &str) -> PathBuf {
        let pid = std::process::id();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("current time should be after epoch")
            .as_nanos();

        std::env::temp_dir()
            .join(format!("voico-{name}-{pid}-{nanos}"))
            .join("config.toml")
    }

    fn cleanup(path: &Path) {
        if let Some(parent) = path.parent() {
            let _ = fs::remove_dir_all(parent);
        }
    }

    #[test]
    fn load_returns_defaults_when_file_missing() {
        let path = temp_config_path("missing");
        let config = load_from_path(&path).expect("missing config should load defaults");

        assert_eq!(config, DaemonConfig::default());
        cleanup(&path);
    }

    #[test]
    fn load_parses_valid_new_schema() {
        let path = temp_config_path("parse");
        fs::create_dir_all(path.parent().expect("temp path should have parent"))
            .expect("failed to create temp dir");
        fs::write(
            &path,
            "toggle_hotkey = \"cmd_space\"\nhold_hotkey = \"fn\"\n",
        )
        .expect("failed to write config");

        let config = load_from_path(&path).expect("valid config should parse");
        assert_eq!(config.toggle_hotkey, DaemonHotkey::CmdSpace);
        assert_eq!(config.hold_hotkey, DaemonHotkey::Fn);

        cleanup(&path);
    }

    #[test]
    fn load_legacy_schema_falls_back_to_defaults() {
        let path = temp_config_path("legacy");
        fs::create_dir_all(path.parent().expect("temp path should have parent"))
            .expect("failed to create temp dir");
        fs::write(
            &path,
            "hotkey = \"cmd_space\"\nmode = \"hold\"\noutput = \"autopaste\"\n",
        )
        .expect("failed to write config");

        let config = load_from_path(&path).expect("legacy config should fall back to defaults");
        assert_eq!(config, DaemonConfig::default());

        cleanup(&path);
    }

    #[test]
    fn save_and_load_round_trip() {
        let path = temp_config_path("roundtrip");
        let expected = DaemonConfig {
            toggle_hotkey: DaemonHotkey::Fn,
            hold_hotkey: DaemonHotkey::CmdSpace,
        };

        save_to_path(&path, expected).expect("save should succeed");
        let actual = load_from_path(&path).expect("load should succeed");

        assert_eq!(actual, expected);
        cleanup(&path);
    }

    #[test]
    fn invalid_toml_returns_config_error() {
        let path = temp_config_path("invalid");
        fs::create_dir_all(path.parent().expect("temp path should have parent"))
            .expect("failed to create temp dir");
        fs::write(&path, "hotkey = [\n").expect("failed to write config");

        let result = load_from_path(&path);
        assert!(matches!(result, Err(AppError::DaemonConfigInvalid)));

        cleanup(&path);
    }

    #[test]
    fn load_rejects_conflicting_hotkeys() {
        let path = temp_config_path("conflict-load");
        fs::create_dir_all(path.parent().expect("temp path should have parent"))
            .expect("failed to create temp dir");
        fs::write(
            &path,
            "toggle_hotkey = \"right_option\"\nhold_hotkey = \"right_option\"\n",
        )
        .expect("failed to write config");

        let result = load_from_path(&path);
        assert!(matches!(result, Err(AppError::DaemonConfigHotkeyConflict)));

        cleanup(&path);
    }

    #[test]
    fn save_rejects_conflicting_hotkeys() {
        let path = temp_config_path("conflict-save");
        let result = save_to_path(
            &path,
            DaemonConfig {
                toggle_hotkey: DaemonHotkey::Fn,
                hold_hotkey: DaemonHotkey::Fn,
            },
        );

        assert!(matches!(result, Err(AppError::DaemonConfigHotkeyConflict)));
        cleanup(&path);
    }
}
