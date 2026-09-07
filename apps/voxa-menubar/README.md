# voxa-menubar

`voxa-menubar` is Voxa's native SwiftUI menu bar application. The UI and global
hotkeys drive one `DictationSession`, which directly calls the native
recorder, transcription client, and serialized transcript output worker.

`AppController` handles setup, preferences, presentation effects, and shutdown.
The application runs in one process. The retired Rust backend is preserved in Git
at `881b78f`; signed legacy app backups remain available locally for rollback.

## Run

```bash
# Requires Swift 6.0+ (the pinned TOMLDecoder dependency)
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

Packaging builds and signs one native executable. Quit other Voxa copies before
launching it. When upgrading an older installation, setup waits until the legacy
recorder is stopped, unregisters the recognized Voxa LaunchAgent, and
archives its plist while preserving the original TOML and Keychain entry.

`./scripts/install.sh` builds and installs the signed app; use `--app /path/to/Voxa.app`
to install an existing candidate. It refuses to replace a running destination and
preserves a verified backup. `VOXA_DIST_DIR` selects a separate build output, and
`VOXA_INSTALL_DIR` supports test installs outside `/Applications`. See the
[migration completion report](../../docs/native-migration-completion.md).

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
- The dictation bar rests as a small handle when Voxa is ready and an API key is configured. Click it to start, use the checkmark to finish, or X to discard the recording without transcription or paste.
- Recording uses a compact dark pill with a live white meter, followed by processing dots and a brief completion check. Reduced Motion disables continuous animation.
- Bundled [UI SFX Zen](https://uisfx.com/) sounds distinguish start, stop, and errors, with playback levels about 3 dB above the upstream defaults. The MP3 assets and CC0 license are in `Sources/VoxaMenuBar/Resources/Sounds/Zen`; playback works offline.
- To inspect the real overlay and sounds without microphone access, run `./scripts/preview-overlay.sh` from the repository root, then open `dist/apps.noindex/Voxa Overlay Preview.app`. Its meter and state transitions are simulated.
- Settings import reads the old `~/Library/Application Support/voxa/config.toml` once using TOMLDecoder 0.4.5. A validated, versioned UserDefaults value records completion. Failed imports can be retried; the original file is never changed.
- Native Security APIs read/update the existing `com.voxa` / `OPENAI_API_KEY` item. Keychain authorization may be requested because the app now accesses the key itself. Secrets are never saved in preferences or logs.
- `api_key_source = "env"` stays read-only. Keychain mode retains the `OPENAI_API_KEY` fallback for a missing/empty entry. `VOXA_CONFIG_PATH` overrides the initial import source; `VOXA_OPENAI_TRANSCRIPTIONS_URL` retains the development endpoint override.
- Permission recovery actions open Microphone, Accessibility, and Input Monitoring settings. Returning to the app or waking the Mac refreshes access and re-registers hotkeys.
- Normal Quit waits for microphone release and clipboard cleanup.

Run all Swift checks, including the application build, with `./scripts/test-swift.sh`
from the repository root. It uses XCTest when available and otherwise runs the same
existing assertions through standalone harnesses for hotkeys, clipboard, sounds,
recording, and the native pipeline. A new
test file without standalone coverage fails the fallback path instead of being skipped.

The native recorder and pipeline are connected to the app. `./scripts/test-audio-recorder.sh`
checks capture fixtures; `./scripts/test-native-pipeline.sh` checks session ordering,
HTTP/output behavior, settings migration, and a disposable Keychain entry. These
checks use no real microphone or external API. See the [completion report](../../docs/native-migration-completion.md)
for validation evidence and its limits.

Clipboard integration checks can also run with just Command Line Tools (no XCTest runner):

```bash
./scripts/test-transcript-output.sh
```

They exercise the production pasteboard code using isolated, uniquely named pasteboards and do not alter the system clipboard.

Add `--live` to also open a temporary native text window and test the actual paste shortcut, selection replacement, Unicode, and clipboard restoration. That optional check requires Accessibility permission for the test process and temporarily uses the system clipboard; it saves and restores its contents and returns focus to the previous app.
