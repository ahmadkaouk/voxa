#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/output-checks"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors -D VOXA_STANDALONE_TESTS \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/Sources/Voxa/ClipboardPaste.swift" \
  "$ROOT_DIR/Tests/VoxaTests/TranscriptOutputTests.swift" \
  -o "$BUILD_DIR/output-checks"
"$BUILD_DIR/output-checks"

if [ "${1:-}" = "--live" ]; then
  swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$ROOT_DIR/Sources/Voxa/ClipboardPaste.swift" \
    "$ROOT_DIR/scripts/preview/LivePasteCheck.swift" \
    -o "$BUILD_DIR/live-paste-check"
  "$BUILD_DIR/live-paste-check"
fi
