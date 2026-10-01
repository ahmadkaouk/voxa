# Voxa

**Speak, transcribe, and paste into the app you're using.**

Voxa is a native macOS dictation app built with Swift and SwiftUI. It lives in
your menu bar: start a recording with a shortcut, speak, and finish to turn your
words into text. Transcription uses OpenAI with your own API key.

- **Two ways to record:** hold a shortcut while speaking, or press once to start
  and again to finish. Both shortcuts are customizable.
- **Clear recording feedback:** a floating dictation bar, live audio meter, and
  sounds for recording and errors.
- **Flexible output:** paste into the active app, copy to the clipboard, or keep
  the result available for manual copying.
- **Clipboard restoration:** autopaste restores your previous clipboard when
  safe, preserving anything you copy while delivery is in progress.
- **Optional English feedback:** review all useful corrections after dictation, with highlighted
  differences, a developing English-expression profile, short spoken practice, and saved-lesson reviews.

## Get started

Voxa is currently built from source. You'll need:

- **macOS 13 or later.**
- **Swift 6.0 or later**, provided by Xcode or the Xcode Command Line Tools.
- **An OpenAI API key and an internet connection** for transcription.

Check your compiler with `swift --version`. If the developer tools are missing,
install them with `xcode-select --install`.

### Install

```bash
git clone https://github.com/ahmadkaouk/voxa.git
cd voxa
./scripts/install.sh
open /Applications/Voxa.app
```

The installer builds and signs Voxa, installs it in `/Applications`, and creates
`dist/Voxa.dmg`. When updating an existing installation, finish your dictation
and quit Voxa first. The installer preserves a signed backup of the previous app.

### Set up Voxa

1. Open Voxa from the menu bar and choose **Voxa Settings…**. Save your OpenAI API
   key; Voxa stores it in macOS Keychain.
2. Allow the permissions needed for the features you use:

   | Permission | Used for |
   | --- | --- |
   | Microphone | Recording your voice |
   | Accessibility | Pasting the transcript into another app |
   | Input Monitoring | Recognizing global shortcuts |

3. Focus a text field, hold **Option + G**, and speak. Release the shortcut to
   transcribe and paste your words.

If a permission is missing, use the **Enable…** actions in Voxa's menu to open
the relevant System Settings page. Return to Voxa after granting access.

## Using Voxa

### Recording controls

| Action | Default control |
| --- | --- |
| Hold to record | Hold **Option + G**; release to finish |
| Toggle recording | Press **Option + F** to start; press again to finish |
| Record with the mouse | Click the floating handle to start, then the checkmark to finish |
| Finish and submit | Press **Enter** while recording in Autopaste mode |
| Discard a recording | Click **×** on the dictation bar while recording |

Change shortcuts in **Voxa Settings…**.
Press **Esc** while capturing a shortcut to cancel without closing Settings.
**Max Recording** sets the recording limit; the default is five minutes. Transcription begins after
recording finishes. Discarding a recording skips transcription and output.

Model, output, and recording-limit menus remain available during dictation.
Changes made while recording or processing are saved for the next recording.

Enter finishes recording, pastes, and sends Return to the same app. This submits
in chat apps and inserts a newline in editors. It requires Accessibility access
and is skipped if you switch apps. Modified Enter shortcuts and other finish
controls keep their usual behavior.

### Choose where text goes

Select a mode under **Output**:

| Mode | Behavior |
| --- | --- |
| **Autopaste (Keep Clipboard)** | Pastes into the active app and restores the previous clipboard when safe. This is the default. |
| **Clipboard Only** | Replaces the clipboard with the transcript for you to paste. |
| **None** | Keeps the latest transcript in memory without automatically copying or pasting it. |

If automatic pasting doesn't work in a particular app, use **Output → Copy Last
Transcript** and paste manually. The latest transcript remains available until
you replace it with another dictation or quit Voxa.

## Audio and data

### English learning

Enable **Voxa Settings → English Learning → Feedback after dictation** for
background English coaching. Dictation is inserted normally and never rewritten;
feedback failures do not interrupt it.

The Quick scan review puts actual grammar and construction errors first. Small
changes appear inline: a subdued struck-through word followed by its correction.
Larger changes show readable before/after text. A short teaching reason stays
visible. Useful alternatives appear directly below the related correction, then
standalone alternatives follow. Each can teach a reusable expression, such as
**Could we + action?** Alternatives may cover any useful phrase or sentence across
the dictation, including correct sentences; they are never collapsed or forced
onto every sentence. The coach preserves meaning, tone, uncertainty and technical
terms, and ignores fillers and clear self-corrections.

An **English-expression estimate** develops across dictations, covering accuracy,
vocabulary, natural phrasing, sentence range and clarity. The header shows a
provisional CEFR-style band once there are at least six qualifying samples,
300 words and two kinds of speech (such as requests and explanations). Individual
samples need at least 40 assessable English words and evidence for all five dimensions.
Short, narrow, non-English or uncertain samples do not lower the estimate. The profile
uses the latest 30 qualifying samples within 90 days; the coverage thresholds and
aggregation are product heuristics, not calibrated confidence. This experimental
estimate has not been validated against a language exam and cannot assess listening,
pronunciation or conversational fluency. A clean dictation can still show a brief
positive review. Old grammar-only observations stay saved but cannot be converted
into a broader level without their original text.

