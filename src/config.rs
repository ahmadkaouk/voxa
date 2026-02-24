use std::env;

use crate::cli::{CommonArgs, Language, Model, OutputTarget};
use crate::error::AppError;

const DEFAULT_MODEL: Model = Model::Gpt4oMiniTranscribe;
const DEFAULT_LANGUAGE: Language = Language::Auto;
const DEFAULT_MAX_SECONDS: u32 = 90;
const DEFAULT_OUTPUT: OutputTarget = OutputTarget::Clipboard;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct AppConfig {
    pub api_key: String,
    pub model: Model,
    pub language: Language,
    pub max_seconds: u32,
    pub output: OutputTarget,
}

pub fn load(args: &CommonArgs) -> Result<AppConfig, AppError> {
    let _ = dotenvy::dotenv();

    let api_key = resolve_api_key()?;
    let model = match args.model {
        Some(model) => model,
        None => resolve_model_env()?.unwrap_or(DEFAULT_MODEL),
    };
    let language = match args.language {
        Some(language) => language,
        None => resolve_language_env()?.unwrap_or(DEFAULT_LANGUAGE),
    };
    let max_seconds = match args.max_seconds {
        Some(max_seconds) if max_seconds > 0 => max_seconds,
        Some(_) => return Err(AppError::CfgInvalidMaxSeconds),
        None => resolve_max_seconds_env()?.unwrap_or(DEFAULT_MAX_SECONDS),
    };
    let output = match args.output {
        Some(output) => output,
        None => resolve_output_env()?.unwrap_or(DEFAULT_OUTPUT),
    };

    Ok(AppConfig {
        api_key,
        model,
        language,
        max_seconds,
        output,
    })
}

fn resolve_api_key() -> Result<String, AppError> {
    match env::var("OPENAI_API_KEY") {
        Ok(value) if !value.trim().is_empty() => Ok(value),
        _ => Err(AppError::CfgApiKeyMissing),
    }
}

fn resolve_model_env() -> Result<Option<Model>, AppError> {
    let value = match env::var("VOICO_MODEL") {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(AppError::CfgInvalidModel),
    };

    match value.trim() {
        "gpt-4o-mini-transcribe" => Ok(Some(Model::Gpt4oMiniTranscribe)),
        "gpt-4o-transcribe" => Ok(Some(Model::Gpt4oTranscribe)),
        _ => Err(AppError::CfgInvalidModel),
    }
}

fn resolve_language_env() -> Result<Option<Language>, AppError> {
    let value = match env::var("VOICO_LANGUAGE") {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(AppError::CfgInvalidLanguage),
    };

    match value.trim() {
        "auto" => Ok(Some(Language::Auto)),
        "en" => Ok(Some(Language::En)),
        "fr" => Ok(Some(Language::Fr)),
        _ => Err(AppError::CfgInvalidLanguage),
    }
}

fn resolve_max_seconds_env() -> Result<Option<u32>, AppError> {
    let value = match env::var("VOICO_MAX_SECONDS") {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(AppError::CfgInvalidMaxSeconds),
    };

    let parsed = value
        .trim()
        .parse::<u32>()
        .map_err(|_| AppError::CfgInvalidMaxSeconds)?;
    if parsed == 0 {
        return Err(AppError::CfgInvalidMaxSeconds);
    }

    Ok(Some(parsed))
}

fn resolve_output_env() -> Result<Option<OutputTarget>, AppError> {
    let value = match env::var("VOICO_OUTPUT") {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(AppError::CfgInvalidOutput),
    };

    match value.trim() {
        "clipboard" => Ok(Some(OutputTarget::Clipboard)),
        "stdout" => Ok(Some(OutputTarget::Stdout)),
        _ => Err(AppError::CfgInvalidOutput),
    }
}
