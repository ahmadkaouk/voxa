# Voico Daemon Mode

`voico daemon` runs a background-ready loop that listens for a global hotkey.

## Behavior

- Hotkey is toggle-based:
  - first trigger: start recording
  - second trigger: stop recording and transcribe
- If max duration is reached, recording stops automatically and transcription continues.

## Config

Config file path:

```text
~/Library/Application Support/voico/config.toml
```

Supported keys:

```toml
hotkey = "right_option" # right_option | cmd_space | fn
output = "clipboard"    # clipboard | autopaste
```

CLI helpers:

```bash
voico config show
voico config set hotkey right_option
voico config set output autopaste
```

## Output Modes

- `clipboard`: copy transcript to clipboard
- `autopaste`: copy to clipboard, then send `Cmd+V` using AppleScript

## LaunchAgent

Install/remove/status:

```bash
voico service install
voico service status
voico service uninstall
```

LaunchAgent label:

```text
com.voico.daemon
```

## macOS Permissions

For global hotkeys and auto-paste, macOS may require Accessibility permission for the running process (`voico` or the hosting terminal).
