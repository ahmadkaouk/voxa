#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/apps.noindex/Voxa Recorder Preview.app"
SOURCE_DIR="$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoxaRecorderPreview</string>
<key>CFBundleIdentifier</key><string>com.voxa.recorder-preview</string>
<key>CFBundleName</key><string>Voxa Recorder Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSMicrophoneUsageDescription</key><string>Test native Voxa recording and local playback. Audio is not uploaded.</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
swiftc -parse-as-library -O -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$ROOT_DIR/apps/voxa-menubar/.build/preview-module-cache" \
  "$SOURCE_DIR/AudioCaptureDevice.swift" "$SOURCE_DIR/AudioWAVEncoder.swift" "$SOURCE_DIR/AudioRecorder.swift" \
  "$ROOT_DIR/scripts/preview/RecorderPreview.swift" \
  -o "$APP_DIR/Contents/MacOS/VoxaRecorderPreview"
codesign --force --sign "${VOXA_CODESIGN_IDENTITY:--}" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built preview: %s\n' "$APP_DIR"
