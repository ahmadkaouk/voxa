#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/.build/standalone-checks"
SUITES=(hotkeys output sounds recorder pipeline)

usage() {
  echo 'Usage: test.sh [all|hotkeys|output|sounds|recorder|pipeline] [--live]'
  echo 'Runs standalone checks without XCTest. --live is only valid with output.'
}

SUITE="${1:-all}"
case "$SUITE" in
  -h|--help) usage; exit 0 ;;
  all|hotkeys|output|sounds|recorder|pipeline) ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && { [ "$SUITE" != output ] || [ "$2" != --live ]; }; }; then
  usage >&2
  exit 2
fi

compile() {
  local executable="$1"
  shift
  mkdir -p "$(dirname "$executable")"
  swiftc -parse-as-library -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/module-cache" "$@" -o "$executable"
}

run_suite() {
  local suite="$1"
  local executable="$BUILD_DIR/$suite-checks"
  local -a flags=(-D VOXA_STANDALONE_TESTS)
  local -a files=()
  case "$suite" in
    hotkeys)
      flags+=(-D VOXA_UNIT_TEST_RUNNER)
      files=(Sources/Voxa/Hotkeys.swift Tests/VoxaTests/UnitChecksSupport.swift
        Tests/VoxaTests/HotkeyOptionTests.swift)
      ;;
    output)
      files=(Sources/Voxa/ClipboardPaste.swift Tests/VoxaTests/TranscriptOutputTests.swift)
      ;;
    sounds)
      local app_dir="$BUILD_DIR/SoundChecks.app"
      executable="$app_dir/Contents/MacOS/SoundChecks"
      mkdir -p "$app_dir/Contents/Resources"
      cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SoundChecks</string>
<key>CFBundleIdentifier</key><string>com.voxa.sound-checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
      ditto Sources/Voxa/Resources/Sounds "$app_dir/Contents/Resources/Sounds"
      files=(Sources/Voxa/DictationSounds.swift Tests/VoxaTests/DictationSoundTests.swift)
      ;;
    recorder)
      files=(Sources/Voxa/AudioCaptureDevice.swift Sources/Voxa/AudioWAVEncoder.swift
        Sources/Voxa/AudioRecorder.swift Tests/VoxaTests/UnitChecksSupport.swift
        Tests/VoxaTests/AudioRecorderTests.swift)
      ;;
    pipeline)
      flags+=(-D VOXA_PIPELINE_TEST_RUNNER)
      files=(Sources/Voxa/Models.swift Sources/Voxa/AudioCaptureDevice.swift
        Sources/Voxa/AudioWAVEncoder.swift Sources/Voxa/AudioRecorder.swift
        Sources/Voxa/TranscriptionClient.swift Sources/Voxa/TranscriptOutput.swift
        Sources/Voxa/ClipboardPaste.swift Sources/Voxa/DictationSession.swift
        Sources/Voxa/DictationTiming.swift Sources/Voxa/Hotkeys.swift Sources/Voxa/GlobalHotkeys.swift
        Sources/Voxa/Preferences.swift Sources/Voxa/Keychain.swift Sources/Voxa/CaptureGuard.swift
        Sources/Voxa/TextContext.swift
        Sources/Voxa/EnglishFeedback.swift Sources/Voxa/FeedbackClient.swift
        Sources/Voxa/FeedbackController.swift Sources/Voxa/CorrectionStore.swift
        Sources/Voxa/LearningAssessment.swift Sources/Voxa/LearningProgress.swift
        Sources/Voxa/ExpressionAssessment.swift Sources/Voxa/Practice.swift
        Sources/Voxa/PracticeHistory.swift Sources/Voxa/PracticeController.swift
        Tests/VoxaTests/NativeSetupTests.swift Tests/VoxaTests/UnitChecksSupport.swift
        Tests/VoxaTests/NativePipelineChecksSupport.swift Tests/VoxaTests/DictationSessionTests.swift
        Tests/VoxaTests/TranscriptionClientTests.swift Tests/VoxaTests/AsyncTranscriptOutputTests.swift
        Tests/VoxaTests/FeedbackTests.swift Tests/VoxaTests/LearningFeaturesTests.swift
        Tests/VoxaTests/TextContextTests.swift)
      ;;
  esac
  echo "Running $suite checks..."
  compile "$executable" "${flags[@]}" "${files[@]}"
  "$executable"
}

if [ "$SUITE" = all ]; then
  # Refuse to silently skip a new test file in the Command Line Tools fallback.
  for test_file in Tests/VoxaTests/*Tests.swift; do
    case "${test_file##*/}" in
      HotkeyOptionTests.swift|TranscriptOutputTests.swift|DictationSoundTests.swift|AudioRecorderTests.swift) ;;
      DictationSessionTests.swift|TranscriptionClientTests.swift|AsyncTranscriptOutputTests.swift|NativeSetupTests.swift|FeedbackTests.swift|LearningFeaturesTests.swift|TextContextTests.swift) ;;
      *) echo "No standalone harness registered for $test_file; use XCTest or add coverage." >&2; exit 1 ;;
    esac
  done
  for suite in "${SUITES[@]}"; do run_suite "$suite"; done
else
  run_suite "$SUITE"
fi

if [ "${2:-}" = --live ]; then
  compile "$BUILD_DIR/live-paste-check" Sources/Voxa/ClipboardPaste.swift scripts/preview/LivePasteCheck.swift
  "$BUILD_DIR/live-paste-check"
fi
