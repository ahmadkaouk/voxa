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

Run in toggle mode:

```bash
voico toggle
```

Run in hold mode:

```bash
voico hold
```

## Background Mode (Global Hotkey)

Show daemon config:

```bash
voico config show
```

Set global hotkey:

```bash
voico config set hotkey right_option
# or: cmd_space, fn
```

Set output mode:

```bash
voico config set output clipboard
# or: autopaste
```

Set input mode:

```bash
voico config set mode toggle
# or: hold
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
- Daemon hotkey acts as toggle: press once to start recording, press again to stop and transcribe.
- `autopaste` copies transcript then sends `Cmd+V`.
- macOS may require Accessibility permission for global hotkey capture and auto-paste.

## Menu Bar App (MVP)

A thin native macOS menu bar controller is available at:

```text
apps/voico-menubar
```

Run it:

```bash
cd apps/voico-menubar
swift run
```

It controls the existing backend using `voico service ...` and `voico config ...`, including:
- start/stop/reinstall service
- hotkey, mode, and output changes
- API key save with `launchctl setenv`
- log opening and refresh
