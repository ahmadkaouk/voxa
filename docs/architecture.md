# Voxa architecture

Voxa is one macOS application process. The root `voxa` Swift package contains the
`Voxa` application target in `Sources/Voxa` and the `VoxaTests` target in
`Tests/VoxaTests`, with `voxa` as the development executable. The deployment
target is macOS 13; development uses Swift 6.0+.

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

`PreferencesStore` validates and saves one versioned UserDefaults value under
`nativePreferences.v1`. Existing settings keep the same format and storage key.
A first launch saves the defaults; invalid saved settings produce a recoverable
setup error. Failed saves restore the previous value.

`Keychain` uses native Security APIs for service `com.voxa`, account
`OPENAI_API_KEY`. The environment source is read-only. Keychain mode retains the
environment fallback for a missing/empty item; denied Keychain access is an error.
Credentials are not written to preferences or diagnostic logs.

`Permissions` handles microphone, Accessibility, and Input Monitoring checks and
recovery. The installed app keeps bundle ID `com.voxa.menubar` and a stable signing
identity independently of the Swift target and executable names, so existing
permissions and UserDefaults remain associated with Voxa. Microphone access is
requested before capture. Permission state and hotkeys refresh when returning to
the app or waking the Mac.

## Installation and recovery

`scripts/package-macos.sh` builds and signs the Swift executable, icons, and sounds
with their license, then creates a DMG. `scripts/verify-native-bundle.sh` checks
the signature, identity, resources, deployment target, and exactly one executable.
`scripts/install.sh` verifies a staged copy and backs up the existing signed app
before replacement. A failed final move restores the previous app. Replacing a
running app is refused.

`CaptureGuard` blocks setup and recording if another Voxa copy is running.
It checks through AppKit before and after permission/credential work, so a copy
launched while a prompt is open is also detected.

Signed backups stay under `dist/apps.noindex/backups/`; preserve that directory
before cleaning build artifacts. To roll back, quit Voxa and restore the entire
preserved signed app bundle to `/Applications/Voxa.app`.

## Validation

`./scripts/check.sh` builds the app and runs Swift tests. XCTest is used when
available; Command Line Tools run the same shared assertions through standalone
harnesses. Discovery guards reject unregistered test files instead of silently
skipping them. Fixtures cover capture/conversion, session ordering and cleanup,
HTTP errors, output/clipboard recovery, settings/Keychain, and duplicate-app protection.

`scripts/test-install.sh` exercises clean installation, signed updates/backups,
failure recovery, and the running-app guard in temporary directories. See the
[development guide](development.md) for development commands and
the optional live clipboard and overlay checks.
