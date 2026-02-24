use clap::{Args, Parser, Subcommand, ValueEnum};

use crate::error::AppError;

const DEFAULT_MAX_SECONDS: u32 = 90;

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
    #[arg(long, value_enum, default_value_t = Language::Auto)]
    pub language: Language,

    #[arg(long, value_enum, default_value_t = Model::Gpt4oMiniTranscribe)]
    pub model: Model,

    #[arg(long = "max-seconds", default_value_t = DEFAULT_MAX_SECONDS)]
    pub max_seconds: u32,

    #[arg(long, value_enum, default_value_t = OutputTarget::Clipboard)]
    pub output: OutputTarget,
}

impl CommonArgs {
    pub fn validate(&self) -> Result<(), AppError> {
        if self.max_seconds == 0 {
            return Err(AppError::InvalidMaxSeconds);
        }

        Ok(())
    }
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
