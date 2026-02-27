# voicoctl

`voicoctl` is a thin IPC client for controlling the v2 daemon.

## Commands

```bash
cd next
cargo run -p voicoctl -- health
cargo run -p voicoctl -- status
cargo run -p voicoctl -- start manual
cargo run -p voicoctl -- stop manual
cargo run -p voicoctl -- config get
cargo run -p voicoctl -- config set model gpt-4o-transcribe
cargo run -p voicoctl -- config set max_recording_seconds 120
```

Defaults:
- `start` default origin: `manual`
- `stop` default reason: `manual`

Allowed values:
- start origins: `manual`, `hotkey_toggle`, `hotkey_hold`
- stop reasons: `manual`, `hotkey_toggle`, `hotkey_hold_release`, `max_duration`
- config keys: `toggle_hotkey`, `hold_hotkey`, `model`, `output_mode`, `max_recording_seconds`

## Socket

By default, `voicoctl` connects to:

`~/Library/Application Support/voico-v2/run/daemon.sock`

To override:

```bash
VOICO_SOCKET=/tmp/voico-test.sock cargo run -p voicoctl -- status
```

## Troubleshooting

- `No such file or directory` when connecting:
  - Daemon is not running or socket path is wrong.
  - Start daemon first and check `VOICO_SOCKET` override.

- `hello failed: Unsupported API version`:
  - `voicoctl` and daemon are running incompatible protocol versions.
  - Rebuild both from the same commit.

- `CONFIG_INVALID` / `CONFIG_HOTKEY_CONFLICT`:
  - Sent config value is invalid or hotkeys conflict.
  - Re-run with valid key/value pairs and distinct hotkeys.

- `Malformed request`:
  - Usually indicates protocol mismatch or a local binary mismatch.
  - Rebuild workspace and retry.
