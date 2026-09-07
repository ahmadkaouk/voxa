# Voxa

Voxa is a macOS dictation application. The Swift migration branch now connects the menu bar UI to native recording, transcription, and output in one process.

Status: macOS-only, build-from-source, native migration in progress. See the [migration plan](docs/swift-migration-plan.md) and [native app report](docs/native-application-integration.md).

Stage 5 validates the native candidate. Rust source and the signed legacy app remain
available for rollback until the daily-use gate passes; see [candidate validation](docs/native-candidate-validation.md).

## Architecture

One SwiftUI application process contains the UI/hotkeys and one `DictationSession`.
The session directly calls `AudioRecorder`, `TranscriptionClient`, and `TranscriptOutput`.
Small helpers handle preferences, Keychain, permissions, and retiring the old LaunchAgent.

`apps/voxa-menubar` contains the application. The `crates` directory and IPC code are
preserved legacy implementations and regression coverage; native dictation does not use them.

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
- Rust toolchain only for the retained legacy regression suite; native packaging and installation do not require Rust
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

Run the Rust tests:

```bash
cargo test --workspace
```

Run the Swift tests:

```bash
./scripts/test-swift.sh
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
