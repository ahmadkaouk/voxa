# Voxa

Voxa is a macOS dictation system built around a local daemon and thin clients.

Status: macOS-only, build-from-source, early-stage.

The core idea is simple: `voxa-daemon` runs as a separate local server, owns recording, transcription, config, and runtime state, and exposes a local IPC API. Clients stay lightweight and talk to the daemon instead of re-implementing that logic. That keeps the architecture flexible and makes it easier to add or experiment with different clients over time.

## Architecture

- `voxa-daemon` is the server boundary. It records audio, calls OpenAI for transcription, stores config and secrets, and publishes runtime state over IPC.
- Clients connect over IPC, send commands, subscribe to events, and provide their own UX.
- `voxa-core` holds shared domain types and protocol primitives used across the workspace.

## Included Components

- `apps/voxa-menubar`: the main SwiftUI menu bar client for everyday use
- `crates/voxactl`: a small CLI used mainly for testing, debugging, and development
- `crates/voxa-daemon`: the local daemon and IPC server
- `crates/voxa-core`: shared domain, IPC, and infrastructure primitives

## What You Can Do Today

- Use the SwiftUI menu bar app for push-to-talk dictation
- Send transcripts to the clipboard or directly into the active app
- Control and inspect the daemon from `voxactl`
- Build a packaged macOS app bundle and DMG

The menu bar app installs or updates a per-user LaunchAgent for `voxa-daemon` and starts it automatically.

## Build From Source

### Requirements

- macOS 13+
- Rust toolchain (stable)
- Xcode Command Line Tools / Swift 5.9+
- OpenAI API key

For DMG packaging, macOS tools `sips`, `iconutil`, and `hdiutil` must also be available.

### Run

1. Install the Rust binaries:

```bash
./scripts/install.sh
```

2. Run the menu bar app:

```bash
cd apps/voxa-menubar
swift run voxa-menubar
```

3. Add your OpenAI API key from the menu bar UI.

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

## Repository Layout

- `apps/voxa-menubar`: SwiftUI menu bar app
- `crates/voxa-daemon`: daemon process and runtime state authority
- `crates/voxactl`: CLI for testing, debugging, and support workflows
- `crates/voxa-core`: shared domain, IPC, and infrastructure primitives
- `docs/`: architecture, IPC contract, and CLI notes

## Documentation

- `apps/voxa-menubar/README.md`
- `crates/voxactl/README.md`
- `docs/architecture.md`
- `docs/ipc.md`
