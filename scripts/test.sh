#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[1/4] Run macOS tests"
"$ROOT_DIR/scripts/test-macos.sh"

echo "[2/4] Lint the Python side"
if command -v uvx >/dev/null 2>&1; then
  (cd "$ROOT_DIR" && uvx ruff@0.17.6 check .)
elif python3 -m ruff --version >/dev/null 2>&1; then
  (cd "$ROOT_DIR" && python3 -m ruff check .)
else
  echo "ruff not found; skipping here (CI runs it). Install it with: pip install ruff"
fi

echo "[3/4] Run server and MCP tests"
cd "$ROOT_DIR/server"
python3 -m pytest tests
cd "$ROOT_DIR/mcp-server"
python3 -m pytest test_secretbox_mcp.py

echo "[4/4] persona-200 regression (parser and search quality floors)"
python3 "$ROOT_DIR/server/scripts/run_persona_suite.py" --out-dir "$(mktemp -d)"
