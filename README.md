# Voxa

Voxa is a local macOS dictation app with:
- a Swift menu bar client (`voxa-menubar`)
- a Rust daemon runtime (`voxa-daemon`)
- an optional IPC troubleshooting CLI (`voxactl`)

## Current Status

Implemented today:
- Daemon-first runtime over local IPC (no log parsing for state)
- Core start/stop/transcribe flow with idempotent control semantics
- Config read/update with validation and persisted revisions
- API key status/set endpoints with Keychain-first storage
- Menu bar app with global hotkeys, transcript output, and daemon lifecycle controls
- Packaging script that produces a macOS app bundle and DMG

## Repository Layout

- `apps/voxa-menubar`: SwiftUI menu bar app (primary UX)
- `crates/voxa-daemon`: daemon process (recording/transcription state authority)
- `crates/voxactl`: thin IPC client for support/dev workflows
- `crates/voxa-core`: shared domain/app/infra/IPC primitives
- `docs/`: architecture, IPC contract, and supporting notes

## Requirements

- macOS 13+
- Rust toolchain (stable)
- Xcode Command Line Tools / Swift 5.9+

For DMG packaging, macOS tools `sips`, `iconutil`, and `hdiutil` are also required.

## Quick Start (Dev)

1. Install Rust binaries:

```bash
./scripts/install.sh
```

2. Run the menu bar app:

```bash
cd apps/voxa-menubar
swift run voxa-menubar
```

3. On first run:
- Add your OpenAI API key from the menu bar UI.
- Grant Accessibility + Input Monitoring if you want global hotkeys/autopaste.

The menu bar app auto-installs/updates a per-user LaunchAgent and starts `voxa-daemon`.

## Build Distributable App

```bash
./scripts/package-macos.sh
```

Outputs:
- `dist/Voxa.app`
- `dist/Voxa.dmg`

The app bundle embeds `voxa-daemon` at `Voxa.app/Contents/Resources/bin/voxa-daemon`.

## `voxactl` Quick Usage

Examples from repo root:

```bash
cargo run -p voxactl -- health
cargo run -p voxactl -- status
cargo run -p voxactl -- start manual
cargo run -p voxactl -- stop manual
cargo run -p voxactl -- config get
cargo run -p voxactl -- config set model gpt-4o-transcribe
cargo run -p voxactl -- api-key status
cargo run -p voxactl -- events
```

If installed via `./scripts/install.sh`, you can run `voxactl ...` directly.

## Runtime Paths

- IPC socket: `~/Library/Application Support/voxa/run/daemon.sock`
- Config file: `~/Library/Application Support/voxa/config.toml`
- LaunchAgent plist: `~/Library/LaunchAgents/com.voxa.daemon.plist`
- Daemon logs: `~/Library/Logs/voxa/daemon.out.log` and `~/Library/Logs/voxa/daemon.err.log`

## Config Defaults

Default daemon config values:
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

- `VOXA_SOCKET`: override daemon socket path (daemon + `voxactl`)
- `VOXA_CONFIG_PATH`: override daemon config file path
- `VOXA_DAEMON_BIN`: override daemon executable path used by menu bar LaunchAgent install
- `VOXA_OPENAI_TRANSCRIPTIONS_URL`: override OpenAI transcriptions endpoint (useful for tests/mocks)
- `OPENAI_API_KEY`: fallback key source (and source when `api_key_source = "env"`)

## Development Checks

Minimal workspace check:

```bash
./scripts/check.sh
```

Optional fuller checks:

```bash
cargo test --workspace
swift test --package-path apps/voxa-menubar
```

## Documentation

- `docs/architecture.md`
- `docs/ipc.md`
- `docs/voxactl.md`
