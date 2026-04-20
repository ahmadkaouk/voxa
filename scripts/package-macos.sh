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
LOCAL_CODESIGN_DIR="${VOXA_CODESIGN_DIR:-$HOME/Library/Application Support/Voxa/codesign}"
LOCAL_CODESIGN_KEYCHAIN="$LOCAL_CODESIGN_DIR/voxa-local-development.keychain-db"
LOCAL_CODESIGN_PASSWORD_FILE="$LOCAL_CODESIGN_DIR/keychain-password"
LOCAL_CODESIGN_CERT_NAME="${VOXA_CODESIGN_CERT_NAME:-Voxa Local Development}"

CODESIGN_IDENTITY="${VOXA_CODESIGN_IDENTITY:-}"
CODESIGN_KEYCHAIN_PATH=""
LOCAL_CODESIGN_TEMP_DIR=""
USE_LOCAL_CODESIGN_KEYCHAIN=0
LOCAL_CODESIGN_KEYCHAIN_PASSWORD=""
ORIGINAL_KEYCHAINS=()

cleanup() {
  local exit_code=$?

  if [ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi

  if [ -n "$LOCAL_CODESIGN_TEMP_DIR" ] && [ -d "$LOCAL_CODESIGN_TEMP_DIR" ]; then
    rm -rf "$LOCAL_CODESIGN_TEMP_DIR"
  fi

  exit "$exit_code"
}

trap cleanup EXIT

trim_keychain_path() {
  local keychain_path="$1"

  keychain_path="${keychain_path#"${keychain_path%%[![:space:]]*}"}"
  keychain_path="${keychain_path%"${keychain_path##*[![:space:]]}"}"
  keychain_path="${keychain_path#\"}"
  keychain_path="${keychain_path%\"}"

  printf '%s\n' "$keychain_path"
}

remember_keychain_search_list() {
  if [ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]; then
    return
  fi

  while IFS= read -r raw_keychain; do
    local keychain
    keychain="$(trim_keychain_path "$raw_keychain")"
    if [ -n "$keychain" ]; then
      ORIGINAL_KEYCHAINS+=("$keychain")
    fi
  done < <(security list-keychains -d user)
}

load_or_create_local_codesign_password() {
  mkdir -p "$LOCAL_CODESIGN_DIR"

  if [ ! -f "$LOCAL_CODESIGN_PASSWORD_FILE" ]; then
    openssl rand -hex 24 > "$LOCAL_CODESIGN_PASSWORD_FILE"
    chmod 600 "$LOCAL_CODESIGN_PASSWORD_FILE"
  fi

  LOCAL_CODESIGN_KEYCHAIN_PASSWORD="$(cat "$LOCAL_CODESIGN_PASSWORD_FILE")"
}

local_codesign_identity_exists() {
  [ -f "$LOCAL_CODESIGN_KEYCHAIN" ] \
    && security find-identity -v -p codesigning "$LOCAL_CODESIGN_KEYCHAIN" 2>/dev/null \
      | grep -F "\"$LOCAL_CODESIGN_CERT_NAME\"" >/dev/null
}

create_local_codesign_identity() {
  load_or_create_local_codesign_password
  mkdir -p "$LOCAL_CODESIGN_DIR"

  if [ -f "$LOCAL_CODESIGN_KEYCHAIN" ]; then
    rm -f "$LOCAL_CODESIGN_KEYCHAIN"
  fi

  LOCAL_CODESIGN_TEMP_DIR="$(mktemp -d)"

  local config_path="$LOCAL_CODESIGN_TEMP_DIR/openssl-codesign.cnf"
  local cert_path="$LOCAL_CODESIGN_TEMP_DIR/cert.pem"
  local key_path="$LOCAL_CODESIGN_TEMP_DIR/key.pem"
  local p12_path="$LOCAL_CODESIGN_TEMP_DIR/cert.p12"
  local p12_password

  p12_password="$(openssl rand -hex 24)"

  cat > "$config_path" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[ dn ]
CN = $LOCAL_CODESIGN_CERT_NAME

[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -x509 \
    -days 3650 \
    -config "$config_path" \
    -keyout "$key_path" \
    -out "$cert_path" >/dev/null 2>&1

  openssl pkcs12 \
    -export \
    -inkey "$key_path" \
    -in "$cert_path" \
    -out "$p12_path" \
    -passout pass:"$p12_password" >/dev/null 2>&1

  security create-keychain -p "$LOCAL_CODESIGN_KEYCHAIN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null
  security unlock-keychain -p "$LOCAL_CODESIGN_KEYCHAIN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null
  security import "$p12_path" \
    -k "$LOCAL_CODESIGN_KEYCHAIN" \
    -P "$p12_password" \
    -f pkcs12 \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$LOCAL_CODESIGN_KEYCHAIN_PASSWORD" \
    "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null
  security add-trusted-cert -d -r trustRoot -k "$LOCAL_CODESIGN_KEYCHAIN" "$cert_path" >/dev/null

  if ! local_codesign_identity_exists; then
    echo "Failed to create local Voxa code-signing identity" >&2
    exit 1
  fi
}

activate_local_codesign_keychain() {
  remember_keychain_search_list
  load_or_create_local_codesign_password
  security unlock-keychain -p "$LOCAL_CODESIGN_KEYCHAIN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$LOCAL_CODESIGN_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}" >/dev/null
}

resolve_codesign_identity() {
  if [ -n "$CODESIGN_IDENTITY" ]; then
    return
  fi

  local preferred_identity
  preferred_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development[^"]*\|Developer ID Application:[^"]*\)".*/\1/p' \
      | head -n 1
  )"

  if [ -n "$preferred_identity" ]; then
    CODESIGN_IDENTITY="$preferred_identity"
    return
  fi

  if ! local_codesign_identity_exists; then
    echo "Creating local code-signing identity: $LOCAL_CODESIGN_CERT_NAME"
    create_local_codesign_identity
  fi

  CODESIGN_IDENTITY="$LOCAL_CODESIGN_CERT_NAME"
  CODESIGN_KEYCHAIN_PATH="$LOCAL_CODESIGN_KEYCHAIN"
  USE_LOCAL_CODESIGN_KEYCHAIN=1
}

codesign_target() {
  local target_path="$1"
  local identifier="$2"
  local -a args=(
    --force
    --sign "$CODESIGN_IDENTITY"
    --timestamp=none
    --identifier "$identifier"
  )

  if [ -n "$CODESIGN_KEYCHAIN_PATH" ]; then
    args+=(--keychain "$CODESIGN_KEYCHAIN_PATH")
  fi

  codesign "${args[@]}" "$target_path" >/dev/null
}

verify_signed_app() {
  codesign --verify --verbose=2 "$APP_DIR"
}

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

resolve_codesign_identity
if [ "$USE_LOCAL_CODESIGN_KEYCHAIN" -eq 1 ]; then
  activate_local_codesign_keychain
fi

echo "Signing bundled daemon with identity: $CODESIGN_IDENTITY"
codesign_target "$DAEMON_BUNDLE_PATH" "com.voxa.daemon"
echo "Signing app bundle with identity: $CODESIGN_IDENTITY"
codesign_target "$APP_DIR" "com.voxa.menubar"
verify_signed_app

ditto "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"
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
