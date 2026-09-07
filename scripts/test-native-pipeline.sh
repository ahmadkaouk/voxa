#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/pipeline-checks"
SOURCE_DIR="$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar"
TEST_DIR="$ROOT_DIR/apps/voxa-menubar/Tests/VoxaMenuBarTests"
mkdir -p "$BUILD_DIR"
swift build --package-path "$ROOT_DIR/apps/voxa-menubar" --target TOMLDecoder
PACKAGE_BIN_DIR="$(swift build --package-path "$ROOT_DIR/apps/voxa-menubar" --show-bin-path)"
TOML_OBJECTS=("$PACKAGE_BIN_DIR"/TOMLDecoder.build/*.o)
swiftc -parse-as-library -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
  -D VOXA_STANDALONE_TESTS -D VOXA_PIPELINE_TEST_RUNNER \
  -I "$PACKAGE_BIN_DIR/Modules" "${TOML_OBJECTS[@]}" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/Models.swift" "$SOURCE_DIR/AudioCaptureDevice.swift" \
  "$SOURCE_DIR/AudioWAVEncoder.swift" "$SOURCE_DIR/AudioRecorder.swift" \
  "$SOURCE_DIR/TranscriptionClient.swift" "$SOURCE_DIR/TranscriptOutput.swift" \
  "$SOURCE_DIR/ClipboardPaste.swift" "$SOURCE_DIR/DictationSession.swift" \
  "$SOURCE_DIR/Hotkeys.swift" "$SOURCE_DIR/Preferences.swift" "$SOURCE_DIR/Keychain.swift" \
  "$TEST_DIR/NativeSetupTests.swift" \
  "$TEST_DIR/UnitChecksSupport.swift" "$TEST_DIR/NativePipelineChecksSupport.swift" \
  "$TEST_DIR/DictationSessionTests.swift" "$TEST_DIR/TranscriptionClientTests.swift" \
  "$TEST_DIR/AsyncTranscriptOutputTests.swift" \
  -o "$BUILD_DIR/pipeline-checks"
"$BUILD_DIR/pipeline-checks"
