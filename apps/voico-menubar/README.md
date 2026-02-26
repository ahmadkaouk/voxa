# voico-menubar

Native macOS menu bar controller for the `voico` daemon.

## Requirements

- macOS 13+
- Xcode Command Line Tools
- `voico` installed and available on PATH (or at `~/.cargo/bin/voico`)

Install/update backend binary:

```bash
cd /Users/ahmadkaouk/projects/voico
./scripts/install.sh
```

## Run

```bash
cd /Users/ahmadkaouk/projects/voico/apps/voico-menubar
swift run
```

This launches a menu bar app (no Dock icon) with controls for:

- service start/stop/reinstall
- daemon hotkey/mode/output config
- API key save via `launchctl setenv OPENAI_API_KEY ...`
- log opening and refresh

## Notes

- The app auto-ensures the daemon service is installed/running on startup.
- If hotkey capture or autopaste fails, grant Accessibility and Microphone permissions in macOS settings.
