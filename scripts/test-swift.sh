#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/apps/voxa-menubar"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required to validate the macOS application." >&2
  exit 1
fi

swift build --package-path "$PACKAGE_DIR"
if command -v xcrun >/dev/null 2>&1 && xcrun --find xctest >/dev/null 2>&1; then
  SWIFT_TEST_LIST="$(swift test --package-path "$PACKAGE_DIR" list 2>&1)"
  if ! printf '%s\n' "$SWIFT_TEST_LIST" | grep -Eq '^VoxaMenuBarTests[./]'; then
    printf '%s\n' "$SWIFT_TEST_LIST" >&2
    echo "Swift test discovery found no VoxaMenuBarTests; refusing a false-green check." >&2
    exit 1
  fi
  swift test --package-path "$PACKAGE_DIR"
else
  echo "XCTest unavailable: running the same assertions with the Command Line Tools harnesses."
  for test_file in "$PACKAGE_DIR"/Tests/VoxaMenuBarTests/*Tests.swift; do
    case "$(basename "$test_file")" in
      HotkeyOptionTests.swift|IPCClientTests.swift|PopoverPrimaryActionTests.swift|TranscriptOutputTests.swift|DictationSoundTests.swift|AudioRecorderTests.swift) ;;
      DictationSessionTests.swift|TranscriptionClientTests.swift|AsyncTranscriptOutputTests.swift) ;;
      *) echo "No standalone harness registered for $test_file; use XCTest or add coverage." >&2; exit 1 ;;
    esac
  done
  "$ROOT_DIR/scripts/test-swift-unit.sh"
  "$ROOT_DIR/scripts/test-transcript-output.sh"
  "$ROOT_DIR/scripts/test-dictation-sounds.sh"
  "$ROOT_DIR/scripts/test-audio-recorder.sh"
  "$ROOT_DIR/scripts/test-native-pipeline.sh"
fi
