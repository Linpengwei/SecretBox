"""Security and protocol tests for the SecretBox MCP server.

Run with: python3 -m pytest mcp-server/test_secretbox_mcp.py
No third-party dependencies; the server itself is stdlib-only.
"""

from __future__ import annotations

import base64
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import secretbox_mcp as server  # noqa: E402

SECRET = "Sup3rS3cret!#2026"

VAULT_RECORDS = [
    {
        "id": "rec-redis-1",
        "itemType": "redis",
        "templateType": "redis",
        "clusterID": "cacheCredential",
        "clusterLabel": "Redis Cache",
        "name": "Order Cache Redis",
        "subtitle": "prod",
        "notes": "order cache",
        "tags": ["env:prod", "service:order-cache"],
        "fields": [],
        "passwordHash": "argon2-hash-not-a-secret-but-still-stripped",
        "passwordFingerprint": "hmac-fingerprint-stripped",
        "primarySecret": SECRET,
        "matchReason": "seed",
        "aiReadable": True,
        "fieldMap": {
            "host": "redis-prod.internal",
            "port": "6379",
            "url": f"redis://default:{SECRET}@redis-prod.internal:6379/0",
            "source_excerpt": f"redis://default:[REDACTED]@redis-prod.internal:6379/0 {SECRET}",
            "password": SECRET,  # must be dropped by key filter
        },
        "username": "default",
    },
    {
        "id": "rec-db-1",
        "itemType": "database",
        "templateType": "database",
        "name": "Billing Postgres",
        "tags": ["env:prod"],
        "primarySecret": None,
        "aiReadable": False,
        "fieldMap": {"host": "billing-db.internal", "database": "billing"},
    },
    {
        "id": "rec-api-1",
        "itemType": "account",
        "name": "GitHub API Bot",
        "tags": ["env:prod"],
        "primarySecret": None,
        "fieldMap": {"host": "github.internal"},
    },
    {
        "id": "rec-secret-1",
        "itemType": "secret",
        "templateType": "s3",
        "name": "Shared S3 Deploy Key",
        "tags": ["env:prod"],
        "primarySecret": f"hidden-{SECRET}",
        "aiReadable": True,
        "fieldMap": {"bucket": "shared-bucket", "access_key": "AKIASHARED"},
    },
]


def call(method: str, params: dict | None = None, msg_id: int = 1) -> dict:
    message: dict = {"jsonrpc": "2.0", "id": msg_id, "method": method}
    if params is not None:
        message["params"] = params
    return server.handle_message(message)


def tool_text(response: dict) -> str:
    assert "error" not in response, response
    return response["result"]["content"][0]["text"]


def with_vault(monkeypatch, records):
    monkeypatch.setattr(server, "load_records", lambda: records)


# ---------------------------------------------------------------------------
# Protocol
# ---------------------------------------------------------------------------

def test_initialize_handshake():
    response = call("initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "0"},
    })
    result = response["result"]
    assert result["protocolVersion"] == "2025-06-18"
    assert "tools" in result["capabilities"]
    assert result["serverInfo"]["name"] == "secretbox"


def test_initialize_unknown_version_falls_back():
    response = call("initialize", {"protocolVersion": "1999-01-01"})
    assert response["result"]["protocolVersion"] == "2025-06-18"


def test_tools_list_exposes_five_tools():
    response = call("tools/list")
    names = {tool["name"] for tool in response["result"]["tools"]}
    assert names == {
        "search_credentials",
        "list_credentials",
        "get_credential",
        "copy_password",
        "copy_totp",
    }
    for tool in response["result"]["tools"]:
        assert tool["inputSchema"]["type"] == "object"


def test_notifications_yield_no_response():
    assert server.handle_message({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None


def test_ping():
    assert call("ping")["result"] == {}


def test_unknown_method_returns_error():
    response = call("resources/list")
    assert response["error"]["code"] == -32601


def test_stdio_roundtrip():
    stdin = io.StringIO(
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-06-18"}}) + "\n"
        + "not-json\n"
        + json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"
        + json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}) + "\n"
    )
    stdout = io.StringIO()
    server.serve(stdin, stdout)
    lines = [json.loads(line) for line in stdout.getvalue().strip().splitlines()]
    assert len(lines) == 3  # notification produced no output
    assert lines[0]["result"]["serverInfo"]["name"] == "secretbox"
    assert lines[1]["error"]["code"] == -32700
    assert lines[2]["result"] == {}


