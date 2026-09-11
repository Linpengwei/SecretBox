#!/usr/bin/env python3
"""Register the SecretBox MCP server into Claude Code, Claude Desktop,
Codex CLI and OpenCode configs.

Every config file is backed up next to itself (`.bak-<timestamp>`) before the
first modification in a run. Re-running updates the existing entry in place.

Usage:
  scripts/setup_mcp.py --claude-code --codex --opencode --claude-desktop
  scripts/setup_mcp.py --all          # register into every detected client
  scripts/setup_mcp.py --remove --claude-code
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

HOME = Path.home()
SERVER_FILE = Path(__file__).resolve().parent.parent / "mcp-server" / "secretbox_mcp.py"
SERVER_CMD = ["python3", str(SERVER_FILE)]
STAMP = time.strftime("%Y%m%d-%H%M%S")


def backup(path: Path) -> None:
    if path.exists():
        target = path.with_name(path.name + f".bak-{STAMP}")
        shutil.copy2(path, target)
        print(f"  backup: {target}")


def write_json_merge(path: Path, mutate) -> None:
    data = {}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"  ERROR: {path} is not valid JSON; skipping (fix it manually).")
            return False
    before = json.dumps(data, sort_keys=True)
    mutate(data)
    if json.dumps(data, sort_keys=True) == before:
        print(f"  already configured: {path}")
        return True
    backup(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"  updated: {path}")
    return True


def register_claude_code() -> bool:
    # Registration is a plain `mcpServers` entry in ~/.claude.json — the same
    # thing `claude mcp add` writes — so no subprocess is needed.
    print("[claude-code]")
    config = HOME / ".claude.json"
    return write_json_merge(config, lambda data: data.setdefault("mcpServers", {}).update({
        "secretbox": {"command": "python3", "args": [str(SERVER_FILE)]},
    }))


def register_claude_desktop() -> bool:
    print("[claude-desktop]")
    config = HOME / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    return write_json_merge(config, lambda data: data.setdefault("mcpServers", {}).update({
        "secretbox": {"command": "python3", "args": [str(SERVER_FILE)]},
    }))


def toml_quote(value: str) -> str:
    """Escape a string for a basic TOML double-quoted string."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def register_codex() -> bool:
    print("[codex]")
    config = HOME / ".codex" / "config.toml"
    section = "[mcp_servers.secretbox]"
    entry = (
        f"{section}\n"
        f'command = "python3"\n'
        f'args = ["{toml_quote(str(SERVER_FILE))}"]\n'
    )
    text = config.read_text() if config.exists() else ""
    if str(SERVER_FILE) in text and section in text:
        print(f"  already configured: {config}")
        return True
    backup(config)
    config.parent.mkdir(parents=True, exist_ok=True)
    if section in text:
        # Replace the existing section block up to the next section header.
        lines = text.splitlines(keepends=True)
        start = next(i for i, line in enumerate(lines) if line.strip() == section)
        end = len(lines)
        for i in range(start + 1, len(lines)):
            if lines[i].strip().startswith("["):
                end = i
                break
        lines[start:end] = [entry]
        config.write_text("".join(lines))
    else:
        with config.open("a") as handle:
            if text and not text.endswith("\n"):
                handle.write("\n")
            handle.write("\n" + entry)
    print(f"  updated: {config}")
    return True


def register_opencode() -> bool:
    print("[opencode]")
    json_config = HOME / ".config" / "opencode" / "opencode.json"
    jsonc_config = HOME / ".config" / "opencode" / "opencode.jsonc"
    if jsonc_config.exists() and not json_config.exists():
        print(f"  ERROR: {jsonc_config} (JSONC) found — add this manually:\n"
              '    "mcp": { "secretbox": { "type": "local",\n'
              f'        "command": [{{"python3", "{SERVER_FILE}"}}, "enabled": true }}\n'
              "  (see mcp-server/README.md)")
        return False
    return write_json_merge(json_config, lambda data: data.setdefault("mcp", {}).update({
        "secretbox": {"type": "local", "command": SERVER_CMD, "enabled": True},
    }))


def remove_from_json(path: Path, top_key: str) -> bool:
    if not path.exists():
        return True

    def mutate(data):
        data.get(top_key, {}).pop("secretbox", None)

    return write_json_merge(path, mutate)


def remove_claude_code() -> bool:
    print("[claude-code] remove")
    return remove_from_json(HOME / ".claude.json", "mcpServers")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--claude-code", action="store_true")
    parser.add_argument("--claude-desktop", action="store_true")
    parser.add_argument("--codex", action="store_true")
    parser.add_argument("--opencode", action="store_true")
    parser.add_argument("--all", action="store_true", help="every installed/detectable client")
    parser.add_argument("--remove", action="store_true", help="remove the registration instead")
    args = parser.parse_args()

    if not SERVER_FILE.exists():
        print(f"missing server: {SERVER_FILE}")
        return 2

    selected = {
        "claude-code": args.claude_code or args.all,
        "claude-desktop": args.claude_desktop or args.all,
        "codex": args.codex or args.all,
        "opencode": args.opencode or args.all,
    }
    if not any(selected.values()):
        parser.print_help()
        return 2

    ok = True
    if selected["claude-code"]:
        ok &= remove_claude_code() if args.remove else register_claude_code()
    if selected["claude-desktop"]:
        if args.remove:
            ok &= remove_from_json(HOME / "Library" / "Application Support" / "Claude"
                                   / "claude_desktop_config.json", "mcpServers")
        else:
            ok &= register_claude_desktop()
    if selected["codex"]:
        if args.remove:
            # TOML removal: drop the section textually.
            config = HOME / ".codex" / "config.toml"
            if config.exists():
                text = config.read_text()
                if "[mcp_servers.secretbox]" in text:
                    backup(config)
                    lines = text.splitlines(keepends=True)
                    start = next(i for i, line in enumerate(lines)
                                 if line.strip() == "[mcp_servers.secretbox]")
                    end = len(lines)
                    for i in range(start + 1, len(lines)):
                        if lines[i].strip().startswith("["):
                            end = i
                            break
                    del lines[start:end]
                    config.write_text("".join(lines))
            print("  removed from codex config (if present)")
        else:
            ok &= register_codex()
    if selected["opencode"]:
        if args.remove:
            ok &= remove_from_json(HOME / ".config" / "opencode" / "opencode.json", "mcp")
        else:
            ok &= register_opencode()

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
