# voxactl

`voxactl` is a thin IPC client for controlling the daemon.

## Commands

```bash
cd next
cargo run -p voxactl -- health
cargo run -p voxactl -- status
cargo run -p voxactl -- start manual
cargo run -p voxactl -- stop manual
cargo run -p voxactl -- config get
cargo run -p voxactl -- config set model gpt-4o-transcribe
cargo run -p voxactl -- config set max_recording_seconds 120
cargo run -p voxactl -- api-key status
cargo run -p voxactl -- api-key set sk-your-key
cargo run -p voxactl -- events
```

Defaults:
- `start` default origin: `manual`
- `stop` default reason: `manual`

Allowed values:
- start origins: `manual`, `hotkey_toggle`, `hotkey_hold`
- stop reasons: `manual`, `hotkey_toggle`, `hotkey_hold_release`, `max_duration`
- config keys: `toggle_hotkey`, `hold_hotkey`, `model`, `output_mode`, `max_recording_seconds`
- api-key actions: `status`, `set <value>`

`events`:
- subscribes to daemon event stream
- prints each event payload as JSON
- runs until interrupted

## Socket

By default, `voxactl` connects to:

`~/Library/Application Support/voxa/run/daemon.sock`

To override:

```bash
VOXA_SOCKET=/tmp/voxa-test.sock cargo run -p voxactl -- status
```

## Troubleshooting

- `No such file or directory` when connecting:
  - Daemon is not running or socket path is wrong.
  - Start daemon first and check `VOXA_SOCKET` override.

- `hello failed: Unsupported API version`:
  - `voxactl` and daemon are running incompatible protocol versions.
  - Rebuild both from the same commit.

- `CONFIG_INVALID` / `CONFIG_HOTKEY_CONFLICT`:
  - Sent config value is invalid or hotkeys conflict.
  - Re-run with valid key/value pairs and distinct hotkeys.

- `Malformed request`:
  - Usually indicates protocol mismatch or a local binary mismatch.
  - Rebuild workspace and retry.

- `Failed to store API key`:
  - Keychain write failed (permissions or keychain unavailable).
  - Retry while logged in to the user session; if needed use `OPENAI_API_KEY` env fallback.
