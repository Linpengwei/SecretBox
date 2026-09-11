#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[1/2] Run macOS tests"
"$ROOT_DIR/scripts/test-macos.sh"

echo "[2/2] Run server tests"
cd "$ROOT_DIR/server"
python3 -m pytest tests
