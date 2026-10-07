# Voxa development

See the [user guide](usage.md) for installation, permissions, and everyday use,
and the [architecture guide](architecture.md) for component ownership and recovery
behavior. All commands below run from the repository root.

## Script responsibilities

| Script | Purpose |
| --- | --- |
| `check.sh` | Build the app and select XCTest or the standalone fallback. Use this for routine validation. |
| `test.sh` | Run all or one of the five standalone Swift test suites without requiring Xcode. |
| `package-macos.sh` | Assemble the app's executable, icon, resources, and metadata; sign it and create a DMG. |
| `verify-native-bundle.sh` | Share bundle and signature checks between packaging, installation, and installer tests. |
| `install.sh` | Stage and verify an app, preserve a backup, and restore the previous app if replacement fails. |
| `test-install.sh` | Exercise installation and recovery in temporary directories using two supplied signed apps. |
| `preview-overlay.sh` | Build an optional visual preview without recording or transcription. |
| `preview-feedback.sh` | Render native feedback and learning views with isolated sample data. |
| `preview-workspace.sh` | Build an interactive Settings and English Learning preview with in-memory fixtures. |
| `check-text-context.sh` | Inspect focused editor context without recording or an API request. |

## Build and check

Open `Package.swift` in Xcode or use Swift 6.0+ from the command line:

```bash
swift build --build-system native
swift run --build-system native voxa
./scripts/check.sh
```

Quit other Voxa copies before running a development build. The check script uses
XCTest when available and otherwise runs the same assertions through standalone
harnesses. Unregistered test files fail the fallback path instead of being skipped.

Packaging and validation use the native SwiftPM build system because CLT 27's
default SwiftBuild currently stamps the deployment target as the SDK version.
The correct SDK version is needed for macOS appearance behavior. CLT 27 also
omits the SwiftUIMacros plugin; the overlay's `ViewState` alias explicitly selects
the existing `SwiftUI.State` property wrapper without that plugin.

One standalone runner provides all five focused suites:

```bash
./scripts/test.sh           # All standalone checks, even when XCTest is available
./scripts/test.sh hotkeys   # Shortcut validation
./scripts/test.sh recorder  # Audio capture and WAV encoding
./scripts/test.sh sounds    # Bundled sound resources
./scripts/test.sh output    # Clipboard delivery and restoration
./scripts/test.sh pipeline  # Sessions, transcription, async output, and setup
```

They use fixture audio and isolated pasteboards, with no microphone capture or
external API calls. The pipeline checks also exercise a disposable Keychain entry.

## Packaging and signing

`./scripts/package-macos.sh` creates a signed app under `dist/apps.noindex/`
and a distributable `dist/Voxa.dmg`. The `.noindex` directory keeps development
app copies out of macOS app search.

The packager uses `VOXA_CODESIGN_IDENTITY` when set. Otherwise, it prefers an
installed Apple Development or Developer ID Application identity. If neither is
available, it creates and reuses **Voxa Local Development** under
`~/Library/Application Support/Voxa/codesign/`.

Keep the same signing identity when replacing `/Applications/Voxa.app` so macOS
permissions can persist. Switching from an ad-hoc build to a stable identity may
require granting Accessibility and Input Monitoring again.

`./scripts/install.sh` builds and installs Voxa. To install an existing signed
candidate, use `./scripts/install.sh --app /path/to/Voxa.app`. It refuses to replace
a running destination and preserves a verified backup under
`dist/apps.noindex/backups/`. Preserve these backups before cleaning build outputs.

Test installation, backup, failed-replacement recovery, and the running-app guard
using temporary copies of a candidate and a previous signed app:

```bash
./scripts/test-install.sh dist/apps.noindex/Voxa.app /Applications/Voxa.app
```

This check does not replace or launch either supplied app.

## Development overrides

| Variable | Purpose |
| --- | --- |
| `VOXA_DIST_DIR` | Select a separate packaging output and backup directory. |
| `VOXA_INSTALL_DIR` | Change the installation directory; defaults to `/Applications`. |
| `VOXA_CODESIGN_IDENTITY` | Select the identity used to sign the app. |
| `VOXA_OPENAI_TRANSCRIPTIONS_URL` | Override the transcription endpoint for development. |
| `OPENAI_API_KEY` | Supply a key for environment mode, or as a fallback when the Keychain item is missing. |

Settings and Keychain access are described in the [architecture guide](architecture.md).

## Manual checks

To collect a dictation timing breakdown, enable the optional local JSON-lines log
and restart the packaged app:

```bash
defaults write com.voxa.menubar VoxaTimingLogPath -string "$PWD/dist/dictation-timing.jsonl"
```

The log records audio finalization, the transcription request (including upload
and response decoding), output preparation, and the clipboard-read signal.
Clipboard restoration is timed separately. The read signal is a delivery proxy;
use a receiving text window to measure actual insertion.

The `transcription` measurements include audio/multipart sizes and URLSession's
per-transaction connection setup, request sending, waiting for the first response
byte, and response receiving. Connection reuse, protocol and status are recorded.
Waiting includes network travel and server processing; it is not model inference
time alone. Sending ends when the client sends the last byte, not when the server
acknowledges it. DNS and connection details are subsets of `pre_request`, and TLS
is included in `connect_including_tls`; do not sum these overlapping intervals.
Unavailable measurements are omitted, including connection timings on reuse.

Logs contain measurements, recording IDs and outcomes, without audio, transcripts,
credentials, URLs or headers. File work runs after delivery. To disable logging,
delete the override and restart Voxa:

```bash
defaults delete com.voxa.menubar VoxaTimingLogPath
```

Build the overlay preview with `./scripts/preview-overlay.sh`, then open
`dist/apps.noindex/Voxa Overlay Preview.app`. It uses the production overlay and
sounds with simulated recording states and levels, without microphone access.

`./scripts/preview-feedback.sh` renders feedback, saved-lesson, progress, settings,
and practice views under `.build/feedback-previews/`. It uses synthetic findings
and in-memory storage, without microphone capture, credentials or user history.
Check short and long comparisons, insertions/deletions, optional phrasing,
recognition issues, light/dark appearance and a constrained panel height.

Use `./scripts/preview-workspace.sh` and open
`.build/workspace-preview/Voxa Workspace Preview.app` to verify native sidebars,
toolbar materials, search and window resizing. Press Command-comma for Settings;
the Preview menu switches light/dark appearance for the fixture app only. It uses
in-memory lessons and preferences, with no credentials or microphone access.

`./scripts/test.sh output --live` opens a temporary text window to
check the actual paste shortcut, selection replacement, Unicode, and clipboard
restoration. It requires Accessibility permission for the test process and
saves/restores the system clipboard. Ordinary output checks use isolated
pasteboards and leave the system clipboard alone.
