#!/usr/bin/env bash
# build.sh — cross-platform build script for scry
# Produces a release binary for the current platform.
# Usage: ./build.sh [--debug]

set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-release}"

case "$MODE" in
  --debug) make debug ;;
  *)       make release ;;
esac

echo ""
echo "Build complete: ./scry"
echo "Binary size: $(du -h scry | cut -f1)"
