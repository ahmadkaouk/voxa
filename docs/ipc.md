# Voxa IPC Protocol (v1)

## Scope
This document defines local IPC between `voxa-daemon` and clients (`voxa-menubar`, optional `voxactl`).

Goals:
- One protocol for all clients.
- Deterministic state sync.
- Backward-compatible evolution.

## Transport
- Unix domain socket.
- Default path: `~/Library/Application Support/voxa/run/daemon.sock`.
- The default runtime directory is restricted to `0700`, and the socket to `0600`.
- With a custom `VOXA_SOCKET`, use a private parent directory. Existing custom
  directory permissions are preserved; newly created directories use `0700`.
- Startup rejects files and symlinks at the socket path and only removes stale sockets.

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
{"type":"hello","api_version":"1.0","client":"voxa-menubar","client_version":"0.1.0"}
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

The daemon acknowledges a new recording and emits `recording_started` after
microphone initialization succeeds. Initialization has a two-second timeout;
startup or subsequent capture failures are reported as `AUDIO_CAPTURE_FAILED`.
Capture failures also publish the updated error state without requiring a stop request.

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
{"accepted": true, "text":"hello world"}
```

Notes:
- When no active recording exists, response remains idempotent with `{"accepted": true}`.
- Output side effects (clipboard/autopaste) are client responsibilities in the menu bar app.

### `cancel_recording`
Request:
```json
{"type":"request","id":"cancel-1","method":"cancel_recording","params":{}}
```

Success result:
```json
{"accepted": true, "cancelled": true}
```

Notes:
- Stops microphone capture and discards its audio, then transitions directly to `idle`.
- Emits `recording_cancelled` with the cancelled `session_id`, followed by `state_changed`.
- Does not transcribe, emit `transcription_ready`, or perform output.
- Outside `recording`, returns `{"accepted": true, "cancelled": false}` without changing state or emitting events. An in-flight transcription continues normally.
- A concurrent stop and cancel are serialized: whichever transitions out of `recording` first wins. A later cancel cannot undo transcription that has already started.
- A capture-stop failure returns the recording error and transitions to `error` without transcription.

### `get_config`
Request:
```json
{"type":"request","id":"5","method":"get_config","params":{}}
```

Response result:
```json
{
  "toggle_hotkey": "option_f",
  "hold_hotkey": "option_g",
  "model": "gpt-transcribe",
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
    "toggle_hotkey":"option_f",
    "hold_hotkey":"option_g",
    "model":"gpt-transcribe",
    "output_mode":"clipboard_autopaste",
    "max_recording_seconds":300
  }
}
```

Rules:
- Partial updates are allowed.
- Validation runs before commit.
- Commit is atomic.
- Updates are rejected with `CONFIG_BUSY` unless the daemon state is `idle`.
- `max_recording_seconds` must be between `1` and `3600`.

Success result:
```json
{"revision": 4}
```

### `get_api_key_status`
Request:
```json
{"type":"request","id":"8","method":"get_api_key_status","params":{}}
```

Response result:
```json
{
  "source": "keychain",
  "is_set": true
}
```

### `set_api_key`
Request:
```json
{
  "type":"request",
  "id":"9",
  "method":"set_api_key",
  "params":{"api_key":"sk-..."}
}
```

Success result:
```json
{"stored":true,"source":"keychain"}
```

### `subscribe`
Request:
```json
{"type":"request","id":"7","method":"subscribe","params":{"from_seq":0}}
```

Params:
- `from_seq` optional.
- Omitted or `0` means subscribe from now; buffered history is not replayed.
- If `from_seq > 0`, the daemon replays available buffered events whose `seq` is
  greater than `from_seq`, in increasing order.
- A `from_seq` above the daemon's current sequence is treated as a prior daemon
  epoch and replays the available new-epoch window.
- The subscribe response is always sent before any replayed or subsequent live event.
- Repeating `subscribe` on the same connection replaces its subscription using
  the new cursor, so future live events are delivered once. Events already queued
  for the previous subscription may arrive before the new response.
- Replay is best effort: the daemon keeps only the latest 32 events in memory and
  never persists them. If `from_seq` predates that window, clients must use
  `get_state` to reconcile the missing state.

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

### `audio_level`
```json
{
  "type":"event",
  "name":"audio_level",
  "seq":45,
  "data":{"session_id":"s-abc","level":0.42}
}
```

### `recording_stopped`
```json
{
  "type":"event",
  "name":"recording_stopped",
  "seq":46,
  "data":{"session_id":"s-abc","reason":"hotkey_hold_release"}
}
```

### `recording_cancelled`
```json
{
  "type":"event",
  "name":"recording_cancelled",
  "seq":46,
  "data":{"session_id":"s-abc"}
}
```

Emitted instead of `recording_stopped` when captured audio is discarded. The next
state is `idle`; no transcription or output events are emitted for that session.

### `transcribing_started`
```json
{
  "type":"event",
  "name":"transcribing_started",
  "seq":47,
  "data":{"session_id":"s-abc"}
}
```

### `transcription_ready`
```json
{
  "type":"event",
  "name":"transcription_ready",
  "seq":48,
  "data":{"session_id":"s-abc","text":"hello world","text_length":11}
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
- `CONFIG_INVALID`
- `CONFIG_HOTKEY_CONFLICT`
- `CONFIG_BUSY`
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
- Request timeout recommendation: 5 seconds for fast control methods such as `health`,
  `get_state`, `get_config`, `start_recording`, and `cancel_recording`.
- `stop_recording` should use a longer client timeout because the response includes the
  transcription result and may remain in flight until transcription completes.
- Client reconnect backoff: 200ms, 500ms, 1s, 2s, max 5s.
- `start_recording`, `stop_recording`, and `cancel_recording` are idempotent from client perspective.

## Backward Compatibility Rules
- Do not remove or rename existing fields in v1.
- Additive fields/events are allowed.
- Breaking changes require `api_version` bump.

## Open Questions
- Should `set_config` support optimistic concurrency via `expected_revision`?
