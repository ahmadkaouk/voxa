use std::env;
use std::fs;
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::cli::{
    ConfigCommand, ConfigSetCommand, DaemonHotkeyArg, DaemonModeArg, DaemonOutputArg,
};
use crate::error::AppError;

const CONFIG_DIR_RELATIVE: &str = "Library/Application Support/voico";
const CONFIG_FILE_NAME: &str = "config.toml";

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonHotkey {
    RightOption,
    CmdSpace,
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

impl From<DaemonHotkeyArg> for DaemonHotkey {
    fn from(value: DaemonHotkeyArg) -> Self {
        match value {
            DaemonHotkeyArg::RightOption => Self::RightOption,
            DaemonHotkeyArg::CmdSpace => Self::CmdSpace,
            DaemonHotkeyArg::Fn => Self::Fn,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonOutput {
    Clipboard,
    Autopaste,
}

impl DaemonOutput {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Clipboard => "clipboard",
            Self::Autopaste => "autopaste",
        }
    }
}

impl From<DaemonOutputArg> for DaemonOutput {
    fn from(value: DaemonOutputArg) -> Self {
        match value {
            DaemonOutputArg::Clipboard => Self::Clipboard,
            DaemonOutputArg::Autopaste => Self::Autopaste,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonMode {
    Toggle,
    Hold,
}

impl DaemonMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Toggle => "toggle",
            Self::Hold => "hold",
        }
    }
}

impl From<DaemonModeArg> for DaemonMode {
    fn from(value: DaemonModeArg) -> Self {
        match value {
            DaemonModeArg::Toggle => Self::Toggle,
            DaemonModeArg::Hold => Self::Hold,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct DaemonConfig {
    pub hotkey: DaemonHotkey,
    pub mode: DaemonMode,
    pub output: DaemonOutput,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            hotkey: DaemonHotkey::RightOption,
            mode: DaemonMode::Toggle,
            output: DaemonOutput::Clipboard,
        }
    }
}

#[derive(Debug, Deserialize)]
struct DaemonConfigFile {
    hotkey: Option<DaemonHotkey>,
    mode: Option<DaemonMode>,
    output: Option<DaemonOutput>,
}

#[derive(Debug, Serialize)]
struct StoredDaemonConfig {
    hotkey: DaemonHotkey,
    mode: DaemonMode,
    output: DaemonOutput,
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
    println!("hotkey = {}", config.hotkey.as_str());
    println!("mode = {}", config.mode.as_str());
    println!("output = {}", config.output.as_str());

    Ok(())
}

fn run_set(command: ConfigSetCommand) -> Result<(), AppError> {
    let store = ConfigStore::new()?;
    let mut config = store.load()?;

    match command {
        ConfigSetCommand::Hotkey { value } => {
            config.hotkey = value.into();
        }
        ConfigSetCommand::Mode { value } => {
            config.mode = value.into();
        }
        ConfigSetCommand::Output { value } => {
            config.output = value.into();
        }
    }

    store.save(config)?;
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

    let parsed: DaemonConfigFile =
        toml::from_str(&raw).map_err(|_| AppError::DaemonConfigInvalid)?;

    Ok(DaemonConfig {
        hotkey: parsed.hotkey.unwrap_or(DaemonHotkey::RightOption),
        mode: parsed.mode.unwrap_or(DaemonMode::Toggle),
        output: parsed.output.unwrap_or(DaemonOutput::Clipboard),
    })
}

fn save_to_path(path: &Path, config: DaemonConfig) -> Result<(), AppError> {
    let Some(parent) = path.parent() else {
        return Err(AppError::DaemonConfigWriteFailed);
    };
    fs::create_dir_all(parent).map_err(|_| AppError::DaemonConfigWriteFailed)?;

    let stored = StoredDaemonConfig {
        hotkey: config.hotkey,
        mode: config.mode,
        output: config.output,
    };

    let serialized = toml::to_string(&stored).map_err(|_| AppError::DaemonConfigWriteFailed)?;
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

    use super::{
        DaemonConfig, DaemonHotkey, DaemonMode, DaemonOutput, load_from_path, save_to_path,
    };
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
    fn load_parses_valid_file() {
        let path = temp_config_path("parse");
        fs::create_dir_all(path.parent().expect("temp path should have parent"))
            .expect("failed to create temp dir");
        fs::write(
            &path,
            "hotkey = \"cmd_space\"\nmode = \"hold\"\noutput = \"autopaste\"\n",
        )
        .expect("failed to write config");

        let config = load_from_path(&path).expect("valid config should parse");
        assert_eq!(config.hotkey, DaemonHotkey::CmdSpace);
        assert_eq!(config.mode, DaemonMode::Hold);
        assert_eq!(config.output, DaemonOutput::Autopaste);

        cleanup(&path);
    }

    #[test]
    fn save_and_load_round_trip() {
        let path = temp_config_path("roundtrip");
        let expected = DaemonConfig {
            hotkey: DaemonHotkey::Fn,
            mode: DaemonMode::Toggle,
            output: DaemonOutput::Clipboard,
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
}
