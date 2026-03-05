#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE_DIR="$ROOT_DIR/apps/voxa-menubar"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/build"
STAGE_DIR="$DIST_DIR/dmg"
APP_NAME="Voxa"
APP_DIR="$DIST_DIR/$APP_NAME.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$APP_NAME"
APP_RESOURCES_DIR="$APP_DIR/Contents/Resources"
DAEMON_BUNDLE_PATH="$APP_RESOURCES_DIR/bin/voxa-daemon"
ICON_SOURCE="$ROOT_DIR/apps/voxa-menubar/Resources/VoxaIcon.svg"
ICONSET_DIR="$BUILD_DIR/Voxa.iconset"
ICON_PATH="$APP_RESOURCES_DIR/Voxa.icns"
INFO_PLIST_PATH="$APP_DIR/Contents/Info.plist"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DAEMON_BIN="$ROOT_DIR/target/release/voxa-daemon"

rm -rf "$BUILD_DIR" "$STAGE_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR"

echo "Building release daemon..."
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p voxa-daemon --release

echo "Building release menu bar app..."
swift build --package-path "$APP_PACKAGE_DIR" --configuration release --product voxa-menubar
MENU_BAR_BIN_DIR="$(swift build --package-path "$APP_PACKAGE_DIR" --configuration release --show-bin-path)"
MENU_BAR_BIN="$MENU_BAR_BIN_DIR/voxa-menubar"

if [ ! -x "$MENU_BAR_BIN" ]; then
  echo "Missing built app executable: $MENU_BAR_BIN" >&2
  exit 1
fi

if [ ! -x "$DAEMON_BIN" ]; then
  echo "Missing built daemon executable: $DAEMON_BIN" >&2
  exit 1
fi

if [ ! -f "$ICON_SOURCE" ]; then
  echo "Missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_RESOURCES_DIR/bin" "$ICONSET_DIR"

sips -s format png "$ICON_SOURCE" --out "$BUILD_DIR/icon_1024x1024.png" >/dev/null
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$BUILD_DIR/icon_1024x1024.png" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256; do
  doubled=$((size * 2))
  cp "$ICONSET_DIR/icon_${doubled}x${doubled}.png" "$ICONSET_DIR/icon_${size}x${size}@2x.png"
done
cp "$BUILD_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_PATH"

cp "$MENU_BAR_BIN" "$APP_EXECUTABLE"
cp "$DAEMON_BIN" "$DAEMON_BUNDLE_PATH"
chmod +x "$APP_EXECUTABLE" "$DAEMON_BUNDLE_PATH"

cat > "$INFO_PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Voxa</string>
  <key>CFBundleIdentifier</key>
  <string>com.voxa.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>Voxa</string>
  <key>CFBundleName</key>
  <string>Voxa</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Voxa records audio for transcription.</string>
</dict>
</plist>
EOF

cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Built app bundle: $APP_DIR"
echo "Built disk image: $DMG_PATH"
