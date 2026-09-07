#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${VOXA_DIST_DIR:-$ROOT_DIR/dist}"
INSTALL_DIR="${VOXA_INSTALL_DIR:-/Applications}"
DESTINATION="$INSTALL_DIR/Voxa.app"

if [ "$#" -eq 0 ]; then
  "$ROOT_DIR/scripts/package-macos.sh"
  CANDIDATE="$DIST_DIR/apps.noindex/Voxa.app"
elif [ "$#" -eq 2 ] && [ "$1" = '--app' ]; then
  CANDIDATE="$2"
else
  echo 'Usage: install.sh [--app /path/to/signed/Voxa.app]' >&2
  exit 2
fi
"$ROOT_DIR/scripts/verify-native-bundle.sh" "$CANDIDATE"

mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
DESTINATION="$INSTALL_DIR/Voxa.app"
RUNNING_EXECUTABLES="$(ps -axo comm=)"
while read -r executable; do
  if [ "$executable" = "$DESTINATION/Contents/MacOS/Voxa" ]; then
    echo "Quit $DESTINATION before replacing it. Finish any dictation first." >&2
    exit 1
  fi
done <<< "$RUNNING_EXECUTABLES"

STAGING="$(mktemp -d "$INSTALL_DIR/.Voxa-install.XXXXXX")"
INSTALLED=0
cleanup() {
  local result=$?
  if [ "$INSTALLED" -eq 0 ] && [ -d "$STAGING/previous.app" ]; then
    if ! mv "$STAGING/previous.app" "$DESTINATION"; then
      echo "Could not restore the previous app; it is preserved at $STAGING/previous.app" >&2
      exit 1
    fi
  fi
  rm -rf "$STAGING"
  exit "$result"
}
trap cleanup EXIT

ditto "$CANDIDATE" "$STAGING/Voxa.app"
"$ROOT_DIR/scripts/verify-native-bundle.sh" "$STAGING/Voxa.app"
if [ -e "$DESTINATION" ]; then
  if [ ! -d "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    echo 'The install destination is not a regular app directory; leaving it unchanged.' >&2
    exit 1
  fi
  BACKUP="$DIST_DIR/apps.noindex/backups/previous-$(date -u +%Y%m%dT%H%M%SZ)-$$/Voxa.app"
  mkdir -p "$(dirname "$BACKUP")"
  ditto "$DESTINATION" "$BACKUP"
  codesign --verify --deep --strict "$BACKUP"
  echo "Previous app preserved: $BACKUP"
  mv "$DESTINATION" "$STAGING/previous.app"
fi
# Both moves are on the install volume; failure restores the previous app via the trap.
mv "$STAGING/Voxa.app" "$DESTINATION"
INSTALLED=1
echo "Installed native app: $DESTINATION"
echo "Launch $DESTINATION to start dictating."
