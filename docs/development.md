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
| `preview-recording-styles.sh` | Build four native Liquid Glass recording-bar concepts for side-by-side and floating previews (macOS 26+). |
| `preview-feedback-styles.sh` | Compare three interactive native Liquid Glass feedback concepts with synthetic text (macOS 26+). |
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
sounds with simulated recording states and levels, without microphone access. The
shipping bar is a 220 × 48 rounded rectangle with continuous 16-point corners,
following the Dock silhouette, with clear Liquid Glass on macOS 26+, regular
material on earlier systems, and an opaque surface with Reduce Transparency. It
uses system red and green for recording and completion, respects Reduce Motion,
and preserves the saved screen position when migrating from the wider bar.

For the recording-bar design study, run `./scripts/preview-recording-styles.sh` and
open `dist/apps.noindex/Voxa Glass Preview.app`. It opens the refined **Compact native**
concept: a 220 × 48 Dock-shaped rounded rectangle using clear system Liquid Glass, semantic label colors,
and macOS `systemRed` / `systemGreen` for recording and completion. Recording shows
the timer, waveform, and one stop control. Processing replaces these with a spinner
and status; completion shows a green checkmark and Text ready. It has no duplicate
status dot, custom gradient, forced dark appearance, or inactive button. Listening, Processing, and Complete are
also shown together beneath the interactive preview. **Original four styles** opens
the earlier Clear capsule, Frosted studio, Split glass, and Compact pebble gallery.
Both views show actual point sizes using Apple's native `glassEffect` and
`GlassEffectContainer` APIs. Switch the shared
background between wallpaper, a light workspace, and a dark workspace, and compare
Listening, Processing, and Complete. Animate controls the simulated waveform; the
timer stays at 0:24 for comparison. The preview respects Reduce Motion.

Each **Float on desktop** button opens that style in a draggable, transparent panel.
The stop button demonstrates processing and completion; **Replay recording** resets
the state. Press Escape or **Hide floating preview** to dismiss the panel. Command-1
through Command-4 switch the original floating styles; Command-5 floats the combined
concept. This separate preview app needs macOS 26+
and never records, registers dictation hotkeys, saves preferences, or changes the
installed recording bar. The production app still supports macOS 13.

For the feedback design study, run `./scripts/preview-feedback-styles.sh` and open
`dist/apps.noindex/Voxa Feedback Preview.app`. Compare **Quiet card**, **Reading panel**,
and **One at a time** on wallpaper, light, and dark backdrops. The example picker
includes two corrections, a long sentence, and optional wording. Expand explanations,
pin, move between corrections, simulate saving or closing, and replay each card.
**Float on desktop** (Command-1 through Command-3) opens the selected concept in a
movable native glass panel; Escape hides it. The preview uses synthetic text, does
not record audio, and does not save or modify lessons or production feedback.

The production feedback panel uses **Quiet card**: a 380-point-wide glass surface,
full You said / Improved sentences, disclosure explanations, header pin/close controls,
and a fixed Save action with the live auto-close status. macOS 26+ uses native Liquid
Glass; earlier systems use regular material, and Reduce Transparency uses an opaque
surface. It preserves grouped corrections, optional wording, recognition issues,
practice actions, storage recovery, and the user's shortcuts and dismissal preferences.

`./scripts/preview-feedback.sh` renders feedback, saved-lesson, progress, settings,
and practice views under `.build/feedback-previews/`. It uses synthetic findings
and in-memory storage, without microphone capture, credentials or user history.
Native Liquid Glass is rendered by the window server and may be absent from the
static bitmap captures. Use **Preview → Feedback Card Window** (Command-Shift-V) in
the interactive workspace preview to inspect the production glass view, including
explanations and Save. This window hides the fixture's floating panel so it cannot
cover the controls being tested.
Check short and long comparisons, insertions/deletions, optional phrasing,
recognition issues, light/dark appearance and a constrained panel height.

Use `./scripts/preview-workspace.sh` and open
`.build/workspace-preview/Voxa Workspace Preview.app` to verify native sidebars,
toolbar materials, search and window resizing. Press Command-comma for Settings;
the Preview menu switches light/dark appearance for the fixture app only. It uses
in-memory lessons and preferences, with no credentials or microphone access.
Use **Minimum Window Size**, **Standard Window Size**, and **Large Window Size**
to repeat checks at the native minimum and larger sizes. **Window Size Details…**
reports the current and minimum dimensions. Select the long subject–verb agreement
lesson, move both column dividers to their limits, and check that the full sentences
wrap and remain reachable by scrolling. In Settings, check the final Data & privacy
rows at the minimum size as well as the API key and shortcut controls.
Choose **Preview → Feedback Panel** (Command-Shift-F) to check sentence context,
click-to-expand explanations and the floating panel's resizing. The fixture pins
this panel open so it stays available during interaction checks.
Its Settings preview uses the production shortcut recorder with in-memory bindings.
Check a new combination, Escape cancellation, reassigning Escape under Cancel / Close,
the inline Save feedback and Cancel / Close key buttons in English Learning settings,
and direct typing/pasting in the full-width secure API key field. Saving in the fixture
only clears its synthetic input; the Keychain suite uses a separate disposable item.
Settings uses native grouped forms, neutral action buttons, and system typography;
compare API Key with General and Shortcuts at the same window size. Blue correction
highlights belong to feedback, with no blue tint forced on Settings or the library.
Both sidebars share 32-point rows, unboxed outline SF Symbols in 20-point frames,
native body text, and the same column widths. Icons are neutral gray; selected rows
use a charcoal background with white labels, icons, and counts, inspired by Apple
Books. Check light/dark and inactive-window contrast, keyboard selection, and that
labels and lesson counts fit at minimum width.
In English Learning settings, change Auto-close feedback and select Never; verify
the explanatory footer updates and the picker follows the feedback toggle.

`./scripts/test.sh output --live` opens a temporary text window to
check the actual paste shortcut, selection replacement, Unicode, and clipboard
restoration. It requires Accessibility permission for the test process and
saves/restores the system clipboard. Ordinary output checks use isolated
pasteboards and leave the system clipboard alone.
