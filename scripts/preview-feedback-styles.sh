#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/apps.noindex/Voxa Feedback Preview.app"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.0" \
  -module-cache-path "$ROOT_DIR/.build/preview-module-cache" \
  "$ROOT_DIR/scripts/preview/FeedbackStylesPreview.swift" \
  -o "$APP_DIR/Contents/MacOS/VoxaFeedbackPreview"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoxaFeedbackPreview</string>
<key>CFBundleIdentifier</key><string>com.voxa.feedback-styles-preview</string>
<key>CFBundleName</key><string>Voxa Feedback Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
printf 'Built preview: %s\n' "$APP_DIR"
