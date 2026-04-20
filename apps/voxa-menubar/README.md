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

Packaging now code-signs the app bundle so macOS permissions can persist across in-place updates.

- If `VOXA_CODESIGN_IDENTITY` is set, the package script signs with that identity.
- Otherwise it prefers an installed `Apple Development` or `Developer ID Application` identity.
- If neither is available, it creates and reuses a stable local identity named `Voxa Local Development` in `~/Library/Application Support/Voxa/codesign/`.

After switching from older ad-hoc builds to a stable signed build, macOS may ask for Accessibility and Input Monitoring one more time. Updates signed with the same identity should then keep those permissions when you replace `/Applications/Voxa.app` in place.

## Notes

- The app resyncs state and config after reconnecting to the daemon.
- Automatic reconnect backoff: `200ms`, `500ms`, `1s`, `2s`, `5s`.
- The app does not shell out to `voxactl` for runtime state.
- The app does not parse daemon logs.
