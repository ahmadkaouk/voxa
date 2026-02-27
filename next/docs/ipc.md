# Voico v2 IPC Protocol (v1)

## Scope
This document defines local IPC between `voico-daemon` and clients (`voico-menubar-v2`, optional `voicoctl`).

Goals:
- One protocol for all clients.
- Deterministic state sync.
- Backward-compatible evolution.

## Transport
- Unix domain socket.
- Default path: `~/Library/Application Support/voico-v2/run/daemon.sock`.
- Socket permissions: user-only.

## Framing
- Newline-delimited JSON (NDJSON).
- Each line is one JSON object.

## Connection Modes
Two connection modes are supported:
1. Request/response mode (short-lived or persistent): send requests, receive responses.
2. Event subscription mode (persistent): subscribe and receive daemon events.

A single connection may use both modes.

## Handshake
Client should send this first:

```json
{"type":"hello","api_version":"1.0","client":"voico-menubar-v2","client_version":"0.1.0"}
```

Daemon replies:

```json
{"type":"hello_ok","api_version":"1.0","daemon_version":"0.1.0"}
```

If unsupported version:

```json
{"type":"hello_error","error":{"code":"API_VERSION_UNSUPPORTED","message":"Unsupported API version"}}
```

## Envelope
### Request
```json
{
  "type": "request",
  "id": "req-123",
  "method": "get_state",
  "params": {}
}
```

### Response Success
```json
{
  "type": "response",
  "id": "req-123",
  "ok": true,
  "result": {}
}
```

### Response Error
```json
{
  "type": "response",
  "id": "req-123",
  "ok": false,
  "error": {
    "code": "INVALID_REQUEST",
    "message": "Missing required field: method",
    "details": null
  }
}
```

### Event
```json
{
  "type": "event",
  "name": "state_changed",
  "seq": 42,
  "data": {}
}
```

## Methods (v1)
### `health`
Request:
```json
{"type":"request","id":"1","method":"health","params":{}}
```

Response result:
```json
{
  "status": "ok",
  "uptime_ms": 12345
}
```

### `get_state`
Request:
```json
{"type":"request","id":"2","method":"get_state","params":{}}
```

Response result:
```json
{
  "state": "idle",
  "session": null,
  "recording_origin": null,
  "is_busy": false,
  "last_error": null,
  "config_revision": 3,
  "event_seq": 42
}
```

`state` values:
- `idle`
- `recording`
- `transcribing`
- `outputting`
- `error`

### `start_recording`
Request:
```json
{
  "type":"request",
  "id":"3",
  "method":"start_recording",
  "params":{"origin":"manual"}
}
```

`origin` values:
- `manual`
- `hotkey_toggle`
- `hotkey_hold`

Success result:
```json
{"accepted": true}
```

### `stop_recording`
Request:
```json
{
  "type":"request",
  "id":"4",
  "method":"stop_recording",
  "params":{"reason":"manual"}
}
```

`reason` values:
- `manual`
- `hotkey_toggle`
- `hotkey_hold_release`
- `max_duration`

Success result:
```json
{"accepted": true}
```

### `get_config`
Request:
```json
{"type":"request","id":"5","method":"get_config","params":{}}
```

Response result:
```json
{
  "toggle_hotkey": "right_option",
  "hold_hotkey": "fn",
  "model": "gpt-4o-mini-transcribe",
  "output_mode": "clipboard_autopaste",
  "max_recording_seconds": 300,
  "api_key_source": "keychain",
  "revision": 3
}
```

### `set_config`
Request:
```json
{
  "type":"request",
  "id":"6",
  "method":"set_config",
  "params":{
    "toggle_hotkey":"right_option",
    "hold_hotkey":"fn",
    "model":"gpt-4o-mini-transcribe",
    "output_mode":"clipboard_autopaste",
    "max_recording_seconds":300
  }
}
```

Rules:
- Partial updates are allowed.
- Validation runs before commit.
- Commit is atomic.

Success result:
```json
{"revision": 4}
```

