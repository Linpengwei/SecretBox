#!/usr/bin/env bash
# Register the SecretBox MCP server into agent CLIs (thin wrapper).
#   scripts/setup-mcp.sh --all        # every requested client
#   scripts/setup-mcp.sh --claude-code --codex --opencode --claude-desktop
#   scripts/setup-mcp.sh --remove --all
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup_mcp.py" "$@"
