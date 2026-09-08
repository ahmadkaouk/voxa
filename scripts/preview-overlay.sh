#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/apps.noindex/Voxa Overlay Preview.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto "$ROOT_DIR/Sources/Voxa/Resources/Sounds" "$APP_DIR/Contents/Resources/Sounds"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoxaOverlayPreview</string>
<key>CFBundleIdentifier</key><string>com.voxa.overlay-preview</string>
<key>CFBundleName</key><string>Voxa Overlay Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
swiftc -parse-as-library -module-cache-path "$ROOT_DIR/.build/preview-module-cache" \
  "$ROOT_DIR/Sources/Voxa/ActivityOverlay.swift" \
  "$ROOT_DIR/Sources/Voxa/DictationSounds.swift" \
  "$ROOT_DIR/scripts/preview/OverlayPreview.swift" \
  -o "$APP_DIR/Contents/MacOS/VoxaOverlayPreview"
printf 'Built preview: %s\n' "$APP_DIR"
