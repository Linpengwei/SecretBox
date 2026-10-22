#!/usr/bin/env python3
"""SecretBox MCP server (stdio transport, stdlib only).

Exposes SecretBox vault queries to MCP clients (Claude Code / Claude Desktop,
OpenAI Codex CLI, OpenCode) with a hard security boundary: plaintext secrets
NEVER appear in any tool response. Agents can search and inspect redacted
metadata, and can place a secret on the macOS clipboard via `copy_password`;
the human then pastes it where needed. The plaintext only transits this
process's memory and the system clipboard.

Data source: the vault blob the SecretBox macOS app stores in the user's
login Keychain (service/account configurable via env). Reading it may prompt
once for keychain access — choose "Always Allow".

Env overrides (strictly allowlisted):
  SECRETBOX_KEYCHAIN_SERVICE  (default: Hendrix.SecretBox)
  SECRETBOX_KEYCHAIN_ACCOUNT  (default: localVault)
  SECRETBOX_SERVER_URL        (optional; e.g. http://127.0.0.1:8000 — when
                               set, every tool call is reported to the
                               server's audit trail POST /api/audit, best
                               effort; no secrets are ever included)
  SECRETBOX_AGENT_NAME        (default: mcp-agent; label shown in the
                               server dashboard's Agent Audit tab)
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import urllib.request
from typing import Any

SERVER_NAME = "secretbox"
SERVER_VERSION = "1.1.0"
SUPPORTED_PROTOCOL_VERSIONS = {
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
}

# Keychain identifiers end up as argv to the `security` CLI; keep them on a
# strict allowlist so environment overrides can never smuggle flag/command
# content into the subprocess.
KEYCHAIN_ID_PATTERN = re.compile(r"^[A-Za-z0-9._\-]{1,128}$")

# Same allowlist discipline for the optional server-audit endpoint: only a
# base URL + agent label, and the URL must be http(s) to a host the user set
# explicitly via env (default: off — no network activity unless configured).
AUDIT_URL_PATTERN = re.compile(r"^https?://[A-Za-z0-9._\-]+(:\d+)?(/.*)?$")
AUDIT_TIMEOUT_SECONDS = 2.0

SECRET_FIELD_KEYS = {
    "password", "passwd", "pwd", "secret", "secret_key", "secretkey",
    "secret-key", "token", "sk", "sasl_password", "api_key", "apikey",
    "aws_secret_access_key", "rabbitmq_password", "rediscli_auth",
    "primarysecret", "passwordhash", "passwordfingerprint", "source_excerpt",
    "access_key_secret", "client_secret", "private_key", "secret_access_key",
}

# Field keys safe to echo back to an agent.
METADATA_FIELD_KEYS = {
    "host", "hostname", "port", "url", "endpoint", "s3_endpoint", "brokers",
    "database", "dbname", "db", "bucket", "topic", "queue", "vhost",
    "scope", "project", "tenant", "env", "environment", "namespace", "stage",
    "region", "aws_default_region", "provider", "cloud", "engine", "driver",
    "mechanism", "sasl_mechanism", "service", "label", "site", "app",
    "cluster", "username", "user", "login", "account", "email",
    "sasl_username", "access_key", "ak", "aws_access_key_id",
}

URI_RE = re.compile(r"\b([a-z][a-z0-9+.\-]*://)([^@/\s\"']+)@", re.IGNORECASE)


class VaultUnavailable(RuntimeError):
    pass


def _validated(name: str, default: str) -> str:
    value = os.environ.get(name, default)
    if not KEYCHAIN_ID_PATTERN.match(value):
        raise VaultUnavailable(f"Invalid {name}: rejected by allowlist.")
    return value


def keychain_service() -> str:
    return _validated("SECRETBOX_KEYCHAIN_SERVICE", "Hendrix.SecretBox")


def keychain_account() -> str:
    return _validated("SECRETBOX_KEYCHAIN_ACCOUNT", "localVault")


# --------------------------------------------------------------------------
# Optional server-side audit reporting. Disabled unless SECRETBOX_SERVER_URL
# is set. The URL is operator-supplied env config (not agent-controllable
# input) and is still hardened before use: scheme restricted to http/https,
# hostname strict-pattern-checked, resolved IP blocked for link-local /
# cloud-metadata / unspecified ranges, and redirects refused. Fire-and-forget
# from a daemon thread so tool latency never depends on the server being
# reachable; payloads never contain secrets — only the action, record id, and
# an outcome flag (the redaction mirror lives server-side in app/audit.py).
# --------------------------------------------------------------------------

def agent_name() -> str:
    raw = os.environ.get("SECRETBOX_AGENT_NAME", "mcp-agent")
    return raw if KEYCHAIN_ID_PATTERN.match(raw.replace("@", "-at-")) else "mcp-agent"


def audit_payload(action: str, record_id: str | None, allowed: bool, detail: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "actor": agent_name(),
        "actor_type": "agent",
        "action": action,
        "record_id": record_id,
        "allowed": allowed,
        "detail": detail or {},
    }


def _blocked_audit_ip(host: str) -> bool:
    import ipaddress
    import socket

    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return True
    for info in infos:
        try:
            address = ipaddress.ip_address(info[4][0])
        except ValueError:
            continue
        # Link-local (cloud metadata 169.254.169.254 lives here) and
        # unspecified addresses are refused. Loopback and private ranges are
        # allowed on purpose: the SecretBox server is typically self-hosted
        # locally or on the team LAN.
        if address.is_link_local or address.is_unspecified:
            return True
    return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


def _post_audit(base_url: str, payload: dict[str, Any]) -> None:
    try:
        from urllib.parse import urlparse

        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            return
        if not KEYCHAIN_ID_PATTERN.match(parsed.hostname):
            return
        if _blocked_audit_ip(parsed.hostname):
            return

        endpoint = f"{parsed.scheme}://{parsed.hostname}"
        if parsed.port:
            endpoint += f":{parsed.port}"
        endpoint += "/api/audit"

        request = urllib.request.Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        opener = urllib.request.build_opener(_NoRedirect)
        opener.open(request, timeout=AUDIT_TIMEOUT_SECONDS).read()
    except Exception:
        pass  # audit reporting is best-effort by design


def report_audit(action: str, record_id: str | None = None, allowed: bool = True, detail: dict[str, Any] | None = None) -> None:
    base = os.environ.get("SECRETBOX_SERVER_URL", "").rstrip("/")
    if not base or not AUDIT_URL_PATTERN.match(base):
        return
    payload = audit_payload(action, record_id, allowed, detail)
    threading.Thread(target=_post_audit, args=(base, payload), daemon=True).start()


def _scrub_uri(value: str) -> str:
    """Replace credentials embedded in URI userinfo with [REDACTED]."""

    def _sub(match: re.Match[str]) -> str:
        userinfo = match.group(2)
        if ":" in userinfo:
            user, _, _ = userinfo.rpartition(":")
            return f"{match.group(1)}{user}:[REDACTED]@"
        return f"{match.group(1)}[REDACTED]@"

    return URI_RE.sub(_sub, value)


def scrub(value: Any) -> Any:
    """Recursively scrub credentials from any string in a JSON structure."""
    if isinstance(value, str):
        return _scrub_uri(value)
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items()}
    return value


def password_shape(secret: str) -> dict[str, Any]:
    return {
        "length": len(secret),
        "has_upper": any(c.isupper() for c in secret),
        "has_lower": any(c.islower() for c in secret),
        "has_digit": any(c.isdigit() for c in secret),
        "has_symbol": any(not c.isalnum() for c in secret),
    }


def load_records() -> list[dict[str, Any]]:
    """Read the vault blob from the login Keychain via the security CLI."""
    result = subprocess.run(
        [
            "security", "find-generic-password",
            "-s", keychain_service(),
            "-a", keychain_account(),
            "-w",
        ],
        capture_output=True,
        text=True,
        shell=False,
    )
    if result.returncode != 0:
        raise VaultUnavailable(
            "SecretBox vault not found in Keychain. Launch the SecretBox app and "
            "save at least one record first. If macOS asks about keychain access, "
            "choose \"Always Allow\"."
        )
    try:
        blob = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise VaultUnavailable(f"Vault blob in Keychain is not valid JSON: {exc}") from exc
    records = blob.get("records") if isinstance(blob, dict) else blob
    if not isinstance(records, list):
        raise VaultUnavailable("Vault blob has an unexpected format.")
    return records


_ACCESS_ORDER = {"none": 0, "metadata": 1, "metadata_and_tools": 2}


def ai_access_level(record: dict[str, Any]) -> str:
    """Effective AI access level for a record (three-level matrix).

    New records carry ``permissions.aiAccess``; legacy blobs only had the
    boolean ``aiReadable`` (true meant metadata + clipboard tools). Anything
    unrecognized resolves to "none" — deny by default.
    """
    permissions = record.get("permissions")
    if isinstance(permissions, dict):
        level = permissions.get("aiAccess")
        if level in _ACCESS_ORDER:
            return level
    if record.get("aiReadable") is True:
        return "metadata_and_tools"
    return "none"


def agent_visible_records(min_level: str = "metadata") -> list[dict[str, Any]]:
    """Records visible to AI agents at the requested level or above.

    Every tool MUST go through this filter: records at "none" are invisible
    to agents (no metadata, no existence hint, no copy) — indistinguishable
    from a missing record. Clipboard tools additionally require the
    "metadata_and_tools" level via min_level.
    """
    floor = _ACCESS_ORDER.get(min_level, 1)
    return [r for r in load_records() if _ACCESS_ORDER.get(ai_access_level(r), 0) >= floor]


def ai_readable_records() -> list[dict[str, Any]]:
    """Back-compat alias: metadata-visible records."""
    return agent_visible_records(min_level="metadata")


def redact_record(record: dict[str, Any]) -> dict[str, Any]:
    """Project a record onto safe metadata fields only."""
    field_map = record.get("fieldMap") or {}
    fields: dict[str, str] = {}
    for key, value in field_map.items():
        if key.lower() in SECRET_FIELD_KEYS:
            continue
        if isinstance(value, str) and value:
            fields[key] = value
    meta = {
        "id": record.get("id"),
        "name": record.get("name"),
        "type": record.get("recordType") or record.get("itemType"),
        "cluster": record.get("clusterID") or record.get("clusterLabel"),
        "username": record.get("username"),
        "subtitle": record.get("subtitle"),
        "fields": {k: v for k, v in fields.items() if k.lower() in METADATA_FIELD_KEYS},
        "tags": record.get("tags") or [],
        "match_reason": record.get("matchReason"),
    }
    return {k: v for k, v in meta.items() if v not in (None, {}, [])}


def rank_records(records: list[dict[str, Any]], query: str) -> list[dict[str, Any]]:
    query = query.strip().lower()
    if not query:
        return list(records)

    def score(record: dict[str, Any]) -> int:
        hay = [record.get("name") or "", record.get("recordType") or "",
               record.get("templateType") or "", record.get("clusterID") or "",
               record.get("clusterLabel") or "", " ".join(record.get("tags") or [])]
        field_map = record.get("fieldMap") or {}
        hay.extend(str(v) for v in field_map.values())
        hay.append(record.get("subtitle") or "")
        text = " ".join(hay).lower()
        if query in text:
            return 100 - text.index(query)
        return 0

    scored = [(score(r), r) for r in records]
    return [r for s, r in sorted(scored, key=lambda pair: -pair[0]) if s > 0]


# --------------------------------------------------------------------------
# Tool implementations. Every user-visible payload passes through scrub().
# --------------------------------------------------------------------------

def tool_search_credentials(args: dict[str, Any]) -> dict[str, Any]:
    query = str(args.get("query", ""))
    limit = max(1, min(int(args.get("limit", 6)), 25))
    records = ai_readable_records()
    matches = rank_records(records, query)[:limit]
    report_audit("search", detail={"results": len(matches), "visible_total": len(records)})
    return {
        "content": [{
            "type": "text",
            "text": json.dumps({
                "query": query,
                "count": len(matches),
                "total_records": len(records),
                "results": [scrub(redact_record(r)) for r in matches],
                "note": "Secrets are never included. Use copy_password to place "
                        "a secret on the clipboard.",
            }, ensure_ascii=False, indent=2),
        }]
    }


def tool_list_credentials(args: dict[str, Any]) -> dict[str, Any]:
    limit = max(1, min(int(args.get("limit", 25)), 100))
    records = ai_readable_records()
    ordered = sorted(records, key=lambda r: str(r.get("name") or ""))[:limit]
    report_audit("list", detail={"results": len(ordered), "visible_total": len(records)})
    return {
        "content": [{
            "type": "text",
            "text": json.dumps({
                "count": len(ordered),
                "total_records": len(records),
                "results": [scrub(redact_record(r)) for r in ordered],
            }, ensure_ascii=False, indent=2),
        }]
    }


def tool_get_credential(args: dict[str, Any]) -> dict[str, Any]:
    record_id = str(args.get("record_id", ""))
    for record in agent_visible_records(min_level="metadata"):
        if record.get("id") == record_id:
            payload = scrub(redact_record(record))
            level = ai_access_level(record)
            payload["ai_access"] = level
            secret = record.get("primarySecret")
            if isinstance(secret, str) and secret:
                payload["password_shape"] = password_shape(secret)
                if level == "metadata_and_tools":
                    payload["note"] = ("Plaintext is never returned. Use copy_password "
                                       "to place it on the clipboard"
                                       + (", copy_totp for its verification code."
                                          if isinstance(record.get("totp"), dict) and record["totp"].get("secret")
                                          else "."))
                else:
                    payload["note"] = ("Plaintext is never returned, and clipboard "
                                       "tools are disabled for this record "
                                       "(metadata-only access).")
            report_audit("get_record", record_id=record_id, allowed=True,
                         detail={"ai_access": level})
            return {
                "content": [{
                    "type": "text",
                    "text": json.dumps(payload, ensure_ascii=False, indent=2),
                }]
            }
    report_audit("get_record", record_id=record_id, allowed=False,
                 detail={"reason": "not found or not visible to agents"})
    return _tool_error(f"No record with id {record_id!r}.")


def tool_copy_password(args: dict[str, Any]) -> dict[str, Any]:
    record_id = str(args.get("record_id", ""))
    for record in agent_visible_records(min_level="metadata_and_tools"):
        if record.get("id") == record_id:
            secret = record.get("primarySecret")
            if not isinstance(secret, str) or not secret:
                report_audit("copy_password", record_id=record_id, allowed=False,
                             detail={"reason": "no stored secret"})
                return _tool_error(f"Record {record_id!r} has no stored secret.")
            proc = subprocess.run(
                ["pbcopy"], input=secret, text=True, capture_output=True, shell=False
            )
            if proc.returncode != 0:
                report_audit("copy_password", record_id=record_id, allowed=False,
                             detail={"reason": "clipboard write failed"})
                return _tool_error("Failed to write to macOS clipboard (pbcopy).")
            report_audit("copy_password", record_id=record_id, allowed=True)
            return {
                "content": [{
                    "type": "text",
                    "text": json.dumps({
                        "copied": True,
                        "record": record.get("name"),
                        "hint": "The secret is on the clipboard and was NOT shown "
                                "in this conversation. Paste it where needed.",
                    }, ensure_ascii=False),
                }]
            }
    report_audit("copy_password", record_id=record_id, allowed=False,
                 detail={"reason": "not found or not visible to agents"})
    return _tool_error(f"No record with id {record_id!r}.")


def totp_code(secret: str, digits: int = 6, period: int = 30,
              algorithm: str = "SHA1", now: float | None = None) -> str:
    """RFC 6238 TOTP generation, pure stdlib. The seed stays in-process: only
    the generated code is emitted (and only onto the clipboard)."""
    import base64
    import struct
    import time

    normalized = secret.replace(" ", "").replace("-", "").upper()
    padded = normalized + "=" * ((8 - len(normalized) % 8) % 8)
    key = base64.b32decode(padded)
    counter = int((time.time() if now is None else now) // max(1, period))
    digest = hmac.new(
        key, struct.pack(">Q", counter), getattr(hashlib, algorithm.lower())
    ).digest()
    offset = digest[-1] & 0x0F
    binary = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(binary % (10 ** max(1, digits))).zfill(max(1, digits))


def tool_copy_totp(args: dict[str, Any]) -> dict[str, Any]:
    record_id = str(args.get("record_id", ""))
    for record in agent_visible_records(min_level="metadata_and_tools"):
        if record.get("id") == record_id:
            totp = record.get("totp")
            if not isinstance(totp, dict) or not totp.get("secret"):
                report_audit("copy_totp", record_id=record_id, allowed=False,
                             detail={"reason": "no TOTP seed"})
                return _tool_error(f"Record {record_id!r} has no two-step verification seed.")
            code = totp_code(
                str(totp.get("secret")),
                digits=int(totp.get("digits") or 6),
                period=int(totp.get("period") or 30),
                algorithm=str(totp.get("algorithm") or "SHA1"),
            )
            proc = subprocess.run(
                ["pbcopy"], input=code, text=True, capture_output=True, shell=False
            )
            if proc.returncode != 0:
                report_audit("copy_totp", record_id=record_id, allowed=False,
                             detail={"reason": "clipboard write failed"})
                return _tool_error("Failed to write to macOS clipboard (pbcopy).")
            report_audit("copy_totp", record_id=record_id, allowed=True)
            return {
                "content": [{
                    "type": "text",
                    "text": json.dumps({
                        "copied": True,
                        "record": record.get("name"),
                        "hint": "The current verification code is on the clipboard; "
                                "the seed never enters this conversation.",
                    }, ensure_ascii=False),
                }]
            }
    report_audit("copy_totp", record_id=record_id, allowed=False,
                 detail={"reason": "not found or not visible to agents"})
    return _tool_error(f"No record with id {record_id!r}.")


def _tool_error(message: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": message}], "isError": True}


TOOLS = [
    {
        "name": "search_credentials",
        "description": (
            "Search the SecretBox vault for credentials by keyword (host, service, "
            "env, username, type, tag). Returns redacted metadata only — never "
            "plaintext secrets."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search keyword."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 25},
            },
            "required": ["query"],
        },
    },
    {
        "name": "list_credentials",
        "description": "List vault records with redacted metadata (no secrets).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
    },
    {
        "name": "get_credential",
        "description": (
            "Get one record's redacted metadata plus the secret's shape "
            "(length/charset classes only — never the plaintext). The user may "
            'paste a "<secretbox-credential id=...>" reference instead of a '
            "secret; use its id as record_id here."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "record_id": {"type": "string"},
            },
            "required": ["record_id"],
        },
    },
    {
        "name": "copy_password",
        "description": (
            "Copy a record's password to the macOS clipboard. The plaintext is "
            "NOT returned to the agent; paste it directly where needed. Use the "
            'id from a pasted "<secretbox-credential>" reference as record_id.'
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "record_id": {"type": "string"},
            },
            "required": ["record_id"],
        },
    },
    {
        "name": "copy_totp",
        "description": (
            "Copy a record's current two-step verification (TOTP) code to the "
            "macOS clipboard. Only the rotating code is emitted — the seed never "
            "enters the conversation. Requires the record to be shared at the "
            "'metadata + tools' level and to have a TOTP seed."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "record_id": {"type": "string"},
            },
            "required": ["record_id"],
        },
    },
]

TOOL_HANDLERS = {
    "search_credentials": tool_search_credentials,
    "list_credentials": tool_list_credentials,
    "get_credential": tool_get_credential,
    "copy_password": tool_copy_password,
    "copy_totp": tool_copy_totp,
}


# --------------------------------------------------------------------------
# JSON-RPC / MCP plumbing (newline-delimited JSON over stdio).
# --------------------------------------------------------------------------

def handle_message(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    msg_id = message.get("id")

    if method == "initialize":
        requested = message.get("params", {}).get("protocolVersion")
        version = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else "2025-06-18"
        return _result(msg_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return _result(msg_id, {})
    if method == "tools/list":
        return _result(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params", {})
        name = params.get("name")
        handler = TOOL_HANDLERS.get(name)
        if handler is None:
            return _error(msg_id, -32602, f"Unknown tool: {name}")
        try:
            return _result(msg_id, handler(dict(params.get("arguments") or {})))
        except VaultUnavailable as exc:
            return _result(msg_id, _tool_error(str(exc)))
        except Exception as exc:  # noqa: BLE001 - surface as tool error
            return _result(msg_id, _tool_error(f"{type(exc).__name__}: {exc}"))
    if msg_id is None:
        return None  # unknown notification: ignore
    return _error(msg_id, -32601, f"Method not found: {method}")


def _result(msg_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _error(msg_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def serve(stdin=sys.stdin, stdout=sys.stdout) -> None:
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            response = _error(None, -32700, "Parse error")
        else:
            if not isinstance(message, dict):
                response = _error(None, -32600, "Invalid Request")
            else:
                response = handle_message(message)
        if response is not None:
            stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            stdout.flush()


if __name__ == "__main__":
    try:
        serve()
    except BrokenPipeError:
        sys.exit(0)
