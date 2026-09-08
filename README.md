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

1. Open Voxa from the menu bar and choose **Add API Key…**. Save your OpenAI API
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
| Discard a recording | Click **×** on the dictation bar while recording |

Change shortcuts under **Hotkeys** in the menu. **Max Recording** sets the
recording limit; the default is five minutes. Transcription begins after
recording finishes. Discarding a recording skips transcription and output.

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

Voxa records audio locally and sends the completed recording to OpenAI for
transcription. **Transcription requires internet access.**

The app holds recordings and the latest transcript in memory; it does not save
an audio or transcript history to disk. API keys entered in the app are stored
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
