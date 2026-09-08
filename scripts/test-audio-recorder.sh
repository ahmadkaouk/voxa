#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/recorder-checks"
SOURCE_DIR="$ROOT_DIR/Sources/Voxa"
TEST_DIR="$ROOT_DIR/Tests/VoxaTests"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors -D VOXA_STANDALONE_TESTS \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/AudioCaptureDevice.swift" "$SOURCE_DIR/AudioWAVEncoder.swift" "$SOURCE_DIR/AudioRecorder.swift" \
  "$TEST_DIR/UnitChecksSupport.swift" "$TEST_DIR/AudioRecorderTests.swift" \
  -o "$BUILD_DIR/recorder-checks"
"$BUILD_DIR/recorder-checks"
