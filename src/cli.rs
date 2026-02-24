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
}

#[derive(Debug, Clone, Args)]
pub struct CommonArgs {
    #[arg(long, value_enum)]
    pub language: Option<Language>,

    #[arg(long, value_enum)]
    pub model: Option<Model>,

    #[arg(long = "max-seconds")]
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
