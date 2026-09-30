#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/feedback-previews"
mkdir -p "$BUILD_DIR"
sources=()
for source in "$ROOT_DIR"/Sources/Voxa/*.swift; do
  case "${source##*/}" in VoxaApp.swift) ;; *) sources+=("$source") ;; esac
done
swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$ROOT_DIR/.build/preview-module-cache" \
  "${sources[@]}" "$ROOT_DIR/scripts/preview/FeedbackPreview.swift" -o "$BUILD_DIR/render"
"$BUILD_DIR/render" "$BUILD_DIR"
