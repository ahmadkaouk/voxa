# voxactl

`voxactl` is a small CLI client for `voxa-daemon`.

It exists mainly for testing, debugging, and development. It speaks the same local IPC protocol as the menu bar app, which makes it useful for inspecting daemon state or exercising the API without using the UI.

## Common Commands

```bash
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

If you installed the workspace with `./scripts/install.sh`, you can run `voxactl ...` directly.

## Defaults

- `start` default origin: `manual`
- `stop` default reason: `manual`

## Allowed Values

- start origins: `manual`, `hotkey_toggle`, `hotkey_hold`
- stop reasons: `manual`, `hotkey_toggle`, `hotkey_hold_release`, `max_duration`
- config keys: `toggle_hotkey`, `hold_hotkey`, `model`, `output_mode`, `max_recording_seconds`
- api-key actions: `status`, `set <value>`

`events` subscribes to the daemon event stream, prints each event payload as JSON, and runs until interrupted.

## Socket

By default, `voxactl` connects to:

`~/Library/Application Support/voxa/run/daemon.sock`

To override the socket path:

```bash
VOXA_SOCKET=/tmp/voxa-test.sock cargo run -p voxactl -- status
```

## Troubleshooting

- `No such file or directory`: the daemon is not running or the socket path is wrong.
- `hello failed: Unsupported API version`: `voxactl` and the daemon were built from incompatible versions.
- `CONFIG_INVALID` or `CONFIG_HOTKEY_CONFLICT`: the config value is invalid or the selected hotkeys conflict.
- `Malformed request`: usually a local binary mismatch or protocol mismatch.
- `Failed to store API key`: keychain write failed, so retry from a logged-in user session or use `OPENAI_API_KEY`.
