# Voxa

Voxa is a native macOS dictation application. Its SwiftUI menu bar UI, microphone recording, transcription, and output run in one process.

Status: macOS-only, build-from-source. See the [architecture](docs/architecture.md) and [migration completion report](docs/native-migration-completion.md).

## Architecture

One SwiftUI application process contains the UI/hotkeys and one `DictationSession`.
The session directly calls `AudioRecorder`, `TranscriptionClient`, and `TranscriptOutput`.
Small helpers handle preferences, Keychain, permissions, and retiring the old LaunchAgent.

`apps/voxa-menubar` contains one application target and its test target. The app has no
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

For a development run, `swift run --package-path apps/voxa-menubar voxa-menubar`
remains available. Run only one Voxa copy at a time.

## Common Tasks

Check the workspace:

```bash
./scripts/check.sh
```

Run the Swift tests:

```bash
./scripts/test-swift.sh
```

## Repository Layout

- `apps/voxa-menubar`: SwiftUI menu bar app
- `scripts/`: build, packaging, installation, tests, and development fixtures
- `docs/`: native architecture and migration evidence
- `docs/archive/`: historical daemon design and retired CLI/IPC documentation

## Documentation

- [Application usage and development](apps/voxa-menubar/README.md)
- [Architecture](docs/architecture.md)
- [Documentation index](docs/README.md)
