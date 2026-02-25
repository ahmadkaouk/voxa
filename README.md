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
