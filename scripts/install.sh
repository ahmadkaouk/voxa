#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cargo install --path . --force

VOICO_BIN="$(command -v voico || true)"
if [ -z "$VOICO_BIN" ] && [ -x "$HOME/.cargo/bin/voico" ]; then
  VOICO_BIN="$HOME/.cargo/bin/voico"
fi

if [ -n "$VOICO_BIN" ]; then
  "$VOICO_BIN" --help >/dev/null
  echo "Installed and verified: $VOICO_BIN"
else
  echo "Installed, but 'voico' was not found on PATH."
  echo "Add '$HOME/.cargo/bin' to your PATH and run: voico --help"
fi
