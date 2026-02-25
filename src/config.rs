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
    let model = args
        .model
        .unwrap_or(resolve_model_env()?.unwrap_or(DEFAULT_MODEL));
    let language = args
        .language
        .unwrap_or(resolve_language_env()?.unwrap_or(DEFAULT_LANGUAGE));
    let max_seconds = args
        .max_seconds
        .unwrap_or(resolve_max_seconds_env()?.unwrap_or(DEFAULT_MAX_SECONDS));
    let output = args
        .output
        .unwrap_or(resolve_output_env()?.unwrap_or(DEFAULT_OUTPUT));

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
        _ => Err(AppError::ApiKeyMissing),
    }
}

fn resolve_model_env() -> Result<Option<Model>, AppError> {
    resolve_optional_env("VOICO_MODEL", parse_model, AppError::InvalidModel)
}

fn resolve_language_env() -> Result<Option<Language>, AppError> {
    resolve_optional_env("VOICO_LANGUAGE", parse_language, AppError::InvalidLanguage)
}

fn resolve_max_seconds_env() -> Result<Option<u32>, AppError> {
    resolve_optional_env(
        "VOICO_MAX_SECONDS",
        parse_max_seconds,
        AppError::InvalidMaxSeconds,
    )
}

fn resolve_output_env() -> Result<Option<OutputTarget>, AppError> {
    resolve_optional_env("VOICO_OUTPUT", parse_output, AppError::InvalidOutput)
}

fn resolve_optional_env<T>(
    key: &str,
    parse: fn(&str) -> Option<T>,
    parse_error: AppError,
) -> Result<Option<T>, AppError> {
    let value = match env::var(key) {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(parse_error),
    };

    parse(value.trim()).ok_or(parse_error).map(Some)
}

fn parse_model(value: &str) -> Option<Model> {
    match value {
        "gpt-4o-mini-transcribe" => Some(Model::Gpt4oMiniTranscribe),
        "gpt-4o-transcribe" => Some(Model::Gpt4oTranscribe),
        _ => None,
    }
}

fn parse_language(value: &str) -> Option<Language> {
    match value {
        "auto" => Some(Language::Auto),
        "en" => Some(Language::En),
        "fr" => Some(Language::Fr),
        _ => None,
    }
}

fn parse_max_seconds(value: &str) -> Option<u32> {
    let parsed = value.parse::<u32>().ok()?;
    if parsed == 0 {
        return None;
    }

    Some(parsed)
}

fn parse_output(value: &str) -> Option<OutputTarget> {
    match value {
        "clipboard" => Some(OutputTarget::Clipboard),
        "stdout" => Some(OutputTarget::Stdout),
        _ => None,
    }
}
