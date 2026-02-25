use clap::{Args, Parser, Subcommand, ValueEnum};

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
    Toggle(CommonArgs),
    Hold(CommonArgs),
    Daemon,
    Service(ServiceArgs),
    Config(ConfigArgs),
}

#[derive(Debug, Clone, Args)]
pub struct CommonArgs {
    #[arg(long, value_enum)]
    pub language: Option<Language>,

    #[arg(long, value_enum)]
    pub model: Option<Model>,

    #[arg(long = "max-seconds", value_parser = clap::value_parser!(u32).range(1..))]
    pub max_seconds: Option<u32>,

    #[arg(long, value_enum)]
    pub output: Option<OutputTarget>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum Model {
    #[value(name = "gpt-4o-mini-transcribe")]
    Gpt4oMiniTranscribe,
    #[value(name = "gpt-4o-transcribe")]
    Gpt4oTranscribe,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum Language {
    Auto,
    En,
    Fr,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum OutputTarget {
    Clipboard,
    Stdout,
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
    Hotkey {
        #[arg(value_enum)]
        value: DaemonHotkeyArg,
    },
    Output {
        #[arg(value_enum)]
        value: DaemonOutputArg,
    },
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum DaemonHotkeyArg {
    #[value(name = "right_option")]
    RightOption,
    #[value(name = "cmd_space")]
    CmdSpace,
    #[value(name = "fn")]
    Fn,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, ValueEnum)]
pub enum DaemonOutputArg {
    #[value(name = "clipboard")]
    Clipboard,
    #[value(name = "autopaste")]
    Autopaste,
}
