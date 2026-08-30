#!/usr/bin/env bash
# install.sh — install a prebuilt scry binary
# Usage: curl -fsSL https://example.com/install.sh | bash
#   or:  ./install.sh [--prefix /usr/local]

set -euo pipefail

PREFIX="${HOME}/.local"
if [ "${1:-}" = "--prefix" ]; then PREFIX="${2:-${HOME}/.local}"; elif [ -n "${1:-}" ]; then PREFIX="$1"; fi

BIN_DIR="${PREFIX}/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/scry" ]; then
  echo "error: scry binary not found in ${SCRIPT_DIR}" >&2
  echo "Run ./build.sh first, or download a prebuilt release." >&2
  exit 1
fi

mkdir -p "${BIN_DIR}"
cp "${SCRIPT_DIR}/scry" "${BIN_DIR}/scry"
chmod +x "${BIN_DIR}/scry"

echo "Installed scry to ${BIN_DIR}/scry"
echo ""
echo "Quick start:"
echo "  scry --help"
echo "  scry --connection mydb"
