#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cargo install --path crates/voxa-daemon --force
cargo install --path crates/voxactl --force

DAEMON_BIN="$(command -v voxa-daemon || true)"
if [ -z "$DAEMON_BIN" ] && [ -x "$HOME/.cargo/bin/voxa-daemon" ]; then
  DAEMON_BIN="$HOME/.cargo/bin/voxa-daemon"
fi

CTL_BIN="$(command -v voxactl || true)"
if [ -z "$CTL_BIN" ] && [ -x "$HOME/.cargo/bin/voxactl" ]; then
  CTL_BIN="$HOME/.cargo/bin/voxactl"
fi

if [ -n "$DAEMON_BIN" ]; then
  echo "Installed daemon: $DAEMON_BIN"
fi

if [ -n "$CTL_BIN" ]; then
  "$CTL_BIN" --help >/dev/null
  echo "Installed control CLI: $CTL_BIN"
fi

echo "Run the menu bar app with:"
echo "  cd apps/voxa-menubar && swift run voxa-menubar"
echo
echo "Build a distributable app bundle with:"
echo "  ./scripts/package-macos.sh"
