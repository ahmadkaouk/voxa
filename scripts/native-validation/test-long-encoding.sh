#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="${1:?Usage: test-long-encoding.sh /path/to/report.json}"
SOURCE_DIR="$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/long-encoding"
mkdir -p "$BUILD_DIR"
swiftc -O -parse-as-library -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/AudioCaptureDevice.swift" "$SOURCE_DIR/AudioWAVEncoder.swift" "$SOURCE_DIR/AudioRecorder.swift" \
  "$ROOT_DIR/scripts/native-validation/LongEncoding.swift" -o "$BUILD_DIR/long-encoding"
"$BUILD_DIR/long-encoding" "$OUTPUT"
