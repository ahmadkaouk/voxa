#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/unit-checks"
SOURCE_DIR="$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar"
TEST_DIR="$ROOT_DIR/apps/voxa-menubar/Tests/VoxaMenuBarTests"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors \
  -D VOXA_STANDALONE_TESTS -D VOXA_UNIT_TEST_RUNNER \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/Hotkeys.swift" \
  "$TEST_DIR/UnitChecksSupport.swift" "$TEST_DIR/HotkeyOptionTests.swift" \
  -o "$BUILD_DIR/unit-checks"
"$BUILD_DIR/unit-checks"
