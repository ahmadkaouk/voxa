use clap::{Args, Parser, Subcommand, ValueEnum};

use crate::daemon_config::DaemonHotkey;

#[derive(Debug, Parser)]
#[command(
    name = "voico",
    version,
    about = "Local voice-to-text CLI scaffold",
    long_about = None
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    Daemon,
    Service(ServiceArgs),
    Config(ConfigArgs),
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum Model {
    #[value(name = "gpt-4o-mini-transcribe")]
    Gpt4oMiniTranscribe,
    #[value(name = "gpt-4o-transcribe")]
    Gpt4oTranscribe,
}

#[derive(Debug, Args)]
pub struct ServiceArgs {
    #[command(subcommand)]
    pub command: ServiceCommand,
}

#[derive(Debug, Subcommand)]
pub enum ServiceCommand {
    Install,
    Uninstall,
    Status,
}

#[derive(Debug, Args)]
pub struct ConfigArgs {
    #[command(subcommand)]
    pub command: ConfigCommand,
}

#[derive(Debug, Subcommand)]
pub enum ConfigCommand {
    Show,
    Set(ConfigSetArgs),
}

#[derive(Debug, Args)]
pub struct ConfigSetArgs {
    #[command(subcommand)]
    pub command: ConfigSetCommand,
}

#[derive(Debug, Subcommand)]
pub enum ConfigSetCommand {
    ToggleHotkey {
        #[arg(value_enum)]
        value: DaemonHotkey,
    },
    HoldHotkey {
        #[arg(value_enum)]
        value: DaemonHotkey,
    },
}
