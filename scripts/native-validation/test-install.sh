#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANDIDATE="${1:?Usage: test-install.sh /path/to/native/Voxa.app /path/to/legacy/Voxa.app}"
LEGACY="${2:?Pass the preserved signed legacy app for upgrade/rollback checks}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/Voxa install checks.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
export VOXA_INSTALL_DIR="$TEST_DIR/Applications"
export VOXA_DIST_DIR="$TEST_DIR/artifacts"
ORIGINAL_HASH="$(shasum -a 256 "$LEGACY/Contents/MacOS/Voxa")"
ORIGINAL_HASH="${ORIGINAL_HASH%% *}"
NATIVE_HASH="$(shasum -a 256 "$CANDIDATE/Contents/MacOS/Voxa")"
NATIVE_HASH="${NATIVE_HASH%% *}"

# Clean install, then replacement of a signed legacy installation with a verified backup.
"$ROOT_DIR/scripts/install.sh" --app "$CANDIDATE"
"$ROOT_DIR/scripts/verify-native-bundle.sh" "$VOXA_INSTALL_DIR/Voxa.app"
rm -rf "$VOXA_INSTALL_DIR/Voxa.app"
ditto "$LEGACY" "$VOXA_INSTALL_DIR/Voxa.app"
"$ROOT_DIR/scripts/install.sh" --app "$CANDIDATE"
ACTUAL_HASH="$(shasum -a 256 "$VOXA_INSTALL_DIR/Voxa.app/Contents/MacOS/Voxa")"
[ "${ACTUAL_HASH%% *}" = "$NATIVE_HASH" ]
BACKUPS=("$VOXA_DIST_DIR"/apps.noindex/backups/*/Voxa.app)
[ "${#BACKUPS[@]}" -eq 1 ]
BACKUP_HASH="$(shasum -a 256 "${BACKUPS[0]}/Contents/MacOS/Voxa")"
[ "${BACKUP_HASH%% *}" = "$ORIGINAL_HASH" ]
codesign --verify --deep --strict "${BACKUPS[0]}"

# Simulate the final rename failing, then verify that the previous app was restored intact.
rm -rf "$VOXA_INSTALL_DIR/Voxa.app"
ditto "$LEGACY" "$VOXA_INSTALL_DIR/Voxa.app"
mkdir -p "$TEST_DIR/tools"
cat > "$TEST_DIR/tools/mv" <<'STUB'
#!/bin/sh
if [ "${1##*/}" = 'Voxa.app' ] && [ "$2" = "$VOXA_INSTALL_DIR/Voxa.app" ]; then
  exit 91
fi
exec /bin/mv "$@"
STUB
chmod +x "$TEST_DIR/tools/mv"
if env PATH="$TEST_DIR/tools:$PATH" "$ROOT_DIR/scripts/install.sh" --app "$CANDIDATE"; then
  echo 'Expected the simulated install failure to fail.' >&2
  exit 1
fi
ACTUAL_HASH="$(shasum -a 256 "$VOXA_INSTALL_DIR/Voxa.app/Contents/MacOS/Voxa")"
[ "${ACTUAL_HASH%% *}" = "$ORIGINAL_HASH" ]
codesign --verify --deep --strict "$VOXA_INSTALL_DIR/Voxa.app"

# Refuse to replace a running destination, without touching a real process.
cat > "$TEST_DIR/tools/ps" <<'STUB'
#!/bin/sh
printf '%s\n' "$VOXA_INSTALL_DIR/Voxa.app/Contents/MacOS/Voxa"
STUB
chmod +x "$TEST_DIR/tools/ps"
if env PATH="$TEST_DIR/tools:$PATH" "$ROOT_DIR/scripts/install.sh" --app "$CANDIDATE"; then
  echo 'Expected the simulated running-app guard to fail.' >&2
  exit 1
fi
ACTUAL_HASH="$(shasum -a 256 "$VOXA_INSTALL_DIR/Voxa.app/Contents/MacOS/Voxa")"
[ "${ACTUAL_HASH%% *}" = "$ORIGINAL_HASH" ]
echo 'PASS: clean install, signed legacy upgrade/backup, failed replacement rollback and running-app guard.'
