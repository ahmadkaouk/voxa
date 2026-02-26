use std::env;

use clap::ValueEnum;

use crate::cli::Model;
use crate::error::AppError;

const DEFAULT_MODEL: Model = Model::Gpt4oMiniTranscribe;

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub api_key: String,
    pub model: Model,
}

pub fn load_defaults() -> Result<AppConfig, AppError> {
    let _ = dotenvy::dotenv();

    let api_key = resolve_api_key()?;
    let model = resolve_model_env()?.unwrap_or(DEFAULT_MODEL);

    Ok(AppConfig { api_key, model })
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
