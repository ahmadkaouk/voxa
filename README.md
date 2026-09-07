# Voxa

Voxa is a native macOS dictation application. Its SwiftUI menu bar UI, microphone recording, transcription, and output run in one process.

Status: macOS-only, build-from-source. See the [architecture](docs/architecture.md).

## Architecture

One SwiftUI application process contains the UI/hotkeys and one `DictationSession`.
The session directly calls `AudioRecorder`, `TranscriptionClient`, and `TranscriptOutput`.
Small helpers handle preferences, Keychain, permissions, and retiring the old LaunchAgent.

The root Swift package contains one application target and its test target. The app has no
Rust dependency, daemon, local IPC server, or external control CLI.

## What You Can Do Today

- Use the SwiftUI menu bar app for push-to-talk dictation
- Transcribe completed recordings with OpenAI's `gpt-transcribe` model
- Send transcripts to the clipboard or directly into the active app
- Build a packaged macOS app bundle and DMG

The app retires its recognized legacy LaunchAgent after the old recorder stops. It does not start a daemon.

GPT-Transcribe is the default and supported transcription model. Saved GPT-4o Mini
Transcribe and GPT-4o Transcribe settings migrate on startup while preserving other
preferences. Native settings are saved in UserDefaults; the original TOML remains available for rollback.

## Build From Source

### Requirements

- macOS 13+
- Xcode Command Line Tools / Swift 6.0+ (TOMLDecoder requires Swift 6; deployment still targets macOS 13)
- OpenAI API key

For DMG packaging, macOS tools `sips`, `iconutil`, and `hdiutil` must also be available.

### Run

Build, sign, and install the native app (quit the installed Voxa first):

```bash
./scripts/install.sh
```

Launch `/Applications/Voxa.app`, allow any required Keychain/microphone permissions,
and use the menu bar controls or configured shortcuts. Existing settings and the
OpenAI key are reused. A fresh install can add its key from the menu bar UI.

For a development run from the repository root, `swift run voxa-menubar`
remains available. Run only one Voxa copy at a time.

## Common Tasks

Build and check the application:

```bash
./scripts/check.sh
```

Build the signed application and DMG without installing:

```bash
./scripts/package-macos.sh
```

## Repository Layout

- `Package.swift`, `Package.resolved`: Swift package and pinned dependencies
- `Sources/VoxaMenuBar/`: application code and bundled resources
- `Tests/VoxaMenuBarTests/`: regression tests
- `assets/`: application icon source used by packaging
- `scripts/`: build, packaging, installation, tests, and development fixtures
- `docs/`: architecture and development guide

Generated build files live in `.build/` and `dist/` and are ignored by Git.
Preserve signed app backups under `dist/apps.noindex/backups/` before cleaning build outputs.

## Documentation

- [Development guide](docs/development.md)
- [Architecture](docs/architecture.md)
