#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cargo install --path crates/voico-daemon --force
cargo install --path crates/voicoctl --force

DAEMON_BIN="$(command -v voico-daemon || true)"
if [ -z "$DAEMON_BIN" ] && [ -x "$HOME/.cargo/bin/voico-daemon" ]; then
  DAEMON_BIN="$HOME/.cargo/bin/voico-daemon"
fi

CTL_BIN="$(command -v voicoctl || true)"
if [ -z "$CTL_BIN" ] && [ -x "$HOME/.cargo/bin/voicoctl" ]; then
  CTL_BIN="$HOME/.cargo/bin/voicoctl"
fi

if [ -n "$DAEMON_BIN" ]; then
  echo "Installed daemon: $DAEMON_BIN"
fi

if [ -n "$CTL_BIN" ]; then
  "$CTL_BIN" --help >/dev/null
  echo "Installed control CLI: $CTL_BIN"
fi

echo "Run the menu bar app with:"
echo "  cd apps/voico-menubar && swift run voico-menubar"
echo
echo "Build a distributable app bundle with:"
echo "  ./scripts/package-macos.sh"
