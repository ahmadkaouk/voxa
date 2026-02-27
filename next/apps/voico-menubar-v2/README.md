# voico-menubar-v2

Greenfield Swift menu bar client for Voico v2.

## What it does

- Connects to `voico-daemon` over IPC (`~/Library/Application Support/voico-v2/run/daemon.sock`).
- Performs protocol handshake (`api_version = 1.0`).
- Resyncs state via `get_state` on connect/reconnect.
- Resyncs config via `get_config` and updates config via `set_config`.
- Reads API key status via `get_api_key_status` and saves key via `set_api_key`.
- Subscribes to daemon events via `subscribe` and updates UI from events.
- Drives listening/transcribing animation from daemon runtime state (`recording`, `transcribing`).
- Captures global hotkeys in the menubar process and forwards start/stop commands via IPC.
- Handles transcript output in the menubar process (clipboard / clipboard+autopaste / none).
- Auto-installs/updates a per-user LaunchAgent for `voico-daemon` and starts it on app launch.
- Uses LaunchAgent lifecycle control (`bootstrap`, `kickstart`, `bootout`) for daemon management.
- Exposes daemon lifecycle actions (`start`/`stop`) from the menu.

## Run

```bash
cd next/apps/voico-menubar-v2
swift run voico-menubar-v2
```

## Notes

- This app does not parse daemon logs.
- This app does not shell out to CLI for runtime state.
- Automatic reconnect backoff: `200ms`, `500ms`, `1s`, `2s`, `5s`.
- Autopaste (`Cmd+V`) may require macOS Accessibility permission for the menubar app process.
