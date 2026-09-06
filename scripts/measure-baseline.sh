#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/migration-measurements/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir -m 700 "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
python3 "$ROOT_DIR/scripts/baseline/collect.py" "$OUTPUT_DIR" --provenance-only
VOXA_BASELINE_DIR="$OUTPUT_DIR" cargo test --manifest-path "$ROOT_DIR/Cargo.toml" \
  -p voxa-daemon --release migration_fixture_baseline -- --ignored --test-threads=1 \
  > "$OUTPUT_DIR/fixture-run.log" 2>&1
test -s "$OUTPUT_DIR/fixture-metrics.json"
BUILD_DIR="$ROOT_DIR/apps/voxa-menubar/.build/baseline-checks"
mkdir -p "$BUILD_DIR"
swiftc -O -parse-as-library -warnings-as-errors -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/apps/voxa-menubar/Sources/VoxaMenuBar/ClipboardPaste.swift" \
  "$ROOT_DIR/scripts/baseline/OutputBaseline.swift" -o "$BUILD_DIR/output-baseline"
"$BUILD_DIR/output-baseline" "$OUTPUT_DIR"
python3 "$ROOT_DIR/scripts/baseline/collect.py" "$OUTPUT_DIR"
