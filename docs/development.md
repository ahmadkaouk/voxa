# Voxa development

See the [user guide](usage.md) for installation, permissions, and everyday use,
and the [architecture guide](architecture.md) for component ownership and recovery
behavior. All commands below run from the repository root.

## Script responsibilities

| Script | Purpose |
| --- | --- |
| `check.sh` | Build the app and select XCTest or the standalone fallback. Use this for routine validation. |
| `test.sh` | Run all or one of the six standalone Swift test suites without requiring Xcode. |
| `package-macos.sh` | Assemble the app's executable, icon, resources, and metadata; sign it and create a DMG. |
| `verify-native-bundle.sh` | Share bundle and signature checks between packaging, installation, and installer tests. |
| `install.sh` | Stage and verify an app, preserve a backup, and restore the previous app if replacement fails. |
| `test-install.sh` | Exercise installation and recovery in temporary directories using two supplied signed apps. |
| `preview-overlay.sh` | Build an optional visual preview without recording or transcription. |
| `preview-recording-styles.sh` | Build four native Liquid Glass recording-bar concepts for side-by-side and floating previews (macOS 26+). |
| `preview-feedback-styles.sh` | Compare three interactive native Liquid Glass feedback concepts with synthetic text (macOS 26+). |
| `preview-feedback.sh` | Render native feedback and learning views with isolated sample data. |
| `preview-feedback-gallery.sh` | Build the production feedback gallery with 30 interactive scenarios and validate its synthetic fixtures. |
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

One standalone runner provides all six focused suites:

