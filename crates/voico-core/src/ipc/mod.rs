use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const API_VERSION: &str = "1.0";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum ClientEnvelope {
    #[serde(rename = "hello")]
    Hello(HelloRequest),
    #[serde(rename = "request")]
    Request(RequestEnvelope),
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct HelloRequest {
    pub api_version: String,
    #[serde(default)]
    pub client: Option<String>,
    #[serde(default)]
    pub client_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct RequestEnvelope {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum ServerEnvelope {
    #[serde(rename = "hello_ok")]
    HelloOk {
        api_version: String,
        daemon_version: String,
    },
    #[serde(rename = "hello_error")]
    HelloError { error: ErrorPayload },
    #[serde(rename = "response")]
    Response(ResponseEnvelope),
    #[serde(rename = "event")]
    Event(EventEnvelope),
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ResponseEnvelope {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorPayload>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct EventEnvelope {
    pub name: String,
    pub seq: u64,
    pub data: Value,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ErrorPayload {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum IpcRuntimeState {
    Idle,
    Recording,
    Transcribing,
    Outputting,
    Error,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum StartOrigin {
    Manual,
    HotkeyToggle,
    HotkeyHold,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    Manual,
    HotkeyToggle,
    HotkeyHoldRelease,
    MaxDuration,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct StartRecordingParams {
    #[serde(default)]
    pub origin: Option<StartOrigin>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct StopRecordingParams {
    #[serde(default)]
    pub reason: Option<StopReason>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SubscribeParams {
    #[serde(default)]
    pub from_seq: Option<u64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SetApiKeyParams {
    pub api_key: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ApiKeyStatusResult {
    pub source: String,
    pub is_set: bool,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct HealthResult {
    pub status: String,
    pub uptime_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct StateResult {
    pub state: IpcRuntimeState,
    pub session: Option<String>,
    pub recording_origin: Option<StartOrigin>,
    pub is_busy: bool,
    pub last_error: Option<String>,
    pub config_revision: u64,
    pub event_seq: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ConfigResult {
    pub toggle_hotkey: String,
    pub hold_hotkey: String,
    pub model: String,
    pub output_mode: String,
    pub max_recording_seconds: u64,
    pub api_key_source: String,
    pub revision: u64,
}

impl RequestEnvelope {
    pub fn parse_params<T>(&self) -> Result<T, ErrorPayload>
    where
        T: for<'de> Deserialize<'de>,
    {
        serde_json::from_value(self.params.clone()).map_err(|_| ErrorPayload {
            code: "INVALID_PARAMS".to_owned(),
            message: "Invalid request params".to_owned(),
            details: None,
        })
    }
}

impl ResponseEnvelope {
    pub fn ok(id: &str, result: Value) -> Self {
        Self {
            id: id.to_owned(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: &str, code: &str, message: &str) -> Self {
        Self {
            id: id.to_owned(),
            ok: false,
            result: None,
            error: Some(ErrorPayload {
                code: code.to_owned(),
                message: message.to_owned(),
                details: None,
            }),
        }
    }
}
