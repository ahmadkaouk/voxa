use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};
use voico_core::ipc::{
    API_VERSION, ClientEnvelope, HelloRequest, RequestEnvelope, ServerEnvelope, StartOrigin,
    StopReason,
};

fn main() {
    if let Err(err) = run() {
        eprintln!("ERROR: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage();
        return Ok(());
    };

    if command == "help" || command == "--help" || command == "-h" {
        print_usage();
        return Ok(());
    }

    let socket_path = socket_path().map_err(|err| err.to_string())?;
    let mut client = IpcClient::connect(&socket_path).map_err(|err| err.to_string())?;

    match command.as_str() {
        "health" => {
            let result = client.request("health", json!({}))?;
            print_json(&result)?;
        }
        "status" => {
            let result = client.request("get_state", json!({}))?;
            print_json(&result)?;
        }
        "start" => {
            let origin = parse_start_origin(args.next().as_deref())?;
            let result = client.request("start_recording", json!({ "origin": origin }))?;
            print_json(&result)?;
        }
        "stop" => {
            let reason = parse_stop_reason(args.next().as_deref())?;
            let result = client.request("stop_recording", json!({ "reason": reason }))?;
            print_json(&result)?;
        }
        "config" => {
            let Some(action) = args.next() else {
                return Err("Missing config action. Expected 'get' or 'set'.".to_owned());
            };

            match action.as_str() {
                "get" => {
                    let result = client.request("get_config", json!({}))?;
                    print_json(&result)?;
                }
                "set" => {
                    let Some(key) = args.next() else {
                        return Err("Missing config key for 'config set'.".to_owned());
                    };
                    let Some(value) = args.next() else {
                        return Err("Missing config value for 'config set'.".to_owned());
                    };

                    let params = parse_config_set_params(&key, &value)?;
                    let result = client.request("set_config", params)?;
                    print_json(&result)?;
                }
                _ => {
                    return Err(format!(
                        "Unknown config action '{action}'. Expected 'get' or 'set'."
                    ));
                }
            }
        }
        "api-key" => {
            let Some(action) = args.next() else {
                return Err("Missing api-key action. Expected 'status' or 'set'.".to_owned());
            };

            match action.as_str() {
                "status" => {
                    let result = client.request("get_api_key_status", json!({}))?;
                    print_json(&result)?;
                }
                "set" => {
                    let Some(api_key) = args.next() else {
                        return Err("Missing API key for 'api-key set'.".to_owned());
                    };
                    let result = client.request(
                        "set_api_key",
                        json!({
                            "api_key": api_key
                        }),
                    )?;
                    print_json(&result)?;
                }
                _ => {
                    return Err(format!(
                        "Unknown api-key action '{action}'. Expected 'status' or 'set'."
                    ));
                }
            }
        }
        "events" => {
            let _ = client.request("subscribe", json!({}))?;
            loop {
                let envelope = client.read()?;
                if let ServerEnvelope::Event(event) = envelope {
                    print_json(&json!(event))?;
                }
            }
        }
        _ => {
            return Err(format!(
                "Unknown command '{command}'. Run 'voicoctl help' for usage."
            ));
        }
    }

    Ok(())
}

fn print_usage() {
    println!("voicoctl v{}", voico_core::version());
    println!("Usage:");
    println!("  voicoctl health");
    println!("  voicoctl status");
    println!("  voicoctl start [manual|hotkey_toggle|hotkey_hold]");
    println!("  voicoctl stop [manual|hotkey_toggle|hotkey_hold_release|max_duration]");
    println!("  voicoctl config get");
    println!("  voicoctl config set <key> <value>");
    println!("  voicoctl api-key status");
    println!("  voicoctl api-key set <value>");
    println!("  voicoctl events");
    println!("    keys: toggle_hotkey, hold_hotkey, model, output_mode, max_recording_seconds");
    println!("\nEnvironment:");
    println!("  VOICO_SOCKET   Override daemon socket path");
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VOICO_SOCKET") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("HOME is not set"))?;

    Ok(home.join("Library/Application Support/voico-v2/run/daemon.sock"))
}

fn parse_start_origin(value: Option<&str>) -> Result<StartOrigin, String> {
    match value.unwrap_or("manual") {
        "manual" => Ok(StartOrigin::Manual),
        "hotkey_toggle" => Ok(StartOrigin::HotkeyToggle),
        "hotkey_hold" => Ok(StartOrigin::HotkeyHold),
        other => Err(format!(
            "Invalid start origin '{other}'. Expected manual, hotkey_toggle, or hotkey_hold."
        )),
    }
}

fn parse_stop_reason(value: Option<&str>) -> Result<StopReason, String> {
    match value.unwrap_or("manual") {
        "manual" => Ok(StopReason::Manual),
        "hotkey_toggle" => Ok(StopReason::HotkeyToggle),
        "hotkey_hold_release" => Ok(StopReason::HotkeyHoldRelease),
        "max_duration" => Ok(StopReason::MaxDuration),
        other => Err(format!(
            "Invalid stop reason '{other}'. Expected manual, hotkey_toggle, hotkey_hold_release, or max_duration."
        )),
    }
}

fn parse_config_set_params(key: &str, value: &str) -> Result<Value, String> {
    let mut params = Map::new();
    match key {
        "toggle_hotkey" | "hold_hotkey" | "model" | "output_mode" => {
            params.insert(key.to_owned(), Value::String(value.to_owned()));
        }
        "max_recording_seconds" => {
            let parsed = value
                .parse::<u64>()
                .map_err(|_| "max_recording_seconds must be a positive integer".to_owned())?;
            params.insert(key.to_owned(), json!(parsed));
        }
        _ => {
            return Err(format!(
                "Invalid config key '{key}'. Expected toggle_hotkey, hold_hotkey, model, output_mode, or max_recording_seconds."
            ));
        }
    }

    Ok(Value::Object(params))
}

fn print_json(value: &Value) -> Result<(), String> {
    let formatted = serde_json::to_string_pretty(value).map_err(|err| err.to_string())?;
    println!("{formatted}");
    Ok(())
}

struct IpcClient {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl IpcClient {
    fn connect(socket_path: &PathBuf) -> io::Result<Self> {
        let mut stream = UnixStream::connect(socket_path)?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;

        let mut reader = BufReader::new(stream.try_clone()?);

        let hello = ClientEnvelope::Hello(HelloRequest {
            api_version: API_VERSION.to_owned(),
            client: Some("voicoctl".to_owned()),
            client_version: Some(voico_core::version().to_owned()),
        });
        write_envelope(&mut stream, &hello)?;

        let response = read_server_envelope(&mut reader)?;
        match response {
            ServerEnvelope::HelloOk { .. } => Ok(Self {
                stream,
                reader,
                next_id: 1,
            }),
            ServerEnvelope::HelloError { error } => Err(io::Error::other(format!(
                "hello failed: {} ({})",
                error.message, error.code
            ))),
            other => Err(io::Error::other(format!(
                "unexpected handshake response: {other:?}"
            ))),
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let request = ClientEnvelope::Request(RequestEnvelope {
            id: self.next_id.to_string(),
            method: method.to_owned(),
            params,
        });
        self.next_id += 1;

        write_envelope(&mut self.stream, &request).map_err(|err| err.to_string())?;

        let envelope = self.read()?;
        match envelope {
            ServerEnvelope::Response(response) if response.ok => response
                .result
                .ok_or_else(|| "response is missing result payload".to_owned()),
            ServerEnvelope::Response(response) => {
                let error = response
                    .error
                    .ok_or_else(|| "response failed without error payload".to_owned())?;
                Err(format!("{} ({})", error.message, error.code))
            }
            other => Err(format!("unexpected envelope: {other:?}")),
        }
    }

    fn read(&mut self) -> Result<ServerEnvelope, String> {
        read_server_envelope(&mut self.reader).map_err(|err| err.to_string())
    }
}

fn write_envelope(stream: &mut UnixStream, envelope: &ClientEnvelope) -> io::Result<()> {
    let serialized = serde_json::to_string(envelope)
        .map_err(|_| io::Error::other("failed to serialize request"))?;
    stream.write_all(serialized.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
}

fn read_server_envelope(reader: &mut BufReader<UnixStream>) -> io::Result<ServerEnvelope> {
    let mut line = String::new();
    let bytes = reader.read_line(&mut line)?;
    if bytes == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "daemon closed connection",
        ));
    }

    serde_json::from_str(line.trim())
        .map_err(|_| io::Error::other("failed to decode daemon response"))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{parse_config_set_params, parse_start_origin, parse_stop_reason};
    use voico_core::ipc::{StartOrigin, StopReason};

    #[test]
    fn parse_start_origin_defaults_to_manual() {
        assert_eq!(parse_start_origin(None), Ok(StartOrigin::Manual));
    }

    #[test]
    fn parse_start_origin_supports_all_values() {
        assert_eq!(parse_start_origin(Some("manual")), Ok(StartOrigin::Manual));
        assert_eq!(
            parse_start_origin(Some("hotkey_toggle")),
            Ok(StartOrigin::HotkeyToggle)
        );
        assert_eq!(
            parse_start_origin(Some("hotkey_hold")),
            Ok(StartOrigin::HotkeyHold)
        );
    }

    #[test]
    fn parse_stop_reason_defaults_to_manual() {
        assert_eq!(parse_stop_reason(None), Ok(StopReason::Manual));
    }

    #[test]
    fn parse_stop_reason_supports_all_values() {
        assert_eq!(parse_stop_reason(Some("manual")), Ok(StopReason::Manual));
        assert_eq!(
            parse_stop_reason(Some("hotkey_toggle")),
            Ok(StopReason::HotkeyToggle)
        );
        assert_eq!(
            parse_stop_reason(Some("hotkey_hold_release")),
            Ok(StopReason::HotkeyHoldRelease)
        );
        assert_eq!(
            parse_stop_reason(Some("max_duration")),
            Ok(StopReason::MaxDuration)
        );
    }

    #[test]
    fn parse_config_set_params_supports_string_fields() {
        let result = parse_config_set_params("model", "gpt-4o-mini-transcribe");
        assert_eq!(
            result,
            Ok(json!({
                "model": "gpt-4o-mini-transcribe"
            }))
        );
    }

    #[test]
    fn parse_config_set_params_supports_numeric_fields() {
        let result = parse_config_set_params("max_recording_seconds", "120");
        assert_eq!(
            result,
            Ok(json!({
                "max_recording_seconds": 120
            }))
        );
    }
}
