#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/output-checks"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors -D VOXA_STANDALONE_TESTS \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar/Models.swift" \
  "$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar/TranscriptOutput.swift" \
  "$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar/ClipboardPaste.swift" \
  "$ROOT_DIR/apps/voxa-menubar/Tests/VoxaMenuBarTests/TranscriptOutputTests.swift" \
  -o "$BUILD_DIR/output-checks"
"$BUILD_DIR/output-checks"

if [ "${1:-}" = "--live" ]; then
  swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar/ClipboardPaste.swift" \
    "$ROOT_DIR/scripts/preview/LivePasteCheck.swift" \
    -o "$BUILD_DIR/live-paste-check"
  "$BUILD_DIR/live-paste-check"
fi
