#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cargo fmt --all -- --check
cargo check --workspace
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace

if command -v swift >/dev/null 2>&1 \
  && command -v xcrun >/dev/null 2>&1 \
  && xcrun --find xctest >/dev/null 2>&1; then
  SWIFT_TEST_LIST="$(swift test --package-path apps/voxa-menubar --list-tests 2>&1)"
  if ! printf '%s\n' "$SWIFT_TEST_LIST" | grep -Eq '^VoxaMenuBarTests\.'; then
    printf '%s\n' "$SWIFT_TEST_LIST" >&2
    echo "Swift test discovery found no VoxaMenuBarTests; refusing a false-green check." >&2
    exit 1
  fi
  swift test --package-path apps/voxa-menubar
else
  echo "Skipping Swift tests: a usable XCTest runner was not found."
  if [ "$(uname -s)" = "Darwin" ] && command -v swiftc >/dev/null 2>&1; then
    ./scripts/test-transcript-output.sh
    ./scripts/test-dictation-sounds.sh
  fi
fi