The panel appears after delivery without taking focus or disappearing on a timer.
A new recording hides it; **English Learning → Show Latest Feedback** reopens the
latest review until another transcript replaces it.

- **Save lessons / S:** save all corrections and alternatives, then close.
  Recognition issues are excluded. S also closes a review with no lessons.
- **Close / D:** close without saving lessons. Local progress remains available.
- **English Learning → Lessons & Progress…:** review, practise, or delete saved
  lessons, and view or clear progress separately.
- **Practise this:** beneath a correction or alternative, say the improved version,
  then try the pattern in a new sentence. Use **Record answer → Stop & check**, or
  **Type instead**. Recording stops automatically at 40 seconds. Each answer gets
  one short response about the target pattern. Practice never pastes or changes
  the last dictation. Close the practice window to resume normal dictation shortcuts.
- **English Learning → One-minute Review…:** revisit up to three due patterns
  from saved lessons, with recurring grammar errors first. Examples stay hidden until
  requested. Skip freely; no reminders or daily requirements. New examples must use
  the pattern, not simply repeat the supplied wording.

Successful reviews return after 1, 3, 7, 14 and then 30 days. A retry brings the pattern
back the next day; immediate repeats do not advance the interval. Recognition
uncertainty and skipped exercises do not count as mistakes. Practice is kept separate
from the English-level estimate and correct uses observed during ordinary dictation.

Progress tracks up to 200 recent reviews automatically while feedback is enabled.
Repeated mistakes are counted by rule, and correct use of previously encountered
patterns is recognised in later dictations, including those with no corrections.
Absence of an error does not count as a success; an actual source example is
required. Counts are per review, not a mastery percentage. The Progress tab shows
the broader expression profile, its coverage, and patterns to practise.

A failed save keeps the review open. While feedback is visible, S and D act on it
instead of typing in the focused app; modified shortcuts such as Command+S still
work. Global shortcuts require Accessibility access.

Feedback is off by default. Enabling it sends transcript text in an additional
OpenAI request using the same API key, with additional usage cost. It uses
`gpt-6-luna` with low reasoning effort and requests `store: false`, which does
not guarantee zero provider retention; see [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
Only accepted excerpts, suggestions, explanations, dates, and practice prompts
are stored in `~/Library/Application Support/Voxa/corrections.json`. Automatic
progress stores only review IDs, dates, assessment bands, word counts, speaking-task
and pattern categories in
`~/Library/Application Support/Voxa/learning-progress.json`; source evidence is
validated in memory and discarded. Only category IDs, not saved lesson excerpts,
are included as context for later dictation feedback. Explicit practice sends the
selected lesson and answer to the feedback service; speaking also sends audio to the
configured transcription service. Both incur additional API usage. Audio and answers
stay in memory and are cleared when practice closes; they are not written to history.
`~/Library/Application Support/Voxa/practice-history.json` stores up to 500 lesson IDs,
attempt IDs, counts and review dates. Deleting a saved lesson also removes its review
timing. Unsaved lessons and paired-alternative practice do not reschedule the saved
primary correction. Disabling feedback cancels pending requests and clears
unsaved findings; saved lessons and existing progress remain until deleted.

### Dictation data

Voxa records audio locally and sends the completed recording to OpenAI for
transcription. **Transcription requires internet access.**

The app holds recordings and the latest transcript in memory; it does not save
an audio or full-transcript history to disk. Explicitly saved English lessons and text-free learning progress
are persisted. API keys entered in the app are stored
in macOS Keychain, and preferences are saved locally. See the
[architecture guide](docs/architecture.md) for details about data handling and
clipboard recovery.

## Development

The repository is a single Swift package with one application target and one test
target. Run these commands from the repository root:

```bash
# Build the application
swift build

# Run a development copy; quit other Voxa copies first
swift run voxa

# Build and run the regression checks
./scripts/check.sh

# Create a signed app bundle and DMG without installing
./scripts/package-macos.sh
```

The check script uses XCTest when available. With Command Line Tools, it runs
the same assertions through standalone harnesses. Checks cover recording,
session state, transcription, clipboard delivery, settings, and duplicate-app protection.

```text
Package.swift           Swift package definition
Sources/Voxa/           Application code and bundled resources
Tests/VoxaTests/        Regression tests
assets/                 App icon source
scripts/                Build, install, test, and preview tools
docs/                   Development and architecture guides
```

Build outputs in `.build/` and `dist/` are ignored by Git. Preserve
`dist/apps.noindex/backups/` before cleaning generated files.

- [Development guide](docs/development.md): signing, packaging, focused checks,
  previews, and environment overrides.
- [Architecture](docs/architecture.md): session ownership, audio capture,
  transcription, clipboard delivery, and settings.

## License

Voxa is available under the [MIT License](LICENSE). Bundled sounds have their
own [CC0 license](Sources/Voxa/Resources/Sounds/Zen/LICENSE-AUDIO).
