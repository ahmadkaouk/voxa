#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/sound-checks"
APP_DIR="$BUILD_DIR/SoundChecks.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SoundChecks</string>
<key>CFBundleIdentifier</key><string>com.voxa.sound-checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
ditto "$ROOT_DIR/Sources/VoxaMenuBar/Resources/Sounds" "$APP_DIR/Contents/Resources/Sounds"
swiftc -parse-as-library -warnings-as-errors -D VOXA_STANDALONE_TESTS \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/Sources/VoxaMenuBar/DictationSounds.swift" \
  "$ROOT_DIR/Tests/VoxaMenuBarTests/DictationSoundTests.swift" \
  -o "$APP_DIR/Contents/MacOS/SoundChecks"
"$APP_DIR/Contents/MacOS/SoundChecks"