# ---------------------------------------------------------------------------
# Security: plaintext must never reach tool output
# ---------------------------------------------------------------------------

def test_search_returns_metadata_without_secrets(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    response = call("tools/call", {"name": "search_credentials",
                                   "arguments": {"query": "redis"}})
    text = tool_text(response)
    payload = json.loads(text)

    assert payload["count"] == 1
    result = payload["results"][0]
    assert result["name"] == "Order Cache Redis"
    assert result["fields"]["host"] == "redis-prod.internal"
    assert SECRET not in text, "plaintext secret leaked into search response"
    assert "argon2-hash" not in text and "hmac-fingerprint" not in text


def test_search_uri_credentials_are_scrubbed(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    response = call("tools/call", {"name": "search_credentials",
                                   "arguments": {"query": "redis"}})
    text = tool_text(response)
    assert SECRET not in text
    assert "redis://default:[REDACTED]@redis-prod.internal:6379/0" in text


def test_get_credential_returns_shape_not_secret(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    response = call("tools/call", {"name": "get_credential",
                                   "arguments": {"record_id": "rec-redis-1"}})
    payload = json.loads(tool_text(response))
    assert payload["password_shape"] == {
        "length": len(SECRET),
        "has_upper": True,
        "has_lower": True,
        "has_digit": True,
        "has_symbol": True,
    }
    assert SECRET not in tool_text(response)


def test_list_credentials_redacts_everything(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    text = tool_text(call("tools/call", {"name": "list_credentials", "arguments": {}}))
    assert SECRET not in text
    assert "passwordhash" not in text.lower()


def test_copy_password_writes_clipboard_but_never_responds_with_secret(monkeypatch):
    captured = {}
    monkeypatch.setattr(server, "load_records", lambda: VAULT_RECORDS)

    def fake_pbcopy(command, input=None, text=True, capture_output=False, shell=False):
        captured["input"] = input
        return type("Proc", (), {"returncode": 0})()

    monkeypatch.setattr(server.subprocess, "run", fake_pbcopy)
    response = call("tools/call", {"name": "copy_password",
                                   "arguments": {"record_id": "rec-redis-1"}})
    payload = json.loads(tool_text(response))
    assert payload["copied"] is True
    assert captured["input"] == SECRET, "clipboard must receive the real secret"
    assert SECRET not in tool_text(response), "plaintext leaked into agent context"


def test_unknown_record_is_tool_error(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    response = call("tools/call", {"name": "copy_password",
                                   "arguments": {"record_id": "missing"}})
    assert response["result"]["isError"] is True


def test_vault_unavailable_becomes_friendly_tool_error(monkeypatch):
    def boom():
        raise server.VaultUnavailable("vault missing")

    monkeypatch.setattr(server, "load_records", boom)
    response = call("tools/call", {"name": "search_credentials",
                                   "arguments": {"query": "x"}})
    assert response["result"]["isError"] is True
    assert "vault missing" in tool_text(response)


def test_keychain_env_overrides_are_allowlisted(monkeypatch):
    monkeypatch.setenv("SECRETBOX_KEYCHAIN_SERVICE", "ok.Service_1")
    assert server.keychain_service() == "ok.Service_1"

    monkeypatch.setenv("SECRETBOX_KEYCHAIN_SERVICE", "bad;rm -rf /")
    try:
        server.keychain_service()
        raise AssertionError("expected rejection")
    except server.VaultUnavailable:
        pass


def test_scrub_handles_nested_structures():
    dirty = {"a": [f"redis://u:{SECRET}@h", {"b": f"mysql://root:{SECRET}@db"}], "c": "clean"}
    cleaned = server.scrub(dirty)
    assert SECRET not in json.dumps(cleaned)
    assert cleaned["c"] == "clean"


# ---------------------------------------------------------------------------
# Permission control: only aiReadable=true records reach the agent
# ---------------------------------------------------------------------------

def test_non_optin_records_are_invisible_to_search_and_list(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    search = json.loads(tool_text(call("tools/call", {
        "name": "search_credentials", "arguments": {"query": "redis"}})))
    search_names = [r["name"] for r in search["results"]]
    assert search_names == ["Order Cache Redis"], "non-opt-in records leaked into search"

    listing = json.loads(tool_text(call("tools/call",
                                        {"name": "list_credentials", "arguments": {}})))
    list_names = [r["name"] for r in listing["results"]]
    assert "Billing Postgres" not in list_names, "explicitly denied record leaked"
    assert "GitHub API Bot" not in list_names, "absent-flag record leaked"
    assert "Shared S3 Deploy Key" in list_names, "opted-in record should be visible"
    assert "Order Cache Redis" in list_names, "opted-in record should be visible"


def test_denied_record_lookup_is_indistinguishable_from_missing(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    denied = tool_text(call("tools/call", {"name": "get_credential",
                                           "arguments": {"record_id": "rec-db-1"}}))
    missing = tool_text(call("tools/call", {"name": "get_credential",
                                            "arguments": {"record_id": "nope"}}))
    assert "No record with id" in denied and "No record with id" in missing
    # Identical wording: the agent cannot even learn a denied record exists.
    assert denied == missing.replace("nope", "rec-db-1")


def test_copy_password_refuses_denied_and_missing_records(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    for record_id in ("rec-db-1", "rec-api-1", "nope"):
        response = call("tools/call", {"name": "copy_password",
                                       "arguments": {"record_id": record_id}})
        assert response["result"]["isError"] is True
        assert "hidden-" not in json.dumps(response)


def test_optin_record_with_query_match_is_returned(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    payload = json.loads(tool_text(call("tools/call", {
        "name": "search_credentials", "arguments": {"query": "s3 deploy"}})))
    assert payload["count"] == 1
    assert payload["results"][0]["name"] == "Shared S3 Deploy Key"
    assert f"hidden-{SECRET}" not in json.dumps(payload)


def test_total_records_reflects_shared_count_only(monkeypatch):
    with_vault(monkeypatch, VAULT_RECORDS)
    payload = json.loads(tool_text(call("tools/call", {
        "name": "search_credentials", "arguments": {"query": ""}})))
    assert payload["total_records"] == 2, "denied records must not be counted"


# ---------------------------------------------------------------------------
# Three-level AI access + TOTP (two-step verification) support
# ---------------------------------------------------------------------------

TOTP_SEED = "JBSWY3DPEHPK3PXP"

LEVEL_RECORDS = [
    {   # Legacy boolean opt-in: full metadata + tools (back-compat mapping).
        "id": "legacy-tools",
        "itemType": "redis",
        "name": "Legacy Opt-In Redis",
        "primarySecret": SECRET,
        "aiReadable": True,
        "fieldMap": {"host": "redis-legacy.internal"},
    },
    {   # New matrix: metadata only — visible, but clipboard tools refuse.
        "id": "meta-only",
        "itemType": "account",
        "name": "Metadata Only GitHub",
        "primarySecret": SECRET,
        "permissions": {"readOnly": False, "hideSecret": False,
                        "requireReauth": False, "aiAccess": "metadata"},
        "fieldMap": {"host": "github.internal"},
    },
    {   # New matrix: metadata + tools, carries a TOTP seed.
        "id": "tools-totp",
        "itemType": "account",
        "name": "Tools Level With TOTP",
        "primarySecret": SECRET,
        "permissions": {"readOnly": False, "hideSecret": False,
                        "requireReauth": False, "aiAccess": "metadata_and_tools"},
        "totp": {"secret": TOTP_SEED, "issuer": "GitHub",
                 "account": "ops@example.com", "digits": 6,
                 "period": 30, "algorithm": "SHA1"},
        "fieldMap": {"host": "github.internal"},
    },
    {   # New matrix: explicit none — invisible, same as legacy aiReadable=false.
        "id": "matrix-denied",
        "itemType": "database",
        "name": "Denied By Matrix",
        "primarySecret": SECRET,
        "permissions": {"readOnly": False, "hideSecret": False,
                        "requireReauth": False, "aiAccess": "none"},
        "fieldMap": {"host": "db.internal"},
    },
]


def test_access_level_resolution_prefers_matrix_and_maps_legacy_boolean():
    assert server.ai_access_level(LEVEL_RECORDS[0]) == "metadata_and_tools"
    assert server.ai_access_level(LEVEL_RECORDS[1]) == "metadata"
    assert server.ai_access_level(LEVEL_RECORDS[2]) == "metadata_and_tools"
    assert server.ai_access_level(LEVEL_RECORDS[3]) == "none"
    assert server.ai_access_level({"id": "x"}) == "none", "unknown shapes deny by default"


def test_metadata_level_visible_in_search_but_tools_refuse(monkeypatch):
    with_vault(monkeypatch, LEVEL_RECORDS)
    payload = json.loads(tool_text(call("tools/call", {
        "name": "search_credentials", "arguments": {"query": "metadata only"}})))
    assert payload["count"] == 1
    assert payload["results"][0]["id"] == "meta-only"

    for tool in ("copy_password", "copy_totp"):
        response = call("tools/call", {"name": tool,
                                       "arguments": {"record_id": "meta-only"}})
        assert response["result"]["isError"] is True, "metadata-only must refuse clipboard tools"


def test_matrix_denied_record_is_invisible(monkeypatch):
    with_vault(monkeypatch, LEVEL_RECORDS)
    payload = json.loads(tool_text(call("tools/call", {
        "name": "search_credentials", "arguments": {"query": "denied"}})))
    assert payload["count"] == 0
    response = call("tools/call", {"name": "get_credential",
                                   "arguments": {"record_id": "matrix-denied"}})
    assert response["result"]["isError"] is True


def test_get_credential_reports_access_level(monkeypatch):
    with_vault(monkeypatch, LEVEL_RECORDS)
    payload = json.loads(tool_text(call("tools/call", {
        "name": "get_credential", "arguments": {"record_id": "meta-only"}})))
    assert payload["ai_access"] == "metadata"
    assert "metadata-only" in payload["note"]


def test_totp_code_matches_rfc6238_reference():
    # RFC 6238 Appendix B test vector seed (ASCII "12345678901234567890").
    rfc_seed = base64.b32encode(b"12345678901234567890").decode()
    # SHA1, 8 digits: T=59s → 94287082; T=1111111109s → 07081804.
    assert server.totp_code(rfc_seed, digits=8, period=30, now=59) == "94287082"
    assert server.totp_code(rfc_seed, digits=8, period=30, now=1111111109) == "07081804"


def test_copy_totp_writes_code_to_clipboard_and_never_leaks_seed(monkeypatch):
    captured = {}
    monkeypatch.setattr(server, "load_records", lambda: LEVEL_RECORDS)

    def fake_pbcopy(command, input=None, text=True, capture_output=False, shell=False):
        captured["input"] = input
        return type("Proc", (), {"returncode": 0})()

    monkeypatch.setattr(server.subprocess, "run", fake_pbcopy)
    response = call("tools/call", {"name": "copy_totp",
                                   "arguments": {"record_id": "tools-totp"}})
    payload = json.loads(tool_text(response))
    assert payload["copied"] is True
    assert captured["input"].isdigit() and len(captured["input"]) == 6, "clipboard must hold the 6-digit code"
    assert TOTP_SEED not in json.dumps(response), "TOTP seed must never enter agent context"


def test_copy_totp_refuses_records_without_seed_or_tool_level(monkeypatch):
    with_vault(monkeypatch, LEVEL_RECORDS)
    for record_id in ("legacy-tools", "meta-only", "matrix-denied", "nope"):
        response = call("tools/call", {"name": "copy_totp",
                                       "arguments": {"record_id": record_id}})
        assert response["result"]["isError"] is True


def test_redacted_metadata_never_contains_totp_seed(monkeypatch):
    with_vault(monkeypatch, LEVEL_RECORDS)
    for record in LEVEL_RECORDS:
        assert TOTP_SEED not in json.dumps(server.scrub(server.redact_record(record)))
        assert TOTP_SEED not in json.dumps(server.ai_access_level(record))


# ---------------------------------------------------------------------------
# Optional server-side audit reporting (off unless SECRETBOX_SERVER_URL set)
# ---------------------------------------------------------------------------

class _Placeholder:
    def start(self):
        pass


def _immediate_thread(monkeypatch):
    """Patch threading.Thread so report_audit runs _post_audit inline."""
    class ImmediateThread:
        def __init__(self, target, args=(), **kwargs):
            target(*args)

        def start(self):
            pass
    monkeypatch.setattr(server.threading, "Thread", ImmediateThread)


def test_report_audit_disabled_without_env(monkeypatch):
    monkeypatch.delenv("SECRETBOX_SERVER_URL", raising=False)
    started = []
    monkeypatch.setattr(server.threading, "Thread",
                        lambda *a, **k: started.append(k) or _Placeholder())
    server.report_audit("copy_password", record_id="rec-1")
    assert started == [], "no thread may spawn when reporting is off"


def test_report_audit_payload_shape(monkeypatch):
    monkeypatch.setenv("SECRETBOX_SERVER_URL", "http://127.0.0.1:8000/")
    monkeypatch.setenv("SECRETBOX_AGENT_NAME", "claude-code")
    _immediate_thread(monkeypatch)
    captured = {}
    monkeypatch.setattr(server, "_post_audit",
                        lambda base_url, payload: captured.update(url=base_url, payload=payload))

    server.report_audit("copy_password", record_id="rec-1", allowed=False,
                        detail={"reason": "not visible"})
    assert captured["url"] == "http://127.0.0.1:8000"
    assert captured["payload"] == {
        "actor": "claude-code",
        "actor_type": "agent",
        "action": "copy_password",
        "record_id": "rec-1",
        "allowed": False,
        "detail": {"reason": "not visible"},
    }


def test_tool_calls_report_audit_when_configured(monkeypatch):
    monkeypatch.setenv("SECRETBOX_SERVER_URL", "http://127.0.0.1:8000")
    _immediate_thread(monkeypatch)
    events = []
    monkeypatch.setattr(server, "_post_audit",
                        lambda base_url, payload: events.append(payload["action"]))
    with_vault(monkeypatch, LEVEL_RECORDS)

    call("tools/call", {"name": "search_credentials", "arguments": {"query": "redis"}})
    call("tools/call", {"name": "get_credential", "arguments": {"record_id": "legacy-tools"}})
    call("tools/call", {"name": "get_credential", "arguments": {"record_id": "no-such"}})

    assert events == ["search", "get_record", "get_record"], "every tool call reports exactly one event"


def test_agent_name_falls_back_on_invalid_labels(monkeypatch):
    monkeypatch.setenv("SECRETBOX_AGENT_NAME", "bad agent name!!")
    assert server.agent_name() == "mcp-agent"
    monkeypatch.setenv("SECRETBOX_AGENT_NAME", "claude-code")
    assert server.agent_name() == "claude-code"


class _RecordingOpener:
    def __init__(self, opened):
        self.opened = opened

    def open(self, *args, **kwargs):
        self.opened.append((args, kwargs))
        raise RuntimeError("should not open")


def test_post_audit_refuses_link_local_host(monkeypatch):
    import socket

    monkeypatch.setattr(socket, "getaddrinfo",
                        lambda host, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("169.254.169.254", 0))])
    opened = []
    monkeypatch.setattr(server.urllib.request, "build_opener",
                        lambda *a, **k: _RecordingOpener(opened))
    server._post_audit("http://metadata.example", {"action": "search"})
    assert opened == [], "cloud-metadata endpoints must never be contacted"
