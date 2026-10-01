#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/context-check"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/Sources/Voxa/TextContext.swift" "$ROOT_DIR/scripts/preview/LiveTextContextCheck.swift" \
  -o "$BUILD_DIR/live-check"
"$BUILD_DIR/live-check"