```bash
./scripts/test.sh           # All standalone checks, even when XCTest is available
./scripts/test.sh hotkeys   # Shortcut validation
./scripts/test.sh recorder  # Audio capture and WAV encoding
./scripts/test.sh sounds    # Bundled sound resources
./scripts/test.sh output    # Clipboard delivery and restoration
./scripts/test.sh pipeline  # Sessions, transcription, async output, and setup
./scripts/test.sh island    # Native panel resizing from recording through feedback
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

Run `./scripts/preview-island.sh`, then open
`.build/island-gallery/Voxa Island Gallery.app` to test the integrated production shell.
The compact **Voxa States** window starts in Listening. Its sidebar holds each state on screen:
Hidden, Preparing microphone, Listening, Finishing recording, Transcribing, Reviewing, and Feedback.
Transcribing stays visible through delivery. Pasting and copying have no completion state;
they go directly to a waiting review, a full review, or a hidden bar. Feedback has no compact summary.
Replay runs the recording and delivery sequence through a deliberately delayed review, using the
production `VoxaIslandView`. The compact recording bar keeps finish/cancel visible without hover expansion;
feedback opens expanded automatically. Light/dark appearance and three backgrounds let you inspect the native glass.
Three synthetic examples cover a single
correction, grouped edits and a clean review. Save remains in memory, and practice is
simulated. No microphone, credentials or transcription service is used.

`AppController` now owns one `DynamicIslandController` for both activity and feedback.
The controller preserves the native panel and screen, places activity and feedback at bottom center above the Dock, and coalesces published
updates before choosing a presentation. Completion cleanup clears activity without
hiding a visible review; pending analysis can bridge to feedback. Practice and shutdown
use `hideAll()`. Feedback has no dismissal timer or outside-click monitors; it remains
visible until an explicit close/save action or a lifecycle transition. `IslandPresentation`
contains independently tested presentation priority and frame calculations.

The earlier `./scripts/preview-overlay.sh` remains a focused recording-component study.
Its 296 × 60 expanded controls, simulated input, isolated frame key, and optional desktop
float are useful for testing finish/cancel without replaying feedback. The production
Dynamic Island adds a fixed 144 × 34 recording pill with clear native Liquid Glass on macOS 26 and later and an ultra-thin material fallback. A 12-point continuous corner radius softens the Dock-like silhouette, with no extra border over the glass. Its centered waveform and controls adapt to the system appearance; cancel sits on the left and the red finish control on the right. Reduce Transparency and Increase Contrast use an opaque surface. Processing keeps the same dimensions. Feedback opens directly at 480 points wide (400 for a clean review).

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
move between corrections, simulate saving or closing, and replay each card.
**Float on desktop** (Command-1 through Command-3) opens the selected concept in a
movable native glass panel; Escape hides it. The preview uses synthetic text, does
not record audio, and does not save or modify lessons or production feedback.

The expanded feedback review is a 480-point-wide reading surface in the shared Dynamic Island. Localized
corrections stay in one sentence: removed wording is warm and struck through, while
corrected wording uses padded, rounded sage controls. Clicking a highlight or activating
the compact **Why?** disclosure in a section header opens an explanation outside the sentence ScrollView;
hover and keyboard focus alone do not open it. Original replacement wording appears in the detail
heading. `FeedbackSentenceFlow` wraps native controls along their text baselines, and
`FeedbackLessonMapping` connects edits to lessons by their source ranges, including
multiple edits belonging to one lesson. Larger rewrites use a
**You said / Say this** comparison with the improved sentence on a softly shaded surface.
Optional phrasing uses a separate **You could say** comparison without correction marks.
All notes are stacked in one scrollable review. Corrections in the same sentence stay
grouped; conflicting suggestions, optional alternatives and transcription issues stay
separate. Explanations, reusable patterns and recurring-pattern context appear in one
rounded detail well below the sentence. Previous/next controls also expose lessons
whose text mapping is ambiguous. Optional wording uses the same compact click disclosure in its header.
A sole lesson has a footer **Practice** action; multiple lessons have a microphone beside
each teaching point. Returning from practice restores that note's scroll position using
`selectedReviewNoteID`, with `selectedReviewExplanationID` restoring its explanation.
Explanations remain selected until another explanation is chosen or the user closes/toggles them. Natural reading height is tried before a scrolling
fallback; there is no placeholder or reserved explanation space. An open explanation uses its natural height up to 110 points plus 8 points of bottom spacing, and the reading viewport subtracts only its measured height. Longer explanations scroll inside the well. **Save review** saves every lesson, including optional alternatives
and notes below the visible area. The close control stays in the header, while the
footer keeps the save action and lesson count available.
The shared shell follows the system color scheme, using white in light mode and the existing
opaque charcoal in dark mode on all supported macOS versions. Increase Contrast strengthens outlines. The standalone Card comparison retains regular
Liquid Glass on macOS 26 and thick material on older systems. Clean reviews use a sage check, a concise confirmation, and selectable dictation text.
The review omits the Used well list; recognised patterns remain part of the controller's
learning-progress data. Storage recovery and shortcuts retain their production behavior.

Run `./scripts/preview-feedback-gallery.sh` and open
`.build/feedback-gallery/Voxa Feedback Gallery.app` for focused feedback scenarios in the production island and standalone Card comparison. **Presentation** defaults to
**Island**; select **Card** to compare the existing floating design. Island starts
expanded, sharing the card's inline corrections, interactive teaching points and save
controls. There is no collapse control or compact summary. `FeedbackIslandView` delegates to the shared `VoxaIslandView`. The menu strip above
the island is simulated scenery inside the gallery, not the system menu bar.
The Island option uses the production `VoxaIslandView`; Card remains a comparison view.
Production recording and feedback use `DynamicIslandController`. `IslandPresentation.defaultFrame`
places every state horizontally at the physical screen center with its bottom 20 points above the usable desktop edge.
Feedback grows upward from that same bottom edge, including when explanations open or close. SwiftUI drag gestures cover the bar's waveform and the review header, leaving buttons usable. The controller skips resizing during a drag and saves the display-relative horizontal center and bottom edge in `VoxaIslandPosition.v1`. It restores that anchor across recordings and app restarts, clamps larger reviews to the usable desktop, and falls back to bottom center if the saved display is disconnected. Native checks use isolated defaults to verify drag, resize and restoration. The controller limits feedback to 800 points
or the screen height minus 64 points, whichever is smaller. The hosting view disables automatic
window constraints, while keeping intrinsic content measurement enabled. The controller measures the hosting view after presentation changes, and the shell reports later size changes such as explanation changes. Feedback uses its content's natural height up to the limit, then scrolls without visible
indicators. Hover does not affect its size; explicit explanation actions fit the panel to its content. `FeedbackPanelController` is retained for standalone
component previews and is no longer constructed by `AppController`.
The script compiles all production views and validates all 31 fixtures. The sidebar
groups everyday, complex and runtime states: single and grouped corrections, rewrites,
multiple sentences, optional and paired alternatives, clean reviews, recognised and
recurring patterns, transcription uncertainty, short-phrase replacements, separate
insertion-only and deletion-only cases, apostrophes and accented names, conflicting edits,
long text, saving, loading and recoverable storage/progress errors. Cases where Voxa
stays quiet are labelled **No popup** rather than creating synthetic production popups.
Light/Dark appearance and White/Dark/Wallpaper backgrounds are independent. The slider
button reveals constrained-height, Reduce Transparency and Increase Contrast controls;
these settings apply only to the fixture app. **Replay** (Command-R) restores the current case; saving/loading take
six seconds, and simulated first-attempt failures recover through the real retry actions.
The gallery's **Review** menu wires Command-S and Escape to the selected review without
registering production global shortcuts.
Check inline replacements, insertion/deletion marks, larger comparisons, paired
alternatives, click/keyboard explanations and constrained scrolling in both presentations.
In Island, also check saving with Command-S and closing with Escape.
Practice selection reports the selected wording in the gallery footer.
All data and history stay in memory; the gallery uses no credentials or microphone.

`./scripts/preview-feedback.sh` renders feedback, saved-lesson, progress, settings,
and practice views under `.build/feedback-previews/`. It uses synthetic findings
and in-memory storage, without microphone capture, credentials or user history.
Native Liquid Glass is rendered by the window server and may be absent from the
static bitmap captures. Use **Preview → Feedback Card Window** (Command-Shift-V) in
the interactive workspace preview to inspect the production glass view, including
explanations and Save. This window hides the fixture's floating panel so it cannot
cover the controls being tested. Its independent appearance and backdrop controls
check light/dark text over white pages, dark pages, and a busy background. Preview-only
Reduce Transparency and Increase Contrast controls check the opaque fallback without
changing system preferences.
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
visible explanations and the floating panel's resizing. The panel stays open during
interaction checks until explicitly closed.
Its Settings preview uses the production shortcut recorder with in-memory bindings.
Check a new combination, Escape cancellation, reassigning Escape under Cancel / Close,
the inline Save feedback and Cancel / Close key buttons in English Learning settings,
and direct typing/pasting in the full-width secure API key field. Saving in the fixture
only clears its synthetic input; the Keychain suite uses a separate disposable item.
Settings uses native grouped forms, neutral action buttons, and system typography;
compare API Key with General and Shortcuts at the same window size. Feedback's sage
change highlights do not change the neutral styling in Settings or the library.
Both sidebars share 32-point rows, unboxed outline SF Symbols in 20-point frames,
native body text, and the same column widths. Icons are neutral gray; selected rows
use a charcoal background with white labels, icons, and counts, inspired by Apple
Books. Check light/dark and inactive-window contrast, keyboard selection, and that
labels and lesson counts fit at minimum width.
Feedback stays visible beyond the former five-second timeout, including clean reviews;
clicking elsewhere leaves it visible. Close, Done, Save review and the configured
Cancel / Close shortcut dismiss it explicitly.

`./scripts/test.sh output --live` opens a temporary text window to
check the actual paste shortcut, selection replacement, Unicode, and clipboard
restoration. It requires Accessibility permission for the test process and
saves/restores the system clipboard. Ordinary output checks use isolated
pasteboards and leave the system clipboard alone.
