# voico

Local macOS voice-to-text CLI.

## Prerequisites

- macOS terminal environment
- Rust toolchain (Cargo)

## Install

Recommended:

```bash
./scripts/install.sh
```

Direct Cargo install:

```bash
cargo install --path . --force
```

If `voico` is not found after install, add Cargo bin to your PATH:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
```

## Verify Install

```bash
voico --help
```

## Usage

Set your OpenAI API key:

```bash
export OPENAI_API_KEY="your_api_key"
```

## Hotkey Mode (Daemon)

Show daemon config:

```bash
voico config show
```

Set toggle hotkey:

```bash
voico config set toggle-hotkey right_option
# or: cmd_space, fn
```

Set hold hotkey:

```bash
voico config set hold-hotkey fn
# or: right_option, cmd_space
```

Run daemon in foreground:

```bash
voico daemon
```

Install as macOS LaunchAgent:

```bash
voico service install
voico service status
```

Remove service:

```bash
voico service uninstall
```

Notes:
- Toggle hotkey: press once to start recording, press again to stop and transcribe.
- Hold hotkey: press to start recording, release to stop and transcribe.
- Daemon always copies transcript to clipboard, then sends `Cmd+V` (auto-paste).
- macOS may require Accessibility permission for global hotkey capture and auto-paste.

## Menu Bar App

A native macOS menu bar controller is available at:

```text
next/apps/voico-menubar-v2
```

Run it:

```bash
cd next/apps/voico-menubar-v2
swift run voico-menubar-v2
```

It talks to the daemon over local IPC, including:
- recording controls
- toggle/hold hotkey changes
- model/output/max-duration config
- OpenAI API key management
- daemon reconnect and status
