#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${1:?Usage: verify-native-bundle.sh /path/to/Voxa.app}"
INFO="$APP_DIR/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = 'com.voxa.menubar' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")" = 'Voxa' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" = '13.0' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO")" = 'true' ]
[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$INFO")" ]
[ -x "$APP_DIR/Contents/MacOS/Voxa" ]
[ -s "$APP_DIR/Contents/Resources/Voxa.icns" ]
[ -s "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt" ]
[ -d "$APP_DIR/Contents/Resources/Sounds/Zen" ]
[ ! -e "$APP_DIR/Contents/Resources/bin" ]
# The final product has one executable. Inspect all files, including nested helper bundles.
MACHO_COUNT=0
while IFS= read -r -d '' path; do
  case "$(file -b "$path")" in
    *Mach-O*)
      [ "$path" = "$APP_DIR/Contents/MacOS/Voxa" ]
      MACHO_COUNT=$((MACHO_COUNT + 1))
      ;;
  esac
done < <(find "$APP_DIR/Contents" -type f -print0)
[ "$MACHO_COUNT" -eq 1 ]
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo 'Native bundle verified: one executable, required resources, macOS 13 identity and valid signature.'
