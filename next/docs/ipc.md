# Voico v2 IPC Protocol (v0 - MVP)

## Scope
Minimal local IPC between `voico-daemon` and clients (`voico-menubar-v2`, optional `voicoctl`).

Goals:
- Drive recording from one daemon authority.
- Keep UI state synchronized without log parsing.
- Keep protocol small and easy to implement.

## Transport
- Unix domain socket.
- Path: `~/Library/Application Support/voico-v2/run/daemon.sock`.
- Newline-delimited JSON (one JSON object per line).

## Handshake
Client sends:

```json
{"type":"hello","api_version":"0"}
```

Daemon responds:

```json
{"type":"hello_ok","api_version":"0"}
```

Or:

```json
{"type":"hello_error","error":{"code":"API_VERSION_UNSUPPORTED","message":"Unsupported API version"}}
```

## Envelope
Request:

```json
{"type":"request","id":"1","method":"get_state","params":{}}
```

Response success:

```json
{"type":"response","id":"1","ok":true,"result":{}}
```

Response error:

```json
{"type":"response","id":"1","ok":false,"error":{"code":"INVALID_REQUEST","message":"Invalid request"}}
```

Event:

```json
{"type":"event","name":"state_changed","data":{}}
```

## Methods (v0)
### `get_state`
Request:

```json
{"type":"request","id":"1","method":"get_state","params":{}}
```

Response:

```json
{
  "state":"idle",
  "is_recording":false,
  "last_error":null
}
```

`state` values:
- `idle`
- `recording`
- `transcribing`
- `error`

### `start_recording`
Request:

```json
{"type":"request","id":"2","method":"start_recording","params":{}}
```

Response:

```json
{"accepted":true}
```

### `stop_recording`
Request:

```json
{"type":"request","id":"3","method":"stop_recording","params":{}}
```

Response:

```json
{"accepted":true}
```

### `subscribe`
Request:

```json
{"type":"request","id":"4","method":"subscribe","params":{}}
```

Response:

```json
{"subscribed":true}
```

## Events (v0)
### `state_changed`

```json
{
  "type":"event",
  "name":"state_changed",
  "data":{
    "state":"recording",
    "is_recording":true
  }
}
```

### `error`

```json
{
  "type":"event",
  "name":"error",
  "data":{
    "code":"API_NETWORK_FAILED",
    "message":"Network error during transcription."
  }
}
```

## Error Codes (v0)
Protocol:
- `API_VERSION_UNSUPPORTED`
- `INVALID_REQUEST`
- `UNKNOWN_METHOD`
- `INTERNAL_ERROR`

Runtime:
- `RECORDING_ALREADY_ACTIVE`
- `RECORDING_NOT_ACTIVE`
- `AUDIO_CAPTURE_FAILED`
- `API_NETWORK_FAILED`
- `API_REQUEST_FAILED`
- `OUTPUT_FAILED`

## Reconnect Rule
After reconnect:
1. `hello`
2. `get_state`
3. `subscribe`

Client must treat `get_state` as source of truth.

## Versioning Rule
- Additive changes allowed in `v0` only if older clients can ignore them.
- Breaking changes require a new `api_version`.
