# voxa-menubar

`voxa-menubar` is the main SwiftUI client for Voxa.

It provides the day-to-day user experience: it lives in the macOS menu bar, captures hotkeys, talks to `voxa-daemon` over local IPC, and handles transcript output.

## Responsibilities

- Connect to `voxa-daemon` over IPC
- Keep UI state in sync with daemon state and config
- Capture global hotkeys and forward start/stop commands
- Save API keys and expose daemon lifecycle controls
- Output transcripts to the clipboard, clipboard plus autopaste, or nowhere
- Install or update the per-user LaunchAgent for `voxa-daemon`

## Run

```bash
cd apps/voxa-menubar
swift run voxa-menubar
```

## Permissions

Depending on the features you use, macOS may ask for:

- Microphone access
- Accessibility permission for autopaste
- Input Monitoring for global hotkeys

## Packaging

```bash
./scripts/package-macos.sh
```

The packaged `Voxa.app` embeds `voxa-daemon` at `Contents/Resources/bin/voxa-daemon`, and the menu bar app prefers that bundled daemon when installing the LaunchAgent.

Generated app bundles and installer staging live under `dist/apps.noindex/` so macOS app search does not list development copies alongside `/Applications/Voxa.app`. Keep local app backups in `dist/apps.noindex/backups/`. The distributable disk image remains `dist/Voxa.dmg`.

Packaging now code-signs the app bundle so macOS permissions can persist across in-place updates.

- If `VOXA_CODESIGN_IDENTITY` is set, the package script signs with that identity.
- Otherwise it prefers an installed `Apple Development` or `Developer ID Application` identity.
- If neither is available, it creates and reuses a stable local identity named `Voxa Local Development` in `~/Library/Application Support/Voxa/codesign/`.

After switching from older ad-hoc builds to a stable signed build, macOS may ask for Accessibility and Input Monitoring one more time. Updates signed with the same identity should then keep those permissions when you replace `/Applications/Voxa.app` in place.

## Notes

- Autopaste temporarily borrows the clipboard, waits for a text read, then restores all saved items and formats. Restoration is skipped if the clipboard changed in the meantime. Clipboard reads are a best-effort delivery signal; macOS does not provide a universal paste-success acknowledgement.
- If the paste shortcut cannot be sent or the clipboard is not read within two seconds, the transcript remains available for manual paste. If the original clipboard cannot be fully saved, autopaste leaves it untouched. Output → Copy Last Transcript can recover the latest dictation in either case; it is kept only in memory while Voxa is running.
- Clipboard Only intentionally replaces the clipboard. All output operations are serialized so overlapping transcripts and explicit copies cannot restore over each other.
- The dictation bar rests as a small handle when Voxa is connected and an API key is configured. Click it to start, use the checkmark to finish, or X to discard the recording without transcription or paste.
- Recording uses a compact dark pill with a live white meter, followed by processing dots and a brief completion check. Reduced Motion disables continuous animation.
- Bundled [UI SFX Zen](https://uisfx.com/) sounds distinguish start, stop, and errors, with playback levels about 3 dB above the upstream defaults. The MP3 assets and CC0 license are in `Sources/VoxaMenuBar/Resources/Sounds/Zen`; playback works offline.
- To inspect the real overlay and sounds without microphone access, run `./scripts/preview-overlay.sh` from the repository root, then open `dist/apps.noindex/Voxa Overlay Preview.app`. Its meter and state transitions are simulated.
- The app resyncs state and config after reconnecting to the daemon.
- Automatic reconnect backoff: `200ms`, `500ms`, `1s`, `2s`, `5s`.
- The app does not shell out to `voxactl` for runtime state.
- The app does not parse daemon logs.

Run all Swift checks, including the application build, with `./scripts/test-swift.sh`
from the repository root. It uses XCTest when available and otherwise runs the same
existing assertions through standalone unit, clipboard, and sound harnesses. A new
test file without standalone coverage fails the fallback path instead of being skipped.

Clipboard integration checks can also run with just Command Line Tools (no XCTest runner):

```bash
./scripts/test-transcript-output.sh
```

They exercise the production pasteboard code using isolated, uniquely named pasteboards and do not alter the system clipboard.

Add `--live` to also open a temporary native text window and test the actual paste shortcut, selection replacement, Unicode, and clipboard restoration. That optional check requires Accessibility permission for the test process and temporarily uses the system clipboard; it saves and restores its contents and returns focus to the previous app.