### `subscribe`
Request:
```json
{"type":"request","id":"7","method":"subscribe","params":{"from_seq":0}}
```

Params:
- `from_seq` optional.
- `0` means subscribe from now.
- If `from_seq > 0`, daemon may replay buffered events if available.

Success result:
```json
{"subscribed": true, "current_seq": 42}
```

## Events (v1)
All events include `seq` and are emitted in strict increasing order per daemon process.

### `state_changed`
```json
{
  "type":"event",
  "name":"state_changed",
  "seq":43,
  "data":{
    "state":"recording",
    "session_id":"s-abc",
    "origin":"hotkey_hold"
  }
}
```

### `recording_started`
```json
{
  "type":"event",
  "name":"recording_started",
  "seq":44,
  "data":{"session_id":"s-abc","origin":"hotkey_hold"}
}
```

### `recording_stopped`
```json
{
  "type":"event",
  "name":"recording_stopped",
  "seq":45,
  "data":{"session_id":"s-abc","reason":"hotkey_hold_release"}
}
```

### `transcribing_started`
```json
{
  "type":"event",
  "name":"transcribing_started",
  "seq":46,
  "data":{"session_id":"s-abc"}
}
```

### `transcription_ready`
```json
{
  "type":"event",
  "name":"transcription_ready",
  "seq":47,
  "data":{"session_id":"s-abc","text_length":132}
}
```

### `output_done`
```json
{
  "type":"event",
  "name":"output_done",
  "seq":48,
  "data":{"session_id":"s-abc","clipboard":true,"autopaste":true}
}
```

### `warning`
```json
{
  "type":"event",
  "name":"warning",
  "seq":49,
  "data":{"code":"AUDIO_MAX_DURATION_REACHED","message":"Recording reached max duration."}
}
```

### `error`
```json
{
  "type":"event",
  "name":"error",
  "seq":50,
  "data":{"code":"API_NETWORK_FAILED","message":"Network error during transcription."}
}
```

## Error Codes (v1)
Protocol errors:
- `API_VERSION_UNSUPPORTED`
- `INVALID_REQUEST`
- `UNKNOWN_METHOD`
- `INVALID_PARAMS`
- `INTERNAL_ERROR`

Domain/runtime errors:
- `INVALID_STATE_TRANSITION`
- `RECORDING_ALREADY_ACTIVE`
- `RECORDING_NOT_ACTIVE`
- `CONFIG_INVALID`
- `CONFIG_HOTKEY_CONFLICT`
- `AUDIO_DEVICE_UNAVAILABLE`
- `AUDIO_PERMISSION_DENIED`
- `AUDIO_CAPTURE_FAILED`
- `AUDIO_EMPTY_BUFFER`
- `API_AUTH_FAILED`
- `API_RATE_LIMITED`
- `API_REQUEST_FAILED`
- `API_NETWORK_FAILED`
- `API_RESPONSE_INVALID`
- `API_EMPTY_TRANSCRIPT`
- `OUTPUT_CLIPBOARD_FAILED`
- `OUTPUT_AUTOPASTE_FAILED`

## Ordering and Consistency
- Daemon is the single state authority.
- Clients must treat `get_state` as the source of truth after reconnect.
- `seq` is monotonically increasing for event ordering.
- On reconnect, client should:
  1. reconnect
  2. `hello`
  3. `get_state`
  4. `subscribe` (with last seen `seq` when supported)

## Timeouts and Retries
- Request timeout recommendation: 5 seconds for control methods.
- Client reconnect backoff: 200ms, 500ms, 1s, 2s, max 5s.
- `start_recording` and `stop_recording` are idempotent from client perspective.

## Backward Compatibility Rules
- Do not remove or rename existing fields in v1.
- Additive fields/events are allowed.
- Breaking changes require `api_version` bump.

## Open Questions
- Should `transcription_ready` optionally include full text for trusted local clients?
- How many events should daemon buffer for replay on `from_seq` subscribe?
- Should `set_config` support optimistic concurrency via `expected_revision`?
