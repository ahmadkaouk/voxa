use std::env;

use clap::ValueEnum;

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
    let model = resolve_value(args.model, resolve_model_env, DEFAULT_MODEL)?;
    let language = resolve_value(args.language, resolve_language_env, DEFAULT_LANGUAGE)?;
    let max_seconds = resolve_value(
        args.max_seconds,
        resolve_max_seconds_env,
        DEFAULT_MAX_SECONDS,
    )?;
    let output = resolve_value(args.output, resolve_output_env, DEFAULT_OUTPUT)?;

    Ok(AppConfig {
        api_key,
        model,
        language,
        max_seconds,
        output,
    })
}

fn resolve_value<T, F>(cli_value: Option<T>, env_loader: F, default: T) -> Result<T, AppError>
where
    F: FnOnce() -> Result<Option<T>, AppError>,
{
    match cli_value {
        Some(value) => Ok(value),
        None => Ok(env_loader()?.unwrap_or(default)),
    }
}

fn resolve_api_key() -> Result<String, AppError> {
    match env::var("OPENAI_API_KEY") {
        Ok(value) if !value.trim().is_empty() => Ok(value),
        _ => Err(AppError::ApiKeyMissing),
    }
}

fn resolve_model_env() -> Result<Option<Model>, AppError> {
    resolve_optional_env(
        "VOICO_MODEL",
        parse_value_enum::<Model>,
        AppError::InvalidModel,
    )
}

fn resolve_language_env() -> Result<Option<Language>, AppError> {
    resolve_optional_env(
        "VOICO_LANGUAGE",
        parse_value_enum::<Language>,
        AppError::InvalidLanguage,
    )
}

fn resolve_max_seconds_env() -> Result<Option<u32>, AppError> {
    resolve_optional_env(
        "VOICO_MAX_SECONDS",
        parse_positive_u32,
        AppError::InvalidMaxSeconds,
    )
}

fn resolve_output_env() -> Result<Option<OutputTarget>, AppError> {
    resolve_optional_env(
        "VOICO_OUTPUT",
        parse_value_enum::<OutputTarget>,
        AppError::InvalidOutput,
    )
}

fn resolve_optional_env<T, F>(
    key: &str,
    parse: F,
    parse_error: AppError,
) -> Result<Option<T>, AppError>
where
    F: FnOnce(&str) -> Option<T>,
{
    let value = match env::var(key) {
        Ok(value) => value,
        Err(env::VarError::NotPresent) => return Ok(None),
        Err(env::VarError::NotUnicode(_)) => return Err(parse_error),
    };

    parse(value.trim()).ok_or(parse_error).map(Some)
}

fn parse_value_enum<T: ValueEnum>(value: &str) -> Option<T> {
    T::from_str(value, false).ok()
}

fn parse_positive_u32(value: &str) -> Option<u32> {
    value.parse::<u32>().ok().filter(|value| *value > 0)
}
