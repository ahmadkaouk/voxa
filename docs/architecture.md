# Voxa architecture

Voxa is one macOS application process, with one Swift application target and one
test target. The deployment target is macOS 13; building requires Swift 6.0+ for
the pinned TOMLDecoder dependency.

```text
Voxa.app
  UI and hotkeys
        │
  DictationSession (@MainActor)
        ├── AudioRecorder       serial capture/conversion worker
        ├── TranscriptionClient async URLSession
        └── TranscriptOutput    serial clipboard/paste worker
```

## Ownership and concurrency

`DictationSession` is the sole observable owner of the dictation workflow. Views
observe the same session instance and send it start, stop, and cancel actions.
`AppController` connects setup, settings, hotkeys, permission recovery, sounds,
overlay presentation, and shutdown. Local view state controls presentation only.

Each recording has an ID and settings snapshot. The session checks both its ID
and expected state after suspension so a late callback cannot complete a newer
recording. States are `idle`, `starting`, `recording`, `finishing`, `transcribing`,
`delivering`, and `failed`. Stop or cancel during preparation is remembered;
releasing a hold shortcut during a permission prompt cannot start capture later.
Cancellation is limited to recording. Normal Quit invalidates pending work and
awaits capture teardown and clipboard cleanup before the process exits.

The three workers are constructed directly. Small protocols and injected closures
allow deterministic tests; there is no service container, event bus, backend
selector, separate core package, daemon, socket, or external control CLI.

## Recording, transcription, and delivery

| Component | Behavior |
| --- | --- |
| `AudioRecorder` | Owns AVAudioEngine lifecycle on a serial worker. A four-slot bounded inbox copies tap buffers without resampling or allocating audio buffers in the callback. Stop drains accepted audio; cancellation discards it. Interruptions, overruns, and a stalled microphone fail the recording and clean up. |
| `AudioWAVEncoder` | Downmixes and streams conversion to 16 kHz mono PCM16 WAV, bounded by the configured 1–3,600-second limit. Meter sensitivity and smoothing affect the display only. |
| `TranscriptionClient` | Uploads WAV data with async URLSession, the configured model, and a Bearer credential. The request timeout is 60 seconds. Redirects and automatic retries are disabled; errors are typed and no transcript/key is logged. |
| `TranscriptOutput` | Serializes delivery and Copy Last Transcript. Autopaste saves all clipboard items/formats, sends paste, waits for consumption, and restores only if the clipboard still belongs to the operation. Clipboard Only intentionally replaces it; None skips automatic delivery. Explicit outcomes distinguish success from manual recovery. |

Audio and the latest transcript are held in memory. The app does not persist a
recording/transcript history. A failed paste can be recovered with Copy Last
Transcript while the app remains open. Clipboard reads are a best-effort delivery
signal; macOS does not acknowledge universal paste success.

## Settings, credentials, and permissions

`PreferencesStore` saves one versioned UserDefaults value. On first use it parses
the whole legacy TOML with TOMLDecoder 0.4.5, validates it, then marks import
complete atomically with the saved settings. Invalid imports remain retryable.
The original `~/Library/Application Support/voxa/config.toml` is preserved.

`Keychain` uses native Security APIs for service `com.voxa`, account
`OPENAI_API_KEY`. The environment source is read-only. Keychain mode retains the
environment fallback for a missing/empty item; denied Keychain access is an error.
Credentials are not written to preferences or diagnostic logs.

`Permissions` handles microphone, Accessibility, and Input Monitoring checks and
recovery. The app retains bundle ID `com.voxa.menubar` and a stable signing
identity. Microphone access is requested before capture, and permission state and
hotkeys refresh when returning to the app or waking the Mac.

## Installation, upgrades, and recovery

`scripts/package-macos.sh` builds and signs the Swift executable, icons, sounds,
and license notices, then creates a DMG. `scripts/verify-native-bundle.sh` checks
the signature, identity, resources, deployment target, and exactly one executable.
`scripts/install.sh` verifies a staged copy and backs up the existing signed app
before replacement. A failed final move restores the previous app. Replacing a
running app is refused.

`LegacyCaptureGuard` is retained for upgrades. It blocks capture if another Voxa
copy, old Recorder Preview, or legacy recorder is running. During setup it
validates and unregisters only the current user's recognized `com.voxa.daemon`
LaunchAgent, then archives its unchanged plist under
`~/Library/Application Support/voxa/migration/`. Unknown jobs fail with a retryable
explanation. It does not launch a helper or modify TOML, credentials, or unrelated
services.

Signed backups stay under `dist/apps.noindex/backups/`; preserve that directory
before cleaning build artifacts. To roll back, quit Voxa and restore the entire
preserved signed app bundle to `/Applications/Voxa.app`. A legacy app can recreate
its LaunchAgent and reuse the original TOML and Keychain. Settings changed only in
the native app remain in UserDefaults and do not rewrite the legacy TOML. A later
native launch retires the recreated registration again.

## Validation

`./scripts/check.sh` builds the app and runs Swift tests. XCTest is used when
available; Command Line Tools run the same shared assertions through standalone
harnesses. Discovery guards reject unregistered test files instead of silently
skipping them. Fixtures cover capture/conversion, session ordering and cleanup,
HTTP errors, output/clipboard recovery, settings/Keychain, and legacy upgrades.

`scripts/test-install.sh` exercises clean installation, signed updates/backups,
failure recovery, and the running-app guard in temporary directories. See the
[application README](../apps/voxa-menubar/README.md) for development commands and
the optional live clipboard and overlay checks.
