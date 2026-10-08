#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/island-gallery/Voxa Island Gallery.app"
mkdir -p "$APP_DIR/Contents/MacOS"
sources=()
for source in "$ROOT_DIR"/Sources/Voxa/*.swift; do
  case "${source##*/}" in VoxaApp.swift) ;; *) sources+=("$source") ;; esac
done
swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$ROOT_DIR/.build/preview-module-cache" \
  "${sources[@]}" "$ROOT_DIR/scripts/preview/IslandPreview.swift" \
  -o "$APP_DIR/Contents/MacOS/IslandGallery"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IslandGallery</string>
<key>CFBundleIdentifier</key><string>com.voxa.island-gallery</string>
<key>CFBundleName</key><string>Voxa Island Gallery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
"$APP_DIR/Contents/MacOS/IslandGallery" --validate-fixtures
printf 'Preview ready: %s\n' "$APP_DIR"
