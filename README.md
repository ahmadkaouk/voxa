# voico

Local macOS dictation app with a Swift menu bar client and a Rust daemon.

## Workspace

- `apps/voico-menubar`: Swift menu bar app
- `crates/voico-daemon`: daemon runtime
- `crates/voicoctl`: optional IPC troubleshooting client
- `crates/voico-core`: shared backend/domain logic

## Prerequisites

- macOS
- Rust toolchain
- Swift 5.9+ / Xcode command line tools

## Install

Build a distributable macOS app bundle and disk image:

```bash
./scripts/package-macos.sh
```

This produces:

- `dist/Voico.app`
- `dist/Voico.dmg`

The app bundle embeds `voico-daemon`, and the menu bar app will install or update a per-user LaunchAgent that points at the bundled daemon.

## Developer Install

Install the daemon and control CLI:

```bash
./scripts/install.sh
```

This installs:

- `voico-daemon`
- `voicoctl`

## Run

Run the menu bar app:

```bash
cd apps/voico-menubar
swift run voico-menubar
```

The menu bar app will install or update a per-user LaunchAgent for `voico-daemon` and connect over local IPC.

## Quick Checks

```bash
./scripts/check.sh
```

## Notes

- IPC socket: `~/Library/Application Support/voico/run/daemon.sock`
- Config path: `~/Library/Application Support/voico/config.toml`
- The menu bar app manages the daemon lifecycle through `launchd`
- Autopaste may require macOS Accessibility permission for the menu bar app process
