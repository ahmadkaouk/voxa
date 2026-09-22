#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required to validate the macOS application." >&2
  exit 1
fi

# Match packaging so CLT 27 records the actual SDK version in the executable.
swift build --build-system native --package-path "$ROOT_DIR"
if command -v xcrun >/dev/null 2>&1 && xcrun --find xctest >/dev/null 2>&1; then
  SWIFT_TEST_LIST="$(swift test --build-system native --package-path "$ROOT_DIR" list 2>&1)"
  if ! printf '%s\n' "$SWIFT_TEST_LIST" | grep -Eq '^VoxaTests[./]'; then
    printf '%s\n' "$SWIFT_TEST_LIST" >&2
    echo "Swift test discovery found no VoxaTests; refusing a false-green check." >&2
    exit 1
  fi
  swift test --build-system native --package-path "$ROOT_DIR"
else
  echo "XCTest unavailable: running the same assertions with the Command Line Tools harnesses."
  "$ROOT_DIR/scripts/test.sh"
fi
