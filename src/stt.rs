use std::time::Duration;

use reqwest::StatusCode;
use reqwest::blocking::{Client, multipart};
use serde::Deserialize;

use crate::cli::{Language, Model};
use crate::error::AppError;

const TRANSCRIPTIONS_URL: &str = "https://api.openai.com/v1/audio/transcriptions";
const REQUEST_TIMEOUT_SECS: u64 = 60;

#[derive(Debug, Deserialize)]
struct TranscriptionResponse {
    text: String,
}

pub fn transcribe(
    api_key: &str,
    model: Model,
    language: Language,
    wav_bytes: &[u8],
) -> Result<String, AppError> {
    transcribe_with_url(api_key, model, language, wav_bytes, TRANSCRIPTIONS_URL)
}

fn transcribe_with_url(
    api_key: &str,
    model: Model,
    language: Language,
    wav_bytes: &[u8],
    url: &str,
) -> Result<String, AppError> {
    let client = Client::builder()
        .timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS))
        .build()
        .map_err(|_| AppError::ApiNetworkFailed)?;

    let mut form = multipart::Form::new()
        .text("model", model_value(model).to_owned())
        .part(
            "file",
            multipart::Part::bytes(wav_bytes.to_vec())
                .file_name("audio.wav")
                .mime_str("audio/wav")
                .map_err(|_| AppError::ApiRequestFailed)?,
        );

    if let Some(value) = language_value(language) {
        form = form.text("language", value.to_owned());
    }

    let response = client
        .post(url)
        .bearer_auth(api_key)
        .multipart(form)
        .send()
        .map_err(|_| AppError::ApiNetworkFailed)?;

    if !response.status().is_success() {
        return Err(map_status_error(response.status()));
    }

    let parsed: TranscriptionResponse =
        response.json().map_err(|_| AppError::ApiResponseInvalid)?;
    let transcript = parsed.text.trim();

    if transcript.is_empty() {
        return Err(AppError::ApiEmptyTranscript);
    }

    Ok(transcript.to_owned())
}

fn model_value(model: Model) -> &'static str {
    match model {
        Model::Gpt4oMiniTranscribe => "gpt-4o-mini-transcribe",
        Model::Gpt4oTranscribe => "gpt-4o-transcribe",
    }
}

fn language_value(language: Language) -> Option<&'static str> {
    match language {
        Language::Auto => None,
        Language::En => Some("en"),
        Language::Fr => Some("fr"),
    }
}

fn map_status_error(status: StatusCode) -> AppError {
    match status.as_u16() {
        401 | 403 => AppError::ApiAuthFailed,
        429 => AppError::ApiRateLimited,
        _ => AppError::ApiRequestFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::{language_value, transcribe_with_url};
    use crate::cli::{Language, Model};
    use crate::error::AppError;
    use mockito::Matcher;

    fn wav_bytes() -> Vec<u8> {
        vec![
            82, 73, 70, 70, 38, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0, 1, 0, 1,
            0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0, 100, 97, 116, 97, 2, 0, 0, 0, 0, 0,
        ]
    }

    #[test]
    fn language_value_maps_expected_codes() {
        assert_eq!(language_value(Language::Auto), None);
        assert_eq!(language_value(Language::En), Some("en"));
        assert_eq!(language_value(Language::Fr), Some("fr"));
    }

    #[test]
    fn transcribe_returns_text_on_success() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .match_header("authorization", "Bearer test-key")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"text":"hello world"}"#)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        )
        .expect("expected success");

        mock.assert();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn transcribe_rejects_empty_text() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"text":"  "}"#)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        );

        assert!(matches!(result, Err(AppError::ApiEmptyTranscript)));
    }

    #[test]
    fn transcribe_maps_auth_error() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(401)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        );

        assert!(matches!(result, Err(AppError::ApiAuthFailed)));
    }

    #[test]
    fn transcribe_maps_rate_limit_error() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(429)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        );

        assert!(matches!(result, Err(AppError::ApiRateLimited)));
    }

    #[test]
    fn transcribe_maps_request_error() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(500)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        );

        assert!(matches!(result, Err(AppError::ApiRequestFailed)));
    }

    #[test]
    fn transcribe_maps_response_invalid_error() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"unexpected":"field"}"#)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        );

        assert!(matches!(result, Err(AppError::ApiResponseInvalid)));
    }

    #[test]
    fn transcribe_maps_network_error() {
        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Auto,
            &wav_bytes(),
            "http://127.0.0.1:9/v1/audio/transcriptions",
        );

        assert!(matches!(result, Err(AppError::ApiNetworkFailed)));
    }

    #[test]
    fn transcribe_includes_language_field_for_explicit_language() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/v1/audio/transcriptions")
            .match_body(Matcher::Regex(r#"name=\"language\""#.to_string()))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"text":"bonjour"}"#)
            .create();

        let result = transcribe_with_url(
            "test-key",
            Model::Gpt4oMiniTranscribe,
            Language::Fr,
            &wav_bytes(),
            &(server.url() + "/v1/audio/transcriptions"),
        )
        .expect("expected success");

        mock.assert();
        assert_eq!(result, "bonjour");
    }
}
