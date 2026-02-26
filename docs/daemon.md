# Voico Daemon Mode

`voico daemon` runs a background-ready loop that listens for two global hotkeys.

## Behavior

- Toggle hotkey:
  - press while idle: start recording
  - press while recording: stop recording and transcribe
- Hold hotkey:
  - press while idle: start recording
  - release: stop recording only if the session started from hold
- Toggle hotkey can stop any active recording session.
- If the 5-minute recording cap is reached, recording stops automatically and transcription continues.

## Config

Config file path:

```text
~/Library/Application Support/voico/config.toml
```

Supported keys:

```toml
toggle_hotkey = "right_option" # right_option | cmd_space | fn
hold_hotkey = "fn"             # right_option | cmd_space | fn
```

CLI helpers:

```bash
voico config show
voico config set toggle-hotkey right_option
voico config set hold-hotkey fn
```

## Output Behavior

- Daemon always copies transcript to clipboard.
- Daemon then attempts to auto-paste with `Cmd+V`.

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
