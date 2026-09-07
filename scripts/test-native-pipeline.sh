#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/pipeline-checks"
SOURCE_DIR="$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar"
TEST_DIR="$ROOT_DIR/apps/voxa-menubar/Tests/VoxaMenuBarTests"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
  -D VOXA_STANDALONE_TESTS -D VOXA_PIPELINE_TEST_RUNNER \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/Models.swift" "$SOURCE_DIR/AudioCaptureDevice.swift" \
  "$SOURCE_DIR/AudioWAVEncoder.swift" "$SOURCE_DIR/AudioRecorder.swift" \
  "$SOURCE_DIR/TranscriptionClient.swift" "$SOURCE_DIR/TranscriptOutput.swift" \
  "$SOURCE_DIR/ClipboardPaste.swift" "$SOURCE_DIR/DictationSession.swift" \
  "$TEST_DIR/UnitChecksSupport.swift" "$TEST_DIR/NativePipelineChecksSupport.swift" \
  "$TEST_DIR/DictationSessionTests.swift" "$TEST_DIR/TranscriptionClientTests.swift" \
  "$TEST_DIR/AsyncTranscriptOutputTests.swift" \
  -o "$BUILD_DIR/pipeline-checks"
"$BUILD_DIR/pipeline-checks"
