# Voxa

Voxa is a macOS dictation app built around a menu bar client and a local daemon. You speak into the mic, Voxa sends the audio to OpenAI for transcription, and the result can go to the clipboard or directly into the active app.

The menu bar app is the main UX. `voxa-daemon` owns recording, transcription, config, and runtime state. `voxactl` is a small CLI for troubleshooting and development.

## Current Scope

- SwiftUI menu bar app with global hotkeys, transcript output, and daemon lifecycle controls
- Rust daemon with local IPC, event-driven state, persisted config, and idempotent start/stop behavior
- Keychain-first API key storage with `OPENAI_API_KEY` fallback
- Packaging script that builds a macOS app bundle and DMG

## Repository Layout

- `apps/voxa-menubar`: SwiftUI menu bar app
- `crates/voxa-daemon`: daemon process and runtime state authority
- `crates/voxactl`: optional CLI for health, config, and support workflows
- `crates/voxa-core`: shared domain, IPC, and infrastructure primitives
- `docs/`: architecture, IPC contract, and CLI notes

## Requirements

- macOS 13+
- Rust toolchain (stable)
- Xcode Command Line Tools / Swift 5.9+
- OpenAI API key

For DMG packaging, macOS tools `sips`, `iconutil`, and `hdiutil` must also be available.

## Quick Start

1. Install the Rust binaries:

```bash
./scripts/install.sh
```

2. Run the menu bar app:

```bash
cd apps/voxa-menubar
swift run voxa-menubar
```

3. On first launch:
- add your OpenAI API key from the menu bar UI
- allow microphone access when prompted
- grant Accessibility and Input Monitoring if you want global hotkeys or autopaste

The menu bar app installs or updates a per-user LaunchAgent for `voxa-daemon` and starts it automatically.

## Common Tasks

Check the workspace:

```bash
./scripts/check.sh
```

Run the Rust tests:

```bash
cargo test --workspace
```

Run the Swift tests:

```bash
swift test --package-path apps/voxa-menubar
```

Build a distributable app:

```bash
./scripts/package-macos.sh
```

Outputs:
- `dist/Voxa.app`
- `dist/Voxa.dmg`

The app bundle embeds `voxa-daemon` at `Voxa.app/Contents/Resources/bin/voxa-daemon`.

## `voxactl`

`voxactl` uses the same local IPC API as the menu bar app. Useful examples:

```bash
cargo run -p voxactl -- health
cargo run -p voxactl -- status
cargo run -p voxactl -- start manual
cargo run -p voxactl -- stop manual
cargo run -p voxactl -- config get
cargo run -p voxactl -- config set model gpt-4o-transcribe
cargo run -p voxactl -- api-key status
cargo run -p voxactl -- api-key set sk-your-key
cargo run -p voxactl -- events
```

If you installed with `./scripts/install.sh`, you can run `voxactl ...` directly.

## Runtime Paths

- IPC socket: `~/Library/Application Support/voxa/run/daemon.sock`
- Config file: `~/Library/Application Support/voxa/config.toml`
- LaunchAgent plist: `~/Library/LaunchAgents/com.voxa.daemon.plist`
- Daemon logs: `~/Library/Logs/voxa/daemon.out.log` and `~/Library/Logs/voxa/daemon.err.log`

## Config Defaults

Default values:
- `toggle_hotkey = "right_option"`
- `hold_hotkey = "fn"`
- `model = "gpt-4o-mini-transcribe"`
- `output_mode = "clipboard_autopaste"`
- `max_recording_seconds = 300`
- `api_key_source = "keychain"`

Accepted values:
- hotkeys: `right_option`, `fn`, `fn_space`, `cmd_space`
- model: `gpt-4o-mini-transcribe`, `gpt-4o-transcribe`
- output mode: `clipboard_autopaste`, `clipboard_only`, `none`

## Environment Overrides

- `VOXA_SOCKET`: override the daemon socket path for `voxa-daemon` and `voxactl`
- `VOXA_CONFIG_PATH`: override the daemon config path
- `VOXA_DAEMON_BIN`: override the daemon executable path used by the menu bar LaunchAgent install
- `VOXA_OPENAI_TRANSCRIPTIONS_URL`: override the OpenAI transcriptions endpoint for tests or mocks
- `OPENAI_API_KEY`: fallback key source and the source used when `api_key_source = "env"`

## Documentation

- `docs/architecture.md`
- `docs/ipc.md`
- `docs/voxactl.md`
